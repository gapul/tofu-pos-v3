package dev.gapul.tofupos

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import org.json.JSONObject
import java.time.Instant
import java.util.UUID

data class ProductResult(val conflict: Boolean, val product: Product)
data class StockEvent(val id: String, val productID: String, val kind: String, val quantity: Long, val reason: String?, val createdAt: String)
data class FeedResult(val products: Int, val orders: Int, val cancellations: Int)
private enum class Merge { ADDED, CANCELLED, SAME, CONFLICT }

class POSStore(context: Context, name: String = "tofu-pos.sqlite") : SQLiteOpenHelper(context, name, null, 3) {
  override fun onConfigure(db: SQLiteDatabase) {
    db.setForeignKeyConstraintsEnabled(true)
    db.execSQL("PRAGMA synchronous=FULL")
  }
  override fun onCreate(db: SQLiteDatabase) {
    db.execSQL("CREATE TABLE products(id TEXT PRIMARY KEY,name TEXT NOT NULL,price INTEGER NOT NULL CHECK(price>=0 AND price<=1000000000))")
    db.execSQL("CREATE TABLE orders(id TEXT PRIMARY KEY,created_at TEXT NOT NULL,total INTEGER NOT NULL,received INTEGER NOT NULL,change_yen INTEGER NOT NULL,cancelled_at TEXT,cancellation_reason TEXT)")
    db.execSQL("CREATE TABLE order_lines(order_id TEXT NOT NULL REFERENCES orders(id),line_no INTEGER NOT NULL,product_id TEXT NOT NULL,name TEXT NOT NULL,price INTEGER NOT NULL,quantity INTEGER NOT NULL CHECK(quantity BETWEEN 1 AND 999),PRIMARY KEY(order_id,line_no))")
    addSyncSchema(db)
    addVersion3(db)
  }
  override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
    check(oldVersion in 1..2 && newVersion == 3) { "未対応のDBバージョンです。データを削除せず確認してください" }
    if (oldVersion < 2) addSyncSchema(db)
    addVersion3(db)
  }
  private fun addSyncSchema(db: SQLiteDatabase) {
    db.execSQL("ALTER TABLE orders ADD COLUMN revision INTEGER NOT NULL DEFAULT 1")
    db.execSQL("ALTER TABLE orders ADD COLUMN synced_revision INTEGER NOT NULL DEFAULT 0")
    db.execSQL("ALTER TABLE orders ADD COLUMN sync_error TEXT")
    db.execSQL("UPDATE orders SET revision=2 WHERE cancelled_at IS NOT NULL")
    db.execSQL("CREATE INDEX pending_sync ON orders(id) WHERE synced_revision<revision")
    db.execSQL("CREATE TABLE sync_metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)")
  }
  // Existing products stay unsent (dirty=1, version 0) so the first cycle registers them in the cloud catalog.
  private fun addVersion3(db: SQLiteDatabase) {
    // cancelled_here marks refunds paid from this device's drawer; restore and feed leave it 0. Not part of the payload.
    listOf("device_id TEXT", "customer_age TEXT", "customer_gender TEXT", "cancelled_here INTEGER NOT NULL DEFAULT 0").forEach { db.execSQL("ALTER TABLE orders ADD COLUMN $it") }
    // track_stock stays for the schema but is always 1: every product keeps (possibly negative) stock.
    // sync_error='rejected': the cloud answered 400 for that item; it is kept locally and left out of automatic sync.
    listOf("active INTEGER NOT NULL DEFAULT 1", "track_stock INTEGER NOT NULL DEFAULT 1", "stop_at_zero INTEGER NOT NULL DEFAULT 0", "version INTEGER NOT NULL DEFAULT 0",
      "cloud_stock INTEGER", "dirty INTEGER NOT NULL DEFAULT 1", "sync_error TEXT", "image_hash TEXT").forEach { db.execSQL("ALTER TABLE products ADD COLUMN $it") }
    // Photo files live in filesDir/product-images/<hash>.jpg; only their upload state is kept here.
    db.execSQL("CREATE TABLE local_images(hash TEXT PRIMARY KEY,uploaded INTEGER NOT NULL DEFAULT 0,created_at TEXT NOT NULL,sync_error TEXT)")
    db.execSQL("CREATE TABLE stock_events(id TEXT PRIMARY KEY,product_id TEXT NOT NULL,kind TEXT NOT NULL,quantity INTEGER NOT NULL,reason TEXT,created_at TEXT NOT NULL,synced INTEGER NOT NULL DEFAULT 0,sync_error TEXT)")
    db.execSQL("CREATE TABLE drawer_sessions(id TEXT PRIMARY KEY,opened_at TEXT NOT NULL,closed_at TEXT,float_json TEXT NOT NULL,float_total INTEGER NOT NULL,counted_json TEXT,counted_total INTEGER,expected_total INTEGER,sales_total INTEGER,cancel_total INTEGER,order_count INTEGER,synced INTEGER NOT NULL DEFAULT 0,sync_error TEXT)")
    db.execSQL("CREATE UNIQUE INDEX one_open_drawer ON drawer_sessions((closed_at IS NULL)) WHERE closed_at IS NULL")
    db.execSQL("INSERT OR IGNORE INTO sync_metadata VALUES('device_id',?)", arrayOf(UUID.randomUUID().toString()))
  }
  fun deviceID(): String = query("SELECT value FROM sync_metadata WHERE key='device_id'").single().single()
  fun products(): List<Product> = query("SELECT $PRODUCT FROM products ORDER BY rowid").map(::makeProduct)
  private fun product(id: String) = query("SELECT $PRODUCT FROM products WHERE id=?", arrayOf(id)).firstOrNull()?.let(::makeProduct)
  private fun makeProduct(it: List<String>) = Product(it[0], it[1], it[2].toLong(), it[3] == "1", it[4] == "1", it[5].toLong(), it[6].toLongOrNull(), it[7] == "1", it[8].ifEmpty { null })
  fun saveProduct(product: Product) {
    val name = product.name.trim()
    require(name.isNotEmpty() && CodePoints.length(name) <= 100 && product.price in 0..Money.MAXIMUM) { "商品名（100文字以内）と価格を確認してください" }
    require(product.imageHash == null || ProductImages.isHash(product.imageHash)) { "写真を確認してください" }
    // UPDATE + INSERT avoids ON CONFLICT DO UPDATE, unavailable in older platform SQLite.
    transaction {
      val active = if (product.active) 1L else 0L; val stop = if (product.stopAtZero) 1L else 0L
      val changed = writableDatabase.compileStatement("UPDATE products SET name=?,price=?,active=?,stop_at_zero=?,image_hash=?,track_stock=1,dirty=1,sync_error=NULL WHERE id=?").use {
        it.bindString(1, name); it.bindLong(2, product.price); it.bindLong(3, active); it.bindLong(4, stop)
        if (product.imageHash == null) it.bindNull(5) else it.bindString(5, product.imageHash); it.bindString(6, product.id); it.executeUpdateDelete()
      }
      if (changed == 0) writableDatabase.execSQL("INSERT INTO products(id,name,price,active,stop_at_zero,image_hash) VALUES(?,?,?,?,?,?)", arrayOf<Any?>(product.id, name, product.price, active, stop, product.imageHash))
    }
  }
  fun dirtyProducts(): List<Product> = query("SELECT $PRODUCT FROM products WHERE dirty=1 AND sync_error IS NULL AND (image_hash IS NULL OR image_hash IN (SELECT hash FROM local_images WHERE uploaded=1)) ORDER BY rowid LIMIT 100").map(::makeProduct)
  /** A product edited again while its upload was in flight keeps the newer local content, now based on the server version. */
  fun applyProductResults(sent: List<Product>, results: List<ProductResult>) = transaction {
    val before = sent.associateBy { it.id }
    results.forEach { r ->
      val local = product(r.product.id); val base = before.getValue(r.product.id)
      if (local != null && !(local.sameContent(base) && local.version == base.version))
        writableDatabase.execSQL("UPDATE products SET version=?,cloud_stock=? WHERE id=?", arrayOf(r.product.version, r.product.cloudStock, r.product.id))
      else writeCloudProduct(r.product, local != null)
    }
  }
  private fun writeCloudProduct(p: Product, exists: Boolean) {
    val values = arrayOf(p.name, p.price, if (p.active) 1 else 0, if (p.stopAtZero) 1 else 0, p.version, p.cloudStock, p.imageHash, p.id)
    if (exists) writableDatabase.execSQL("UPDATE products SET name=?,price=?,active=?,stop_at_zero=?,track_stock=1,version=?,cloud_stock=?,image_hash=?,dirty=0 WHERE id=?", values)
    else writableDatabase.execSQL("INSERT INTO products(name,price,active,stop_at_zero,version,cloud_stock,image_hash,dirty,id) VALUES(?,?,?,?,?,?,?,0,?)", values)
    // A hash the cloud sent us exists there, so products using it may be sent without uploading it again.
    p.imageHash?.let { registerImage(it, uploaded = true) }
  }
  fun addStockEvent(productID: String, kind: String, quantity: Long, reason: String?) {
    val note = reason?.trim()?.ifEmpty { null }
    require(when (kind) { "set" -> quantity in 0..1_000_000; "add" -> quantity in -1_000_000..1_000_000 && quantity != 0L; else -> false }) { "数量を確認してください" }
    require(note == null || CodePoints.length(note) <= 200) { "メモは200文字以内です" }
    transaction {
      require(product(productID) != null) { "商品がありません" }
      writableDatabase.execSQL("INSERT INTO stock_events(id,product_id,kind,quantity,reason,created_at) VALUES(?,?,?,?,?,?)",
        arrayOf(UUID.randomUUID().toString(), productID, kind, quantity, note, Instant.now().toString()))
    }
  }
  fun pendingStockEvents(): List<StockEvent> = query("SELECT id,product_id,kind,quantity,reason,created_at FROM stock_events WHERE synced=0 AND sync_error IS NULL ORDER BY rowid LIMIT 100")
    .map { StockEvent(it[0], it[1], it[2], it[3].toLong(), it[4].ifEmpty { null }, it[5]) }
  fun markStockSynced(ids: List<String>, products: List<Product>) = transaction {
    ids.forEach { writableDatabase.execSQL("UPDATE stock_events SET synced=1 WHERE id=?", arrayOf(it)) }
    products.forEach { writableDatabase.execSQL("UPDATE products SET cloud_stock=? WHERE id=?", arrayOf(it.cloudStock, it.id)) }
  }
  /** Unsynced, not cancelled sales per product; the cloud stock does not include them yet. */
  fun pendingQuantities(): Map<String, Long> = query("SELECT l.product_id,SUM(l.quantity) FROM order_lines l JOIN orders o ON o.id=l.order_id WHERE o.synced_revision<o.revision AND o.cancelled_at IS NULL GROUP BY l.product_id")
    .associate { it[0] to it[1].toLong() }
  fun checkout(id: String, lines: List<Line>, received: Long, age: String? = null, gender: String? = null): Sale = transaction {
    sale(id)?.let {
      require(it.lines == lines && it.received == received) { "同じ会計IDで内容が異なります" }
      return@transaction it
    }
    val total = Money.total(lines)
    require(id.isNotEmpty() && received >= total && received <= Money.MAXIMUM) { "預り金が不足しているか上限を超えています" }
    require(Customer.validAge(age) && Customer.validGender(gender)) { "客層を確認してください" }
    writableDatabase.execSQL("INSERT INTO orders(id,created_at,total,received,change_yen,device_id,customer_age,customer_gender) VALUES(?,?,?,?,?,?,?,?)",
      arrayOf<Any?>(id, Instant.now().toString(), total, received, received - total, deviceID(), age, gender))
    lines.forEachIndexed { index, line ->
      writableDatabase.execSQL("INSERT INTO order_lines VALUES(?,?,?,?,?,?)", arrayOf<Any>(id, index + 1, line.productID, line.name, line.price, line.quantity))
    }
    checkNotNull(sale(id))
  }
  fun cancel(id: String, reason: String) {
    val clean = reason.trim()
    require(clean.isNotEmpty() && CodePoints.length(clean) <= 200) { "取消理由（200文字以内）を入力してください" }
    transaction {
      val current = sale(id)
      require(current != null && current.cancelledAt == null) { "取消済み、または注文がありません" }
      writableDatabase.execSQL("UPDATE orders SET cancelled_at=?,cancellation_reason=?,revision=2,cancelled_here=1 WHERE id=? AND cancelled_at IS NULL", arrayOf(Instant.now().toString(), clean, id))
    }
  }
  fun sales(): List<Sale> {
    val orders = query("SELECT $ORDER FROM orders ORDER BY created_at DESC,rowid DESC")
    val details = query("SELECT order_id,product_id,name,price,quantity FROM order_lines ORDER BY order_id,line_no").groupBy { it[0] }
    return orders.map { makeSale(it, details[it[0]].orEmpty()) }
  }
  fun pendingCount(): Int = query("SELECT COUNT(*) FROM orders WHERE synced_revision<revision").single().single().toInt()
  fun pendingSales(): List<PendingSale> {
    val rows = query("SELECT $ORDER,revision FROM orders WHERE synced_revision<revision AND sync_error IS NULL ORDER BY id LIMIT 50")
    if (rows.isEmpty()) return emptyList()
    val marks = rows.joinToString(",") { "?" }
    val details = query("SELECT order_id,product_id,name,price,quantity FROM order_lines WHERE order_id IN ($marks) ORDER BY order_id,line_no", rows.map { it[0] }.toTypedArray()).groupBy { it[0] }
    return rows.map { PendingSale(makeSale(it, details[it[0]].orEmpty()), it[11].toInt()) }
  }
  fun acknowledge(receipts: List<SyncReceipt>) {
    if (receipts.isEmpty()) return
    transaction {
      receipts.forEach {
        require(it.revision in 1..2)
        writableDatabase.execSQL("UPDATE orders SET synced_revision=MAX(synced_revision,CAST(? AS INTEGER)) WHERE id=? AND revision>=?", arrayOf<Any>(it.revision, it.id, it.revision))
      }
    }
  }
  fun holdSync(ids: List<String>) {
    if (ids.isEmpty()) return
    transaction { ids.forEach { writableDatabase.execSQL("UPDATE orders SET sync_error='payload_too_large' WHERE id=?", arrayOf(it)) } }
  }
  fun heldSyncCount(): Int = query("SELECT COUNT(*) FROM orders WHERE synced_revision<revision AND sync_error='payload_too_large'").single().single().toInt()
  /** Conflicting orders leave automatic sync; a manual send releases them for one more attempt. */
  fun holdConflicts(ids: List<String>) = transaction { ids.forEach { writableDatabase.execSQL("UPDATE orders SET sync_error='conflict' WHERE id=? AND synced_revision<revision", arrayOf(it)) } }
  fun releaseConflicts() = writableDatabase.execSQL("UPDATE orders SET sync_error=NULL WHERE sync_error='conflict'")
  fun conflictCount(): Int = query("SELECT COUNT(*) FROM orders WHERE synced_revision<revision AND sync_error='conflict'").single().single().toInt()
  fun rejectProducts(ids: List<String>) = transaction { ids.forEach { writableDatabase.execSQL("UPDATE products SET sync_error='rejected' WHERE id=? AND dirty=1", arrayOf(it)) } }
  fun rejectStockEvents(ids: List<String>) = transaction { ids.forEach { writableDatabase.execSQL("UPDATE stock_events SET sync_error='rejected' WHERE id=?", arrayOf(it)) } }
  fun rejectSessions(sent: List<DrawerSession>) = transaction { sent.forEach { writableDatabase.execSQL("UPDATE drawer_sessions SET sync_error='rejected' WHERE id=? AND closed_at IS ?", arrayOf(it.id, it.closedAt)) } }
  fun registerImage(hash: String, uploaded: Boolean) {
    require(ProductImages.isHash(hash))
    writableDatabase.execSQL("INSERT OR IGNORE INTO local_images(hash,uploaded,created_at) VALUES(?,?,?)", arrayOf<Any>(hash, if (uploaded) 1 else 0, Instant.now().toString()))
    if (uploaded) writableDatabase.execSQL("UPDATE local_images SET uploaded=1,sync_error=NULL WHERE hash=?", arrayOf(hash))
  }
  fun pendingImages(): List<String> = query("SELECT hash FROM local_images WHERE uploaded=0 AND sync_error IS NULL ORDER BY created_at LIMIT ${ProductImages.UPLOADS_PER_CYCLE}").map { it[0] }
  fun markImageUploaded(hash: String) = registerImage(hash, uploaded = true)
  /** 400 or a missing file: the image is parked and products using it are held too. */
  fun rejectImage(hash: String, reason: String) = writableDatabase.execSQL("UPDATE local_images SET sync_error=? WHERE hash=?", arrayOf(reason, hash))
  fun rejectedImageCount(): Int = query("SELECT COUNT(*) FROM local_images WHERE uploaded=0 AND sync_error IS NOT NULL").single().single().toInt()
  fun referencedImages(): Set<String> = query("SELECT DISTINCT image_hash FROM products WHERE image_hash IS NOT NULL").map { it[0] }.toSet()
  fun forgetImages(keep: Set<String>) = transaction {
    query("SELECT hash FROM local_images").map { it[0] }.filter { it !in keep }.forEach { writableDatabase.execSQL("DELETE FROM local_images WHERE hash=?", arrayOf(it)) }
  }
  /** Items the cloud refused (HTTP 400): products (including those waiting on a refused photo), stock events, drawer sessions. */
  fun rejectedCounts(): Triple<Int, Int, Int> = Triple(
    query("SELECT COUNT(*) FROM products WHERE dirty=1 AND (sync_error IS NOT NULL OR image_hash IN (SELECT hash FROM local_images WHERE uploaded=0 AND sync_error IS NOT NULL))").single().single().toInt(),
    query("SELECT COUNT(*) FROM stock_events WHERE synced=0 AND sync_error IS NOT NULL").single().single().toInt(),
    query("SELECT COUNT(*) FROM drawer_sessions WHERE synced=0 AND sync_error IS NOT NULL").single().single().toInt())
  fun syncGate(): Pair<Double, Int> {
    val values = query("SELECT key,value FROM sync_metadata").associate { it[0] to it[1] }
    return (values["next"]?.toDoubleOrNull() ?: 0.0) to (values["failures"]?.toIntOrNull() ?: 0)
  }
  fun setSyncGate(next: Double, failures: Int) = transaction {
    writableDatabase.execSQL("INSERT OR REPLACE INTO sync_metadata VALUES('next',?)", arrayOf(next.toString()))
    writableDatabase.execSQL("INSERT OR REPLACE INTO sync_metadata VALUES('failures',?)", arrayOf(failures.toString()))
  }
  fun bindSyncTarget(target: String) {
    val existing = query("SELECT value FROM sync_metadata WHERE key='target'").firstOrNull()
    if (existing == null) writableDatabase.execSQL("INSERT INTO sync_metadata VALUES('target',?)", arrayOf(target))
    else require(existing[0] == target) { "同期先の変更はできません。元の接続先を指定してください" }
  }
  fun feedAfter(): Long = query("SELECT value FROM sync_metadata WHERE key='feed_after'").firstOrNull()?.get(0)?.toLongOrNull() ?: 0
  fun lastSentAt(): String? = query("SELECT value FROM sync_metadata WHERE key='sent_at'").firstOrNull()?.get(0)
  fun markSent() = writableDatabase.execSQL("INSERT OR REPLACE INTO sync_metadata VALUES('sent_at',?)", arrayOf(Instant.now().toString()))
  fun lastFeedAt(): String? = query("SELECT value FROM sync_metadata WHERE key='feed_at'").firstOrNull()?.get(0)
  /** One feed page and its cursor commit together, so a failure re-reads the same page. */
  fun applyFeed(page: FeedPage): FeedResult {
    page.validate()
    return transaction {
      var products = 0; var orders = 0; var cancellations = 0
      page.products.forEach { p ->
        val local = product(p.id)
        if (local == null || !local.dirty) { writeCloudProduct(p, local != null); products++ }
      }
      page.orders.forEach { when (merge(it)) { Merge.ADDED -> orders++; Merge.CANCELLED -> cancellations++; else -> Unit } }
      writableDatabase.execSQL("INSERT OR REPLACE INTO sync_metadata VALUES('feed_after',?)", arrayOf(page.next.toString()))
      writableDatabase.execSQL("INSERT OR REPLACE INTO sync_metadata VALUES('feed_at',?)", arrayOf(Instant.now().toString()))
      FeedResult(products, orders, cancellations)
    }
  }
  fun restoreCursor(): Pair<String?, String> {
    val values = query("SELECT key,value FROM sync_metadata WHERE key IN ('restore_catalog','restore_after')").associate { it[0] to it[1] }
    return values["restore_catalog"]?.ifEmpty { null } to values["restore_after"].orEmpty()
  }
  fun restore(page: RestorePage): RestoreResult {
    page.validate()
    return transaction {
      val previous = if (page.after.isEmpty()) emptyMap() else query("SELECT key,value FROM sync_metadata WHERE key LIKE 'restore_%'").associate { it[0] to it[1] }
      var productsAdded = previous["restore_products"]?.toIntOrNull() ?: 0
      var ordersAdded = previous["restore_orders"]?.toIntOrNull() ?: 0
      var cancellations = previous["restore_cancellations"]?.toIntOrNull() ?: 0
      var conflicts = previous["restore_conflicts"]?.toIntOrNull() ?: 0
      page.products.forEach { p ->
        val old = query("SELECT name,price FROM products WHERE id=?", arrayOf(p.id)).firstOrNull()
        if (old == null) {
          writableDatabase.execSQL("INSERT INTO products(id,name,price) VALUES(?,?,?)", arrayOf<Any>(p.id, p.name, p.price)); productsAdded++
        } else if (old[0] != p.name || old[1].toLong() != p.price) conflicts++
      }
      page.orders.forEach { when (merge(it)) { Merge.ADDED -> ordersAdded++; Merge.CANCELLED -> cancellations++; Merge.CONFLICT -> conflicts++; Merge.SAME -> Unit } }
      writableDatabase.execSQL("INSERT OR REPLACE INTO sync_metadata VALUES('restore_catalog',?)", arrayOf(page.catalogID.orEmpty()))
      writableDatabase.execSQL("INSERT OR REPLACE INTO sync_metadata VALUES('restore_after',?)", arrayOf(page.next.orEmpty()))
      writableDatabase.execSQL("INSERT OR REPLACE INTO sync_metadata VALUES('restore_conflicts',?)", arrayOf(conflicts.toString()))
      listOf("restore_products" to productsAdded,"restore_orders" to ordersAdded,"restore_cancellations" to cancellations).forEach { (key,value) ->
        writableDatabase.execSQL("INSERT OR REPLACE INTO sync_metadata VALUES(?,?)", arrayOf(key,value.toString()))
      }
      RestoreResult(productsAdded, ordersAdded, cancellations, conflicts)
    }
  }
  // Cloud orders never overwrite local content and never undo a cancellation.
  private fun merge(row: PendingSale): Merge {
    val incoming = row.sale; val old = sale(incoming.id)
    if (old == null) {
      writableDatabase.execSQL("INSERT INTO orders(id,created_at,total,received,change_yen,cancelled_at,cancellation_reason,device_id,customer_age,customer_gender,revision,synced_revision) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
        arrayOf(incoming.id,incoming.createdAt,incoming.total,incoming.received,incoming.change,incoming.cancelledAt,incoming.cancellationReason,incoming.deviceID,incoming.customerAge,incoming.customerGender,row.revision,row.revision))
      incoming.lines.forEachIndexed { index, l -> writableDatabase.execSQL("INSERT INTO order_lines VALUES(?,?,?,?,?,?)", arrayOf<Any>(incoming.id,index+1,l.productID,l.name,l.price,l.quantity)) }
      return Merge.ADDED
    }
    if (old.createdAt != incoming.createdAt || old.total != incoming.total || old.received != incoming.received || old.change != incoming.change || old.lines != incoming.lines ||
      old.deviceID != incoming.deviceID || old.customerAge != incoming.customerAge || old.customerGender != incoming.customerGender) return Merge.CONFLICT
    if (old.cancelledAt != null && incoming.cancelledAt != null && (old.cancelledAt != incoming.cancelledAt || old.cancellationReason != incoming.cancellationReason)) return Merge.CONFLICT
    var result = Merge.SAME
    if (old.cancelledAt == null && row.revision == 2) {
      writableDatabase.execSQL("UPDATE orders SET cancelled_at=?,cancellation_reason=?,revision=2,sync_error=NULL WHERE id=?", arrayOf(incoming.cancelledAt,incoming.cancellationReason,incoming.id))
      result = Merge.CANCELLED
    }
    writableDatabase.execSQL("UPDATE orders SET synced_revision=CAST(? AS INTEGER) WHERE id=? AND synced_revision<?", arrayOf<Any>(row.revision,incoming.id,row.revision))
    return result
  }
  fun currentSession(): DrawerSession? = query("SELECT $SESSION FROM drawer_sessions WHERE closed_at IS NULL").firstOrNull()?.let(::makeSession)
  fun pendingSessions(): List<DrawerSession> = query("SELECT $SESSION FROM drawer_sessions WHERE synced=0 AND sync_error IS NULL ORDER BY opened_at LIMIT 20").map(::makeSession)
  fun openSession(float: Map<String, Int>): DrawerSession = transaction {
    require(currentSession() == null) { "レジは開いています" }
    val total = Cash.total(float); val id = UUID.randomUUID().toString()
    writableDatabase.execSQL("INSERT INTO drawer_sessions(id,opened_at,float_json,float_total) VALUES(?,?,?,?)", arrayOf<Any>(id, Instant.now().toString(), counts(float), total))
    checkNotNull(currentSession())
  }
  fun closeSession(id: String, counted: Map<String, Int>): DrawerSession = transaction {
    val open = currentSession(); require(open != null && open.id == id) { "開いているレジがありません" }
    val countedTotal = Cash.total(counted); val closedAt = Instant.now().toString()
    val summary = sessionSummary(open.openedAt, closedAt)
    writableDatabase.execSQL("UPDATE drawer_sessions SET closed_at=?,counted_json=?,counted_total=?,expected_total=?,sales_total=?,cancel_total=?,order_count=?,synced=0,sync_error=NULL WHERE id=?",
      arrayOf<Any>(closedAt, counts(counted), countedTotal, Cash.expected(open.floatTotal, summary), summary.sales, summary.cancels, summary.orders, id))
    makeSession(query("SELECT $SESSION FROM drawer_sessions WHERE id=?", arrayOf(id)).single())
  }
  /** Only this device's sales and refunds recorded here move cash in this drawer. */
  fun sessionSummary(openedAt: String, closedAt: String?): SessionSummary = Cash.summary(sales(), deviceID(), openedAt, closedAt)
  /** Marks a session sent only if it was not closed after this upload started. */
  fun markSessionsSynced(sent: List<DrawerSession>) = transaction {
    sent.forEach { writableDatabase.execSQL("UPDATE drawer_sessions SET synced=1 WHERE id=? AND closed_at IS ?", arrayOf(it.id, it.closedAt)) }
  }
  private fun counts(map: Map<String, Int>) = JSONObject().apply { Cash.DENOMINATIONS.forEach { put(it.toString(), map[it.toString()] ?: 0) } }.toString()
  private fun parseCounts(text: String): Map<String, Int>? = text.ifEmpty { null }?.let { JSONObject(it) }?.let { o -> Cash.DENOMINATIONS.associate { it.toString() to o.optInt(it.toString()) } }
  private fun makeSession(r: List<String>) = DrawerSession(r[0], r[1], r[2].ifEmpty { null }, parseCounts(r[3]).orEmpty(), r[4].toLong(), parseCounts(r[5]),
    r[6].toLongOrNull(), r[7].toLongOrNull(), r[8].toLongOrNull(), r[9].toLongOrNull(), r[10].toIntOrNull())
  private fun sale(id: String): Sale? {
    val order = query("SELECT $ORDER FROM orders WHERE id=?", arrayOf(id)).firstOrNull() ?: return null
    return makeSale(order, query("SELECT order_id,product_id,name,price,quantity FROM order_lines WHERE order_id=? ORDER BY line_no", arrayOf(id)))
  }
  private fun makeSale(row: List<String>, lines: List<List<String>>) = Sale(
    row[0], row[1], row[2].toLong(), row[3].toLong(), row[4].toLong(), row[5].ifEmpty { null }, row[6].ifEmpty { null },
    lines.map { Line(it[1], it[2], it[3].toLong(), it[4].toInt()) }, row[7].ifEmpty { null }, row[8].ifEmpty { null }, row[9].ifEmpty { null }, row[10] == "1"
  )
  private fun query(sql: String, args: Array<String> = emptyArray()): List<List<String>> =
    readableDatabase.rawQuery(sql, args).use { cursor ->
      buildList { while (cursor.moveToNext()) add((0 until cursor.columnCount).map { cursor.getString(it).orEmpty() }) }
    }
  private fun <T> transaction(body: () -> T): T {
    writableDatabase.beginTransaction()
    try { val result = body(); writableDatabase.setTransactionSuccessful(); return result }
    finally { writableDatabase.endTransaction() }
  }
  private companion object {
    const val ORDER = "id,created_at,total,received,change_yen,cancelled_at,cancellation_reason,device_id,customer_age,customer_gender,cancelled_here"
    const val PRODUCT = "id,name,price,active,stop_at_zero,version,cloud_stock,dirty,image_hash"
    const val SESSION = "id,opened_at,closed_at,float_json,float_total,counted_json,counted_total,expected_total,sales_total,cancel_total,order_count"
  }
}
