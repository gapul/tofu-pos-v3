package dev.gapul.tofupos

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.InputStream
import java.net.URI
import java.security.KeyStore
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.TimeUnit
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.net.ssl.HttpsURLConnection
import kotlin.math.min
import kotlin.math.pow
import kotlin.random.Random

data class PendingSale(val sale: Sale, val revision: Int) {
  fun json(): JSONObject = JSONObject().put("id", sale.id).put("revision", revision).put("created_at", sale.createdAt)
    .put("total", sale.total).put("received", sale.received).put("change_yen", sale.change)
    .put("cancelled_at", sale.cancelledAt ?: JSONObject.NULL).put("cancellation_reason", sale.cancellationReason ?: JSONObject.NULL)
    .put("lines", JSONArray(sale.lines.map { JSONObject().put("product_id", it.productID).put("name", it.name).put("price", it.price).put("quantity", it.quantity) }))
    // Omitted when null so 0.3.0 orders keep their cloud payload and hash.
    .apply { sale.deviceID?.let { put("device_id", it) }; sale.customerAge?.let { put("customer_age", it) }; sale.customerGender?.let { put("customer_gender", it) }; sale.customerGroup?.let { put("customer_group", it) }; sale.ticketNo?.let { put("ticket_no", it) }; sale.customerRelation?.let { put("customer_relation", it) } }
}
data class SyncReceipt(val id: String, val revision: Int)
data class SyncOutcome(val message: String, val pending: Int, val changed: Boolean = false, val images: Int = 0)
private class SyncFailure(message: String, val retryAfter: String? = null, val unauthorized: Boolean = false, val rejected: Boolean = false) : Exception(message)
data class SyncConnection(val url: String, val token: String)

class SyncCredentials(context: Context, private val environment: AppEnvironment = AppEnvironment.PRODUCTION) {
  private val preferences = context.getSharedPreferences("cloud-sync", Context.MODE_PRIVATE)
  private val assets = context.applicationContext.assets
  private val alias = environment.keyAlias
  private fun key(): SecretKey {
    val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    (store.getKey(alias, null) as? SecretKey)?.let { return it }
    return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
      init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
        .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
    }.generateKey()
  }
  /** A saved connection wins; otherwise the per-build-type bundled assets/sync-default(-test).json (never committed), if any. */
  fun load(): SyncConnection? {
    val stored = preferences.getString(environment.connectionKey, null) ?: return bundled()
    val parts = stored.split(":"); require(parts.size == 2) { "接続設定を読み込めません" }
    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
    cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, Base64.decode(parts[0], Base64.NO_WRAP)))
    val json = JSONObject(String(cipher.doFinal(Base64.decode(parts[1], Base64.NO_WRAP)), Charsets.UTF_8))
    return SyncConnection(json.getString("url"), json.getString("token"))
  }
  private fun bundled(): SyncConnection? = runCatching {
    val json = assets.open(environment.bundledConnection).use { JSONObject(String(SyncRules.readLimited(it, 4096), Charsets.UTF_8)) }
    SyncConnection(json.getString("url"), json.getString("token")).takeIf { c ->
      runCatching { SyncRules.endpoint(c.url) }.isSuccess && c.token.length in 32..256 && c.token.all { it.code in 33..126 }
    }
  }.getOrNull()
  fun save(connection: SyncConnection) {
    val cipher = Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.ENCRYPT_MODE, key())
    val json = JSONObject().put("url", connection.url).put("token", connection.token).toString()
    val encrypted = cipher.doFinal(json.toByteArray(Charsets.UTF_8))
    check(preferences.edit().putString(environment.connectionKey, Base64.encodeToString(cipher.iv, Base64.NO_WRAP) + ":" + Base64.encodeToString(encrypted, Base64.NO_WRAP)).commit()) { "接続設定を保存できません" }
  }
}
object SyncRules {
  fun endpoint(base: String): URI {
    val uri = URI(base.trim())
    require(uri.scheme == "https" && !uri.host.isNullOrBlank() && uri.userInfo == null && uri.query == null && uri.fragment == null && uri.port in listOf(-1, 443) && uri.path in listOf("", "/")) { "CloudflareのHTTPS URLを入力してください（パスなし）" }
    return URI("https", null, uri.host, uri.port, "/v1/sync", null, null)
  }
  fun delay(failures: Int, retryAfter: String? = null): Double = retryAfter?.toDoubleOrNull()?.takeIf { it.isFinite() }
    ?.coerceIn(15.0, 3600.0) ?: min(300.0, 15.0 * 2.0.pow((failures - 1).coerceIn(0, 5)))
  fun readLimited(stream: InputStream, limit: Int): ByteArray {
    val output = java.io.ByteArrayOutputStream(); val chunk = ByteArray(4096)
    while (true) { val n = stream.read(chunk); if (n < 0) break; require(output.size() + n <= limit) { "応答が大きすぎます" }; output.write(chunk, 0, n) }
    return output.toByteArray()
  }
}
class CloudSync(private val credentials: SyncCredentials, private val worker: Executor, private val imageDirectory: java.io.File? = null, private val store: () -> POSStore) {
  val running = AtomicBoolean(false)
  private val network = Executors.newSingleThreadExecutor()
  private val deadlines = Executors.newSingleThreadScheduledExecutor()
  @Volatile var lastMessage = "会計後に自動で送信します"
    private set
  // When the last upload left work that a later attempt can finish (epoch seconds); null otherwise.
  // Auth failures and content conflicts are not retried automatically.
  @Volatile var autoRetryAt: Double? = null
    private set
  // Set after HTTP 401/403. Every automatic trigger stops until settings are saved or a manual send succeeds.
  @Volatile var halted = false
    private set
  fun connection(): SyncConnection? = credentials.load()
  fun configure(url: String, token: String) {
    check(!running.get()) { "同期完了後に設定してください" }
    val endpoint = SyncRules.endpoint(url)
    val value = token.ifEmpty { credentials.load()?.token.orEmpty() }
    require(value.length in 32..256 && value.all { it.code in 33..126 }) { "端末用トークンを入力してください" }
    store().bindSyncTarget(endpoint.toString())
    credentials.save(SyncConnection(url.trim(), value))
    halted = false
    lastMessage = "接続設定を保存しました"
  }
  fun backupProducts(completion: (Result<String>) -> Unit) {
    var count = 0
    backupRequest("/v1/catalogs", {
      val products = store().products(); require(products.size <= 1000) { "商品バックアップは最大1000件です" }; count = products.size
      JSONObject().put("schema_version",1).put("products",JSONArray(products.map { JSONObject().put("id",it.id).put("name",it.name).put("price",it.price) })).toString().toByteArray(Charsets.UTF_8)
    }, {
      require(it.getString("id").matches(Regex("[a-f0-9]{64}")) && it.getInt("product_count") == count) { "不正なバックアップ応答です" }
      "商品${count}件をバックアップしました。売上は会計ごとに自動で送信します"
    }, completion)
  }
  fun catalogs(before: String?, completion: (Result<CatalogPage>) -> Unit) = backupRequest("/v1/catalogs", { null }, {
    val rows = it.getJSONArray("catalogs"); require(rows.length() <= 20)
    val items = (0 until rows.length()).map { index -> rows.getJSONObject(index).let { r ->
      val id = r.getString("id"); require(id.matches(Regex("[a-f0-9]{64}")))
      val count = r.getInt("product_count"); require(count in 0..1000)
      val date = r.getString("received_at"); java.time.Instant.parse(date)
      Catalog(id,count,date)
    } }
    val next = if (it.isNull("next")) null else it.getString("next").also { cursor -> require(cursor.length <= 128 && cursor != before) }
    CatalogPage(items,next)
  }, completion, query = { before?.let { "?before="+java.net.URLEncoder.encode(it,"UTF-8") } ?: "" })
  fun restore(catalog: String?, continuation: Boolean, completion: (Result<String>) -> Unit) {
    var after = ""; var selected = catalog
    backupRequest("/v1/restore", { null }, { json ->
      val page = RestorePage.parse(json,after,selected)
      store().restore(page).message(page.next)
    }, completion, query = {
      if (continuation) { val cursor = store().restoreCursor(); selected = cursor.first; after = cursor.second; require(after.isNotEmpty()) { "復元の続きはありません" } }
      val encode = { value: String -> java.net.URLEncoder.encode(value,"UTF-8") }
      "?after=" + encode(after) + (selected?.let { "&catalog_id="+encode(it) } ?: "")
    })
  }
  // Manual operations share the upload lock and persistent backoff, never a retry loop.
  private fun <T> backupRequest(path: String, body: () -> ByteArray?, apply: (JSONObject) -> T,
    completion: (Result<T>) -> Unit, query: () -> String = { "" }) {
    if (!running.compareAndSet(false,true)) { completion(Result.failure(IllegalStateException("通信中です"))); return }
    fun finish(result: Result<T>) { lastMessage = result.fold({ if (it is String) it else "バックアップを選択してください" },{ it.message ?: "通信できませんでした" }); running.set(false); completion(result) }
    worker.execute {
      try {
        val connection = credentials.load() ?: error("先に同期設定をしてください")
        val endpoint = SyncRules.endpoint(connection.url); store().bindSyncTarget(endpoint.toString())
        val (next,failures) = store().syncGate(); require(System.currentTimeMillis()/1000.0 >= next) { "待機中です。少し待ってから実行してください" }
        val data = body(); require(data == null || data.size <= 256*1024) { "商品バックアップが256KiBを超えています" }
        val url = endpoint.resolve(path+query()).toURL()
        store().setSyncGate(System.currentTimeMillis()/1000.0+30,failures)
        network.execute {
          var retryAfter: String? = null
          val response = runCatching {
            val http = url.openConnection() as HttpsURLConnection
            val expired = AtomicBoolean(false)
            val deadline = deadlines.schedule({ expired.set(true); http.disconnect() },25,TimeUnit.SECONDS)
            try {
              http.instanceFollowRedirects=false; http.connectTimeout=15000; http.readTimeout=20000
              http.setRequestProperty("Authorization","Bearer ${connection.token}"); http.setRequestProperty("User-Agent","TofuPOS/0.4.0 (Android)")
              if (data != null) { http.requestMethod="POST"; http.doOutput=true; http.setRequestProperty("Content-Type","application/json"); http.setFixedLengthStreamingMode(data.size); http.outputStream.use { it.write(data) } }
              val status=http.responseCode; retryAfter=http.getHeaderField("Retry-After")
              if (status==401 || status==403) { retryAfter="300"; error("同期設定のトークンを確認してください") }
              check(status==200) { "通信できませんでした（HTTP $status）。端末データは保持しています" }
              val bytes=http.inputStream.use { SyncRules.readLimited(it,512*1024+4096) }; check(!expired.get()) { "通信がタイムアウトしました" }
              JSONObject(String(bytes,Charsets.UTF_8)).also { require(it.getInt("schema_version")==1) { "未対応のバックアップ形式です" } }
            } finally { deadline.cancel(false); http.disconnect() }
          }
          worker.execute {
            val result=response.mapCatching(apply)
            try { store().setSyncGate(System.currentTimeMillis()/1000.0 + if (result.isFailure) SyncRules.delay(failures+1,retryAfter)*Random.nextDouble(1.0,1.2) else 0.0, if (result.isFailure) min(10,failures+1) else 0) }
            catch (error: Exception) { finish(Result.failure(error)); return@execute }
            finish(result)
          }
        }
      } catch (error: Exception) { finish(Result.failure(error)) }
    }
  }
  /**
   * One cycle in [SyncStep] order: orders -> images -> products -> stock -> sessions -> feed (<= 5 pages) -> missing photos. Network calls run on
   * their own thread; every database step is handed to [worker] so checkout never waits for the network.
   * [manual] releases conflicting orders for one more attempt.
   */
  fun run(manual: Boolean = false, completion: (Result<SyncOutcome>) -> Unit) {
    if (!running.compareAndSet(false, true)) { completion(Result.failure(IllegalStateException("同期中です"))); return }
    autoRetryAt = null
    fun finish(result: Result<SyncOutcome>) {
      lastMessage = result.fold({ it.message }, { it.message ?: "同期できませんでした" })
      running.set(false); completion(result)
    }
    worker.execute {
      try {
        val connection = credentials.load() ?: error("先に同期設定をしてください")
        val endpoint = SyncRules.endpoint(connection.url)
        val (next, failures) = store().syncGate(); val now = System.currentTimeMillis() / 1000.0
        if (now < next) autoRetryAt = next
        check(now >= next) { "待機中です。${kotlin.math.ceil(next - now).toInt()}秒後に再送します" }
        store().bindSyncTarget(endpoint.toString())
        store().setSyncGate(now + 30, failures)
        if (manual) store().releaseConflicts()
        network.execute {
          val cycle = runCatching { cycle(connection, endpoint) }
          worker.execute completion@ {
            val result = cycle.map { it.outcome }
            val failure = cycle.exceptionOrNull()
            if (failure != null) {
              val unauthorized = (failure as? SyncFailure)?.unauthorized == true
              val gate = System.currentTimeMillis() / 1000.0 + SyncRules.delay(failures + 1, (failure as? SyncFailure)?.retryAfter) * Random.nextDouble(1.0, 1.2)
              if (unauthorized) halted = true else autoRetryAt = gate
              try { store().setSyncGate(gate, min(10, failures + 1)) }
              catch (error: Exception) { finish(Result.failure(IllegalStateException("同期の待機状態を保存できません", error))); return@completion }
            } else {
              val done = cycle.getOrThrow()
              val gate = System.currentTimeMillis() / 1000.0 + if (done.conflicts == 0) 5 else 300
              try { store().setSyncGate(gate, 0); store().markSent() }
              catch (error: Exception) { finish(Result.failure(IllegalStateException("同期の待機状態を保存できません", error))); return@completion }
              halted = false
              if (done.conflicts == 0 && done.more) autoRetryAt = gate
            }
            finish(result)
          }
        }
      } catch (error: Exception) { finish(Result.failure(error)) }
    }
  }
  /**
   * On return to the foreground: fetch photos referenced by products but missing locally, outside the sync cycle.
   * Shares the network thread (so it queues behind a running cycle), skips while token-halted, never touches the gate.
   */
  fun fetchMissingImages(done: (Int) -> Unit) {
    val directory = imageDirectory ?: return
    if (halted) return
    worker.execute {
      val connection = runCatching { credentials.load() }.getOrNull() ?: return@execute
      val endpoint = runCatching { SyncRules.endpoint(connection.url) }.getOrNull() ?: return@execute
      val missing = runCatching { store().referencedImages() }.getOrDefault(emptySet()).filter { !ProductImages.file(directory, it).isFile }.take(ProductImages.DOWNLOADS_PER_CYCLE)
      if (missing.isEmpty()) return@execute
      network.execute {
        var fetched = 0
        missing.forEach { hash ->
          if (ProductImages.file(directory, hash).isFile) return@forEach
          runCatching { ProductImages.save(directory, hash, request(connection, endpoint.resolve("/v1/images/$hash").toURL(), null, ProductImages.MAX_BYTES, null)); fetched++ }
        }
        if (fetched > 0) done(fetched)
      }
    }
  }
  private class Cycle(val outcome: SyncOutcome, val conflicts: Int, val more: Boolean)
  private fun <T> db(block: (POSStore) -> T): T = try { CompletableFuture.supplyAsync({ block(store()) }, worker).get() }
    catch (error: ExecutionException) { throw error.cause ?: error }
  private fun cycle(connection: SyncConnection, endpoint: URI): Cycle {
    val notes = mutableListOf<String>(); var changed = false; var more = false; var images = 0
    var conflicts = 0; var orderMessage: String? = null; var pending = 0; var held = 0; var conflicted = 0; var imported = 0
    fun post(path: String, body: JSONObject, limit: Int): JSONObject {
      val data = body.toString().toByteArray(Charsets.UTF_8); require(data.size <= 256 * 1024) { "送信データが256KiBを超えています" }
      return call(connection, endpoint.resolve(path).toURL(), data, limit)
    }
    // HTTP 400 parks just that batch (sync_error='rejected') and the cycle goes on.
    fun postOrReject(path: String, body: JSONObject, limit: Int, label: String, size: Int, reject: (POSStore) -> Unit): JSONObject? = try { post(path, body, limit) }
      catch (error: SyncFailure) {
        if (!error.rejected) throw error
        db(reject); notes += "送信できなかった${label}${size}件を保留しました"; changed = true; null
      }
    fun orders() {
      val candidates = db { it.pendingSales() }
      val batch = mutableListOf<PendingSale>(); val oversized = mutableListOf<String>()
      fun encode(rows: List<PendingSale>) = JSONObject().put("schema_version", 1).put("orders", JSONArray(rows.map { it.json() })).toString().toByteArray(Charsets.UTF_8)
      candidates.forEach { row ->
        if (encode(listOf(row)).size > 256 * 1024) oversized += row.sale.id
        else if (encode(batch + row).size <= 256 * 1024) batch += row
      }
      if (oversized.isNotEmpty()) db { it.holdSync(oversized) }
      if (batch.isNotEmpty()) {
        val json = call(connection, endpoint.toURL(), encode(batch), 64 * 1024)
        val allowed = batch.associate { it.sale.id to it.revision }
        val accepted = json.getJSONArray("accepted"); val conflictRows = json.getJSONArray("conflicts")
        val receipts = (0 until accepted.length()).map { accepted.getJSONObject(it).let { row -> SyncReceipt(row.getString("id"), row.getInt("revision")) } }
        val conflictIDs = (0 until conflictRows.length()).map { conflictRows.getJSONObject(it).getString("id") }
        val receiptIDs = receipts.map { it.id }
        check(receipts.all { allowed[it.id] == it.revision } && receiptIDs.distinct().size == receiptIDs.size && conflictIDs.distinct().size == conflictIDs.size && receiptIDs.toSet().intersect(conflictIDs.toSet()).isEmpty() && (receiptIDs + conflictIDs).toSet() == allowed.keys) { "不正な同期応答です。未同期のまま保持しました" }
        db { it.acknowledge(receipts); it.holdConflicts(conflictIDs) }
        conflicts = conflictIDs.size
        val left = db { it.pendingCount() }
        orderMessage = if (conflicts == 0) "${receipts.size}件を同期しました。残り${left}件" else "${receipts.size}件を同期。競合${conflicts}件は保留し、自動送信しません（「今すぐ送信」で再送）"
        changed = true
      }
      db { Triple(it.pendingCount(), it.heldSyncCount(), it.conflictCount()) }.let { (p, h, c) -> pending = p; held = h; conflicted = c }
      if (pending > held + conflicted) more = true
    }
    fun uploadImages() {
      val hashes = db { it.pendingImages() }
      hashes.forEach { hash ->
        val bytes = imageDirectory?.let { ProductImages.file(it, hash) }?.takeIf { it.isFile }?.readBytes()
        if (bytes == null || ProductImages.sha256(bytes) != hash) { db { it.rejectImage(hash, "missing") }; notes += "写真のファイルが見つからないため送信を保留しました"; return@forEach }
        try {
          val json = call(connection, endpoint.resolve("/v1/images").toURL(), bytes, 4096, "image/jpeg")
          check(json.getString("hash") == hash) { "不正な写真の応答です" }
          db { it.markImageUploaded(hash) }
        } catch (error: SyncFailure) {
          if (!error.rejected) throw error
          db { it.rejectImage(hash, "rejected") }; notes += "送信できなかった写真1枚を保留しました"; changed = true
        }
      }
      if (hashes.size == ProductImages.UPLOADS_PER_CYCLE) more = true
    }
    fun products() {
      val dirty = db { it.dirtyProducts() }
      if (dirty.isEmpty()) return
      val json = postOrReject("/v1/products", JSONObject().put("schema_version", 1).put("products", JSONArray(dirty.map {
        JSONObject().put("id", it.id).put("name", it.name).put("price", it.price).put("active", it.active).put("track_stock", true)
          .put("stop_at_zero", it.stopAtZero).put("image_hash", it.imageHash ?: JSONObject.NULL).put("base_version", it.version)
      })), 512 * 1024, "商品", dirty.size) { store -> store.rejectProducts(dirty.map { it.id }) }
      if (json != null) {
        val rows = json.getJSONArray("results")
        val results = (0 until rows.length()).map { rows.getJSONObject(it).let { r ->
          val status = r.getString("status"); require(status == "applied" || status == "conflict") { "不正な商品同期応答です" }
          ProductResult(status == "conflict", CloudJSON.product(r.getJSONObject("product"))).also { require(it.product.id == r.getString("id")) { "不正な商品同期応答です" } }
        } }
        val ids = results.map { it.product.id }
        check(ids.distinct().size == ids.size && ids.toSet() == dirty.map { it.id }.toSet()) { "不正な商品同期応答です" }
        db { it.applyProductResults(dirty, results) }
        results.filter { it.conflict }.forEach { notes += "商品「${it.product.name}」は他の端末の変更を優先しました" }
        changed = true
      }
      more = more || dirty.size == 100
    }
    // Rejected events (product_not_found) cannot succeed on resend, so they are marked sent too.
    fun stock() {
      val events = db { it.pendingStockEvents() }
      if (events.isEmpty()) return
      val json = postOrReject("/v1/stock", JSONObject().put("schema_version", 1).put("events", JSONArray(events.map {
        JSONObject().put("id", it.id).put("product_id", it.productID).put("kind", it.kind).put("quantity", it.quantity)
          .put("created_at", it.createdAt).apply { it.reason?.let { reason -> put("reason", reason) } }
      })), 512 * 1024, "在庫", events.size) { store -> store.rejectStockEvents(events.map { it.id }) }
      if (json != null) {
        val accepted = json.getJSONArray("accepted").let { a -> (0 until a.length()).map { a.getString(it) } }
        val rejected = json.getJSONArray("rejected").let { a -> (0 until a.length()).map { a.getJSONObject(it).getString("id") } }
        val products = json.getJSONArray("products").let { a -> (0 until a.length()).map { CloudJSON.product(a.getJSONObject(it)) } }
        check((accepted + rejected).distinct().size == accepted.size + rejected.size && (accepted + rejected).toSet() == events.map { it.id }.toSet()) { "不正な在庫同期応答です" }
        db { it.markStockSynced(accepted + rejected, products) }
        if (rejected.isNotEmpty()) notes += "在庫調整${rejected.size}件は反映されませんでした（商品がクラウドにありません）"
        changed = true
      }
      more = more || events.size == 100
    }
    // An open session is sent with its running totals.
    fun sessions() {
      val sessions = db { store -> store.pendingSessions().map { it to (if (it.closedAt == null) store.sessionSummary(it.openedAt, null) else null) } }
      if (sessions.isEmpty()) return
      val label = CodePoints.deviceLabel(android.os.Build.MODEL)
      val deviceID = db { it.deviceID() }
      val json = postOrReject("/v1/sessions", JSONObject().put("schema_version", 1).put("sessions", JSONArray(sessions.map { (s, live) ->
        fun counts(map: Map<String, Int>?) = map?.let { m -> JSONObject().apply { m.forEach { (k, v) -> put(k, v) } } } ?: JSONObject.NULL
        JSONObject().put("id", s.id).put("device_id", deviceID).put("device_label", label).put("opened_at", s.openedAt)
          .put("closed_at", s.closedAt ?: JSONObject.NULL).put("float", counts(s.float)).put("float_total", s.floatTotal)
          .put("counted", counts(s.counted)).put("counted_total", s.countedTotal ?: JSONObject.NULL).put("expected_total", s.expectedTotal ?: JSONObject.NULL)
          .put("sales_total", s.salesTotal ?: live?.sales ?: 0).put("cancel_total", s.cancelTotal ?: live?.cancels ?: 0).put("order_count", s.orderCount ?: live?.orders ?: 0)
      })), 64 * 1024, "レジ記録", sessions.size) { store -> store.rejectSessions(sessions.map { it.first }) }
      if (json != null) {
        val accepted = json.getJSONArray("accepted").let { a -> (0 until a.length()).map { a.getString(it) } }
        // Rejected = the cloud already holds a different closed session; resending cannot fix it, so the cloud wins.
        val rejected = json.optJSONArray("rejected")?.let { a -> (0 until a.length()).map { a.getJSONObject(it).getString("id") } }.orEmpty()
        check((accepted + rejected).distinct().size == accepted.size + rejected.size && (accepted + rejected).toSet() == sessions.map { it.first.id }.toSet()) { "不正なレジ締め同期応答です" }
        db { it.markSessionsSynced(sessions.map { it.first }) }
        if (rejected.isNotEmpty()) notes += "レジセッション${rejected.size}件はクラウドの締め済み内容を優先しました"
      }
    }
    fun feed() {
      var pages = 0; var page: FeedPage
      do {
        val after = db { it.feedAfter() }
        page = FeedPage.parse(call(connection, endpoint.resolve("/v1/feed?after=$after").toURL(), null, 600 * 1024), after)
        val applied = db { it.applyFeed(page) }
        imported += applied.orders + applied.cancellations
        if (applied.products + applied.orders + applied.cancellations > 0) changed = true
        pages++
      } while (page.hasMore && pages < 5)
      if (page.hasMore) more = true
    }
    // Missing photos are fetched best effort; a failure waits for the next cycle and never fails this one.
    fun downloadImages() {
      val directory = imageDirectory ?: return
      val missing = db { it.referencedImages() }.filter { !ProductImages.file(directory, it).isFile }.take(ProductImages.DOWNLOADS_PER_CYCLE)
      missing.forEach { hash ->
        runCatching {
          val bytes = request(connection, endpoint.resolve("/v1/images/$hash").toURL(), null, ProductImages.MAX_BYTES, null)
          ProductImages.save(directory, hash, bytes); images++
        }
      }
    }
    for (step in SyncStep.entries) when (step) {
      SyncStep.ORDERS -> orders()
      SyncStep.IMAGES -> uploadImages()
      SyncStep.PRODUCTS -> products()
      SyncStep.STOCK -> stock()
      SyncStep.SESSIONS -> sessions()
      SyncStep.FEED -> feed()
      SyncStep.IMAGE_DOWNLOADS -> downloadImages()
    }
    val message = listOfNotNull(
      orderMessage ?: if (pending == 0) "すべて同期済みです" else if (pending == held + conflicted) "未同期${pending}件は保留中です" else "未同期${pending}件",
      if (held > 0) "サイズ超過で保留${held}件（CSVで取り出せます）" else null,
      if (conflicted > 0 && orderMessage == null) "競合で保留${conflicted}件（「今すぐ送信」で再送）" else null,
      if (imported > 0) "他の端末から${imported}件を取り込みました" else null
    ) + notes
    return Cycle(SyncOutcome(message.joinToString("。"), pending, changed, images), conflicts, more)
  }
  // Blocking request on the network thread with a hard 25 s deadline.
  private fun call(connection: SyncConnection, url: java.net.URL, data: ByteArray?, limit: Int, contentType: String = "application/json"): JSONObject =
    JSONObject(String(request(connection, url, data, limit, contentType), Charsets.UTF_8)).also { check(it.getInt("schema_version") == 1) { "不正な同期応答です" } }
  private fun request(connection: SyncConnection, url: java.net.URL, data: ByteArray?, limit: Int, contentType: String?): ByteArray {
    val http = url.openConnection() as HttpsURLConnection
    val expired = AtomicBoolean(false)
    val deadline = deadlines.schedule({ expired.set(true); http.disconnect() }, 25, TimeUnit.SECONDS)
    try {
      http.instanceFollowRedirects = false; http.connectTimeout = 15000; http.readTimeout = 20000
      http.setRequestProperty("Authorization", "Bearer ${connection.token}"); http.setRequestProperty("User-Agent", "TofuPOS/0.4.0 (Android)")
      http.setRequestProperty("Cache-Control", "no-store")
      if (data != null) {
        http.requestMethod = "POST"; http.doOutput = true; http.setRequestProperty("Content-Type", contentType ?: "application/json")
        http.setFixedLengthStreamingMode(data.size); http.outputStream.use { it.write(data) }
      }
      val status = http.responseCode; val retryAfter = http.getHeaderField("Retry-After")
      if (status == 401 || status == 403) throw SyncFailure("同期設定のトークンを確認してください", "300", true)
      if (status == 400) throw SyncFailure("送信内容がクラウドで受け付けられませんでした（HTTP 400）", rejected = true)
      if (status != 200) throw SyncFailure("同期できませんでした（HTTP $status）。未同期データは端末に残っています", retryAfter)
      val body = http.inputStream.use { SyncRules.readLimited(it, limit) }
      check(!expired.get()) { "同期がタイムアウトしました。未同期データは端末に残っています" }
      return body
    } catch (error: java.io.IOException) {
      throw SyncFailure(if (expired.get()) "同期がタイムアウトしました。未同期データは端末に残っています" else "通信できませんでした。未同期データは端末に残っています")
    } finally { deadline.cancel(false); http.disconnect() }
  }
}
