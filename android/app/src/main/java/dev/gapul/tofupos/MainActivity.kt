package dev.gapul.tofupos

import android.app.Application
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.runtime.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import androidx.compose.runtime.snapshots.SnapshotStateList
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.Executors

class POSApplication : Application() {
  val worker = Executors.newSingleThreadExecutor()
  // The environment picks the database, photo folder and connection. Store and sync are rebuilt when it changes.
  @Volatile var currentEnvironment = AppEnvironment.PRODUCTION
    private set
  var environment by mutableStateOf(AppEnvironment.PRODUCTION)
    private set
  private var currentStore: POSStore? = null
  private var currentCloud: CloudSync? = null
  val store: POSStore
    @Synchronized get() = currentStore ?: POSStore(this, currentEnvironment.database).also { currentStore = it }
  val cloud: CloudSync
    @Synchronized get() = currentCloud ?: store.let { s -> CloudSync(SyncCredentials(this, currentEnvironment), worker, ProductImages.directory(this)) { s } }.also { currentCloud = it }
  // Bumped when photo files arrive, so thumbnails decoded earlier (or found missing) are read again.
  var imageGeneration by mutableIntStateOf(0)
  override fun onCreate() {
    super.onCreate()
    currentEnvironment = AppEnvironment.parse(getSharedPreferences(AppEnvironment.PREFERENCES, MODE_PRIVATE).getString(AppEnvironment.PREFERENCE_KEY, null))
    environment = currentEnvironment
    worker.execute { runCatching { ProductImages.cleanup(ProductImages.directory(this), store) } }
  }
  var exportCSV: String? = null
  // Sync outlives an Activity recreation; its UI state must do the same.
  var pendingSync by mutableIntStateOf(0)
  var syncRunning by mutableStateOf(false)
  var syncMessage by mutableStateOf("")
  var syncFailed by mutableStateOf(false)
  var lastSentAt by mutableStateOf<String?>(null)
  var lastFeedAt by mutableStateOf<String?>(null)
  // Bumped when cloud data changed local rows (restore, feed, product results); the screen reloads once per bump.
  var restoreGeneration by mutableIntStateOf(0)

  // Online-first: upload after each sale/cancel and on launch. A failed upload is retried once its
  // persisted backoff expires, only while the app is in the foreground. One request at a time.
  private val main = Handler(Looper.getMainLooper())
  private val scheduled = Runnable { requestSync() }
  // Pulls other devices' sales and stock every 60 s while visible. This is a network feed, not DB polling.
  private val periodic: Runnable = Runnable {
    requestSync()
    main.postDelayed(periodic, 60_000)
  }
  private var again = false
  private var foreground = false
  fun foreground(visible: Boolean) {
    foreground = visible
    main.removeCallbacks(periodic)
    if (visible) {
      requestSync(); main.postDelayed(periodic, 60_000)
      cloud.fetchMissingImages { main.post { imageGeneration++ } }
    } else main.removeCallbacks(scheduled)
  }
  fun requestSync() = main.post { sync(null) }
  // A switch requested while a cloud operation runs waits for it; idle() then performs it.
  private var pendingSwitch: Pair<AppEnvironment, (Result<Unit>) -> Unit>? = null
  /**
   * Switches production/test: stops scheduled syncs, closes the current database on the worker, and the next access
   * opens the other environment's store and sync. Returns false when it has to wait for a running sync.
   */
  @android.annotation.SuppressLint("UseKtx") // core-ktx is not a dependency
  fun switchEnvironment(target: AppEnvironment, done: (Result<Unit>) -> Unit): Boolean {
    main.removeCallbacks(scheduled); main.removeCallbacks(periodic); again = false
    if (cloud.running.get() || syncRunning) { pendingSwitch = target to done; return false }
    rebuild(done) {
      check(getSharedPreferences(AppEnvironment.PREFERENCES, MODE_PRIVATE).edit().putString(AppEnvironment.PREFERENCE_KEY, target.key).commit()) { "環境を保存できません" }
      target
    }
    return true
  }
  /** Test environment only: deletes the test database and photos (production is never touched), then re-imports from the test cloud. */
  fun resetTestData(done: (Result<Unit>) -> Unit) {
    if (currentEnvironment != AppEnvironment.TEST) { done(Result.failure(IllegalStateException("テスト環境のときだけ消去できます"))); return }
    if (cloud.running.get() || syncRunning) { done(Result.failure(IllegalStateException("同期中は消去できません"))); return }
    main.removeCallbacks(scheduled); main.removeCallbacks(periodic); again = false
    rebuild(done) {
      synchronized(this) { currentStore?.close(); currentStore = null; currentCloud = null }
      check(AppEnvironment.TEST.database != AppEnvironment.PRODUCTION.database && AppEnvironment.TEST.imageFolder != AppEnvironment.PRODUCTION.imageFolder)
      deleteDatabase(AppEnvironment.TEST.database)
      java.io.File(filesDir, AppEnvironment.TEST.imageFolder).deleteRecursively()
      AppEnvironment.TEST
    }
  }
  /** Closes the current store on the worker; the next access opens [prepare]'s environment from scratch. */
  private fun rebuild(done: (Result<Unit>) -> Unit, prepare: () -> AppEnvironment) {
    worker.execute {
      val result = runCatching {
        val target = prepare()
        synchronized(this) { currentStore?.close(); currentStore = null; currentCloud = null; currentEnvironment = target }
      }
      main.post {
        environment = currentEnvironment
        pendingSync = 0; syncMessage = ""; syncFailed = false; lastSentAt = null; lastFeedAt = null; imageGeneration++; restoreGeneration++
        if (foreground) { requestSync(); main.postDelayed(periodic, 60_000) }
        done(result)
      }
    }
  }
  /** [onError] is set for a manual run; automatic runs only update the status text. */
  /** [onDone] runs on the main thread once this request ends, whether it ran, was skipped or failed. */
  fun sync(onError: ((Throwable) -> Unit)?, onDone: () -> Unit = {}) {
    main.removeCallbacks(scheduled)
    // After 401/403 only a manual send (or saving settings) may contact the cloud again.
    if (onError == null && cloud.halted) { onDone(); return }
    if (cloud.running.get()) { again = true; onDone(); return }
    worker.execute {
      if (runCatching { cloud.connection() }.getOrNull() == null) {
        main.post { onError?.invoke(IllegalStateException("先に同期設定をしてください")); onDone() }; return@execute
      }
      main.post {
        if (cloud.running.get()) { again = true; onDone(); return@post }
        syncRunning = true
        cloud.run(manual = onError != null) { result -> main.post {
          syncRunning = cloud.running.get(); syncMessage = cloud.lastMessage
          result.fold({
            pendingSync = it.pending; syncMessage = it.message; syncFailed = false
            java.time.Instant.now().toString().let { now -> lastSentAt = now; lastFeedAt = now }
            if (it.changed) restoreGeneration++
            if (it.images > 0) imageGeneration++
          }, {
            syncMessage = it.message ?: "同期に失敗しました"; onError?.invoke(it)
            // Waiting out a persisted backoff is not a new failure; keep the previous state.
            if (!syncMessage.startsWith("待機中")) syncFailed = true
          })
          idle(cloud.autoRetryAt)
          onDone()
        } }
      }
    }
  }
  /** Called when any cloud operation ends, so a sale recorded meanwhile is not left waiting. */
  fun idle(retryAt: Double? = null) {
    pendingSwitch?.let { (target, done) -> if (!cloud.running.get()) { pendingSwitch = null; switchEnvironment(target, done); return } }
    if (again) { again = false; requestSync(); return }
    if (retryAt != null && foreground) main.postDelayed(scheduled, ((retryAt - System.currentTimeMillis() / 1000.0) * 1000).toLong().coerceAtLeast(1000))
  }
}

@Suppress("DEPRECATION")
class MainActivity : ComponentActivity() {
  private val app get() = application as POSApplication
  private var products by mutableStateOf(emptyList<Product>())
  private var pendingQuantities by mutableStateOf(emptyMap<String, Long>())
  private var deviceID by mutableStateOf("")
  private var drawer by mutableStateOf<DrawerSession?>(null)
  private var advanced by mutableStateOf(false)
  private var single by mutableStateOf(SingleState())
  private var refreshing by mutableStateOf(false)
  private val snackbar = SnackbarHostState()
  private var scope: CoroutineScope? = null
  private var held by mutableStateOf(Held())
  private var age by mutableStateOf<String?>(null)
  private var gender by mutableStateOf<String?>(null)
  private var group by mutableStateOf<String?>(null)
  // Bumped after each sale (and environment switch) so the customer pager returns to its first page.
  private var customerEpoch by mutableIntStateOf(0)
  private var ticketPrefix by mutableStateOf("")
  private var stockEdit by mutableStateOf<StockEdit?>(null)
  private var sales by mutableStateOf(emptyList<Sale>())
  private var pendingSync: Int
    get() = app.pendingSync
    set(value) { app.pendingSync = value }
  private val cart: SnapshotStateList<Line> = mutableStateListOf()
  private var commandID = UUID.randomUUID().toString()
  private var cash by mutableStateOf("")
  private var tab by mutableIntStateOf(0)
  private var busy by mutableStateOf(true)
  private var ready by mutableStateOf(false)
  private var syncRunning: Boolean
    get() = app.syncRunning
    set(value) { app.syncRunning = value }
  private var syncMessage: String
    get() = app.syncMessage
    set(value) { app.syncMessage = value }
  private var error by mutableStateOf<String?>(null)
  private var productEditor by mutableStateOf<ProductEdit?>(null)
  private var cancelSale by mutableStateOf<Sale?>(null)
  private var confirmation by mutableStateOf<Checkout?>(null)
  private var savedSale by mutableStateOf<Sale?>(null)
  private var settings by mutableStateOf<ConnectionEdit?>(null)
  private var catalogs by mutableStateOf<List<Catalog>?>(null)
  private var catalogNext by mutableStateOf<String?>(null)
  private var restoreChoice by mutableStateOf<RestoreChoice?>(null)
  private var canContinueRestore by mutableStateOf(false)
  private var loadedRestoreGeneration = 0

  override fun onCreate(state: Bundle?) {
    super.onCreate(state)
    enableEdgeToEdge()
    state?.let {
      commandID = it.getString("commandID") ?: commandID
      cash = it.getString("cash").orEmpty()
      tab = it.getInt("selectedTab", 0).coerceIn(0, 3)
      advanced = it.getBoolean("advanced")
      single = SingleState(it.getInt("singleQuantity", 1).coerceIn(1, 999), it.getString("singleTender"), it.getString("singleManual").orEmpty())
      age = it.getString("age"); gender = it.getString("gender"); group = it.getString("group")
      val rows = JSONArray(it.getString("cart") ?: "[]")
      for (i in 0 until rows.length()) {
        val row = rows.getJSONObject(i)
        cart += Line(row.getString("id"), row.getString("name"), row.getLong("price"), row.getInt("quantity"))
      }
    }
    syncRunning = app.cloud.running.get()
    syncMessage = app.cloud.lastMessage
    setContent {
      scope = rememberCoroutineScope()
      LaunchedEffect(app.restoreGeneration,busy) { if (!busy && loadedRestoreGeneration < app.restoreGeneration) load() }
      TofuTheme {
        val stocks = products.associate { it.id to Cash.displayedStock(it.cloudStock, pendingQuantities[it.id] ?: 0) }
        val summary = drawer?.let { session -> Cash.summary(sales, deviceID, session.openedAt, null) }
        POSScreen(
          products, sales, cart, cash, tab, ready, busy, pendingSync, syncRunning, syncMessage,
          ScreenExtras(stocks, age, gender, drawer, summary, app.lastFeedAt, deviceLabel, held, deviceID, app.lastSentAt, app.syncFailed, app.imageGeneration, app.environment,
            group = group, customerEpoch = customerEpoch, ticketPrefix = ticketPrefix),
          onTab = { tab = it }, onCash = { cash = it }, onQuantity = ::quantity,
          onExact = { runCatching { Money.total(cart) }.getOrNull()?.let { cash = it.toString() } },
          onCashSet = { cash = it.toString() },
          onCashAdd = { add -> cash = ((Money.parse(cash) ?: 0) + add).coerceAtMost(Money.MAXIMUM).toString() },
          // Customer segment is optional; tapping the selected chip clears it.
          onAge = { age = if (age == it) null else it }, onGender = { gender = if (gender == it) null else it },
          onGroup = { group = if (group == it) null else it },
          onTicketPrefix = { value -> work({ app.store.setTicketPrefix(value); app.store.ticketPrefix() }) { ticketPrefix = it; Toast.makeText(this, "接頭辞を保存しました", Toast.LENGTH_SHORT).show() } },
          onCheckout = ::confirmCheckout, onEdit = { productEditor = ProductEdit(it) },
          onStock = { product, kind -> stockEdit = StockEdit(product, kind) },
          onOpenDrawer = { counts -> work({ app.store.openSession(counts) }) { load(); app.requestSync() } },
          onCloseDrawer = ::closeDrawer,
          onCancel = { cancelSale = it }, onExport = ::export, onSync = ::sync,
          onSettings = ::openSettings, onImport = ::importSettings,
          canContinue = canContinueRestore, onBackup = ::backupProducts, onRestore = { listBackups() },
          onContinue = { restoreChoice = RestoreChoice(null,true) },
          advanced = advanced, onAdvanced = { advanced = it },
          single = single, onSingle = { single = it }, onSingleConfirm = ::confirmSingle, snackbar = snackbar,
          onEnvironment = ::switchEnvironment, onResetTest = ::resetTestData, refreshing = refreshing, onRefresh = ::refresh
        )
        productEditor?.let { editor ->
          ProductDialog(editor.product, busy, editor.picked, editor.token, app.imageGeneration, onPick = ::importPhoto, onDismiss = { productEditor = null }) { name, price, active, stop, image ->
            val updated = editor.product?.copy(name = name, price = price, active = active, stopAtZero = stop, imageHash = image)
              ?: Product(name = name, price = price, active = active, stopAtZero = stop, imageHash = image)
            work({ app.store.saveProduct(updated) }) { productEditor = null; load(); app.requestSync() }
          }
        }
        stockEdit?.let { edit ->
          StockDialog(edit.product, edit.kind, stocks[edit.product.id], busy, onDismiss = { stockEdit = null }) { quantity, reason ->
            work({ app.store.addStockEvent(edit.product.id, edit.kind, quantity, reason) }) { stockEdit = null; load(); app.requestSync() }
          }
        }
        cancelSale?.let { sale ->
          CancelDialog(sale, busy, onDismiss = { cancelSale = null }) { reason ->
            work({ app.store.cancel(sale.id, reason) }) { cancelSale = null; load(); app.requestSync() }
          }
        }
        confirmation?.let { checkout ->
          CheckoutDialog(checkout, busy, onDismiss = { confirmation = null }) {
            if (!busy) work({ app.store.checkout(checkout.id, checkout.lines, checkout.received, checkout.age, checkout.gender, checkout.group) }) { sale ->
              confirmation = null; clearCart(); savedSale = sale; load(); app.requestSync()
            }
          }
        }
        savedSale?.let { ReceiptDialog(it) { savedSale = null } }
        settings?.let { connection ->
          ConnectionDialog(connection.url, busy || syncRunning, onDismiss = { settings = null }) { url, token ->
            work({ app.cloud.configure(url, token) }) { settings = null; syncMessage = app.cloud.lastMessage; app.requestSync() }
          }
        }
        catalogs?.let { list -> CatalogDialog(list, catalogNext != null, syncRunning, { catalogNext?.let { listBackups(it) } }, { catalogs = null }) { selected ->
          catalogs = null; restoreChoice = RestoreChoice(selected,false)
        } }
        restoreChoice?.let { choice -> RestoreConfirmDialog(choice.catalog, choice.continuation, { restoreChoice = null }) {
          restoreChoice = null
          cloudAction({ app.cloud.restore(choice.catalog?.id,choice.continuation,it) }) { app.restoreGeneration++ }
        } }
        error?.let { ErrorDialog(it) { error = null } }
      }
    }
    load()
  }

  override fun onStart() { super.onStart(); app.foreground(true) }
  override fun onStop() { app.foreground(false); super.onStop() }

  override fun onSaveInstanceState(out: Bundle) {
    out.putString("commandID", commandID); out.putString("cash", cash); out.putInt("selectedTab", tab)
    out.putString("age", age); out.putString("gender", gender); out.putString("group", group); out.putBoolean("advanced", advanced)
    out.putInt("singleQuantity", single.quantity); out.putString("singleTender", single.tender); out.putString("singleManual", single.manual)
    out.putString("cart", JSONArray().apply {
      cart.forEach { put(JSONObject().put("id", it.productID).put("name", it.name).put("price", it.price).put("quantity", it.quantity)) }
    }.toString())
    super.onSaveInstanceState(out)
  }

  private fun load() {
    val generation = app.restoreGeneration
    work({
      val store = app.store
      Loaded(store.products(), store.sales(), store.pendingCount(), store.restoreCursor().second.isNotEmpty(),
        store.pendingQuantities(), store.deviceID(), store.currentSession(), store.lastFeedAt(), store.lastSentAt(),
        store.rejectedCounts().let { (p, s, d) -> Held(p, s, d, store.conflictCount(), store.rejectedImageCount()) }, store.ticketPrefix())
    }) { loaded ->
      val (p, s, pending, more) = loaded
      pendingQuantities = loaded.quantities; deviceID = loaded.deviceID; drawer = loaded.drawer; app.lastFeedAt = loaded.lastFeedAt; app.lastSentAt = loaded.lastSentAt; held = loaded.held; ticketPrefix = loaded.ticketPrefix
      loadedRestoreGeneration = generation
      canContinueRestore = more
      products = p; sales = s; pendingSync = pending; ready = true
      val recovered = sales.firstOrNull { it.id == commandID }
      if (recovered != null && cart.isNotEmpty()) { clearCart(); savedSale = recovered }
      else if (recovered != null) { commandID = UUID.randomUUID().toString(); single = SingleState() } // single-product sale saved before a restart
      syncRunning = app.cloud.running.get(); syncMessage = app.cloud.lastMessage
    }
  }

  private fun <T> work(task: () -> T, success: (T) -> Unit) {
    if (busy && ready) return
    busy = true
    app.worker.execute {
      val result = runCatching(task)
      runOnUiThread {
        if (isDestroyed) return@runOnUiThread
        busy = false
        result.fold(success, ::failure)
      }
    }
  }

  private fun quantity(productID: String, delta: Int) {
    if (busy || !ready) return
    val index = cart.indexOfFirst { it.productID == productID }
    if (index < 0) {
      val product = products.firstOrNull { it.id == productID } ?: return
      if (delta > 0 && product.active && Cash.canAdd(product.stopAtZero, stockOf(product), 0)) cart += Line(product.id, product.name, product.price, 1)
    } else {
      val count = cart[index].quantity + delta
      val product = products.firstOrNull { it.id == productID }
      if (delta > 0 && product != null && !Cash.canAdd(product.stopAtZero, stockOf(product), count - 1)) return
      if (count <= 0) cart.removeAt(index)
      else if (count <= 999) cart[index] = cart[index].copy(quantity = count)
    }
    cash = ""
  }

  private fun confirmCheckout() {
    if (busy || !ready || cart.isEmpty()) return
    val total = runCatching { Money.total(cart) }.getOrNull()
    val received = Money.parse(cash)
    if (total == null || received == null || received < total) {
      failure(IllegalArgumentException("商品・数量・預り金を確認してください")); return
    }
    confirmation = Checkout(commandID, cart.toList(), total, received, age, gender, group)
  }
  /** One tap, no dialogs. The command ID plus the busy guard keep a double tap from saving twice. */
  private fun confirmSingle() {
    if (busy || !ready) return
    val product = products.singleOrNull { it.active } ?: return
    val state = single
    if (!state.canConfirm(product.price, product.stopAtZero, stockOf(product))) return
    val total = state.total(product.price) ?: return; val received = state.received(total) ?: return
    val id = commandID; val customerAge = age; val customerGender = gender; val customerGroup = group
    work({ app.store.checkout(id, listOf(Line(product.id, product.name, product.price, state.quantity)), received, customerAge, customerGender, customerGroup) }) { sale ->
      single = SingleState(); age = null; gender = null; group = null; customerEpoch++; commandID = UUID.randomUUID().toString()
      load(); app.requestSync(); offerUndo(sale, state.quantity)
    }
  }
  private fun offerUndo(sale: Sale, quantity: Int) {
    snackbar.currentSnackbarData?.dismiss()
    scope?.launch {
      val result = withTimeoutOrNull(6000) {
        snackbar.showSnackbar((if (app.environment == AppEnvironment.TEST) "【テスト】" else "") + (sale.ticketNo?.let { "\n整理番号 $it\n" } ?: "\n") + "${yen(sale.total)}（${quantity}本）を保存しました・お釣り ${yen(sale.change)}", "取消", duration = SnackbarDuration.Indefinite)
      }
      if (result != SnackbarResult.ActionPerformed || isDestroyed) return@launch
      if (busy) { failure(IllegalStateException("処理中のため取消できませんでした。履歴から取消してください")); return@launch }
      work({ app.store.cancel(sale.id, "確定直後の取消") }) {
        load(); app.requestSync(); Toast.makeText(this@MainActivity, "取消を記録しました", Toast.LENGTH_SHORT).show()
      }
    }
  }
  /** Shrinks, hashes and stores the picked photo as an unsent image; the product refers to it once saved. */
  private fun importPhoto(uri: android.net.Uri) = work({
    val (hash, bytes) = ProductImages.import(this, uri)
    ProductImages.save(ProductImages.directory(this), hash, bytes)
    app.store.registerImage(hash, uploaded = false); hash
  }) { hash -> productEditor = productEditor?.let { it.copy(picked = hash, token = it.token + 1) } }
  /** Drops every piece of screen state (cart, dialogs, loaded rows) and reloads from the other environment's database. */
  private fun switchEnvironment(target: AppEnvironment) {
    if (busy) { failure(IllegalStateException("保存中です。少し待ってから切り替えてください")); return }
    busy = true
    val now = app.switchEnvironment(target) { result ->
      if (isDestroyed) return@switchEnvironment
      busy = false
      result.onFailure(::failure)
      resetScreen()
      Toast.makeText(this, "${app.environment.label}環境に切り替えました", Toast.LENGTH_SHORT).show()
    }
    if (!now) Toast.makeText(this, "同期の完了後に切り替えます", Toast.LENGTH_SHORT).show()
  }
  private fun resetTestData() {
    if (busy || syncRunning || app.cloud.running.get()) { failure(IllegalStateException("同期・保存中は消去できません")); return }
    busy = true
    app.resetTestData { result ->
      if (isDestroyed) return@resetTestData
      busy = false
      result.onFailure(::failure)
      resetScreen()
      Toast.makeText(this, "テストデータを消去しました", Toast.LENGTH_SHORT).show()
    }
  }
  /** Drops every piece of screen state (cart, dialogs, loaded rows) and reloads from the current environment's database. */
  private fun resetScreen() {
      snackbar.currentSnackbarData?.dismiss()
      cart.clear(); cash = ""; age = null; gender = null; group = null; customerEpoch++; ticketPrefix = ""; single = SingleState(); commandID = UUID.randomUUID().toString()
      productEditor = null; stockEdit = null; cancelSale = null; confirmation = null; savedSale = null; settings = null
      catalogs = null; catalogNext = null; restoreChoice = null; canContinueRestore = false
      products = emptyList(); sales = emptyList(); pendingQuantities = emptyMap(); drawer = null; held = Held(); deviceID = ""
      tab = 0; ready = false; syncMessage = app.syncMessage
      load()
  }
  private fun stockOf(product: Product) = Cash.displayedStock(product.cloudStock, pendingQuantities[product.id] ?: 0)
  private val deviceLabel get() = CodePoints.deviceLabel(android.os.Build.MODEL)
  private fun closeDrawer(counts: Map<String, Int>) {
    val session = drawer ?: return
    work({ app.store.closeSession(session.id, counts) }) { closed ->
      load(); app.requestSync()
      val difference = (closed.countedTotal ?: 0) - (closed.expectedTotal ?: 0)
      Toast.makeText(this, "レジを締めました（差額 ${if (difference > 0) "+" else ""}${difference}円）", Toast.LENGTH_LONG).show()
    }
  }
  private fun clearCart() { cart.clear(); cash = ""; age = null; gender = null; group = null; customerEpoch++; commandID = UUID.randomUUID().toString() }
  private fun failure(cause: Throwable) { error = cause.message ?: "処理に失敗しました" }

  private fun sync() {
    if (syncRunning) return
    app.sync({ if (!isDestroyed) failure(it) })
  }
  /** Pull to refresh: one manual cycle, or only a reload while waiting out the backoff or already syncing. */
  private fun refresh() {
    if (refreshing) return
    refreshing = true
    app.worker.execute {
      val waiting = runCatching { app.store.syncGate().first > System.currentTimeMillis() / 1000.0 }.getOrDefault(true) || app.cloud.running.get()
      runOnUiThread {
        if (isDestroyed) return@runOnUiThread
        if (waiting || syncRunning) { refreshing = false; load() }
        else app.sync({ if (!isDestroyed) failure(it) }) { refreshing = false; load() }
      }
    }
  }
  private fun <T> cloudAction(task: ((Result<T>) -> Unit) -> Unit, success: (T) -> Unit) {
    if (syncRunning) return
    syncRunning = true
    task { result -> runOnUiThread {
      syncRunning = app.cloud.running.get(); syncMessage = app.cloud.lastMessage
      result.fold(success, { if (!isDestroyed) failure(it) })
      app.idle()
    } }
  }
  private fun backupProducts() = cloudAction(app.cloud::backupProducts) { }
  private fun listBackups(before: String? = null) = cloudAction({ app.cloud.catalogs(before,it) }) { page ->
    if (before == null) catalogs = page.catalogs else catalogs = catalogs?.plus(page.catalogs)
    catalogNext = page.next
  }
  private fun openSettings() {
    if (syncRunning) return
    work({ app.cloud.connection() }) { settings = ConnectionEdit(it?.url.orEmpty()) }
  }
  private fun importSettings() {
    if (syncRunning || app.cloud.running.get()) { failure(IllegalStateException("同期完了後に設定してください")); return }
    startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
      addCategory(Intent.CATEGORY_OPENABLE); type = "application/json"
    }, 101)
  }
  private fun export() {
    app.exportCSV = SalesCSV.make(sales)
    startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
      addCategory(Intent.CATEGORY_OPENABLE); type = "text/csv"; putExtra(Intent.EXTRA_TITLE, "tofu-pos-sales.csv")
    }, 100)
  }
  override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
    super.onActivityResult(requestCode, resultCode, data)
    if (requestCode == 101) {
      if (resultCode != RESULT_OK) return
      val uri = data?.data ?: return
      work({
        val stream = contentResolver.openInputStream(uri) ?: error("設定ファイルを開けません")
        val json = stream.use { JSONObject(String(SyncRules.readLimited(it, 4096), Charsets.UTF_8)) }
        app.cloud.configure(json.getString("url"), json.getString("token"))
        app.store.pendingCount()
      }) {
        pendingSync = it; syncMessage = app.cloud.lastMessage
        Toast.makeText(this, "接続設定を保存しました", Toast.LENGTH_LONG).show()
        app.requestSync()
      }
      return
    }
    if (requestCode != 100) return
    val csv = app.exportCSV; app.exportCSV = null
    if (resultCode != RESULT_OK) return
    val uri = data?.data
    if (uri == null || csv == null) { failure(IllegalStateException("もう一度CSV書き出しを実行してください")); return }
    work({
      val stream = contentResolver.openOutputStream(uri, "wt") ?: error("保存先を開けません")
      stream.use { it.write(csv.toByteArray(Charsets.UTF_8)) }
    }) { Toast.makeText(this, "CSVを保存しました", Toast.LENGTH_LONG).show() }
  }
}

data class Checkout(val id: String, val lines: List<Line>, val total: Long, val received: Long, val age: String? = null, val gender: String? = null, val group: String? = null)
private data class StockEdit(val product: Product, val kind: String)
private data class ProductEdit(val product: Product?, val picked: String? = null, val token: Int = 0)
private data class ConnectionEdit(val url: String)

private data class RestoreChoice(val catalog: Catalog?, val continuation: Boolean)
private data class Loaded(
  val products: List<Product>, val sales: List<Sale>, val pending: Int, val more: Boolean,
  val quantities: Map<String, Long>, val deviceID: String, val drawer: DrawerSession?, val lastFeedAt: String?, val lastSentAt: String?, val held: Held, val ticketPrefix: String
)
