package dev.gapul.tofupos

import org.json.JSONObject
import java.time.Instant

data class Catalog(val id: String, val productCount: Int, val receivedAt: String)
data class CatalogPage(val catalogs: List<Catalog>, val next: String?)
data class RestoreResult(val products: Int, val orders: Int, val cancellations: Int, val conflicts: Int) {
  fun message(next: String?) = "商品${products}件・会計${orders}件・取消${cancellations}件を復元。競合は累計${conflicts}件は端末の内容を保持。" +
    if (next == null) "売上の復元が完了しました" else "続きがあります。「売上の続きを復元」を押してください"
}
data class RestorePage(val products: List<Product>, val orders: List<PendingSale>, val after: String, val next: String?, val catalogID: String?) {
  fun validate() {
    require(products.size <= 1000 && products.map { it.id }.distinct().size == products.size) { "不正な商品バックアップです" }
    products.forEach { require(it.id.isNotEmpty() && CodePoints.length(it.id) <= 128 && it.name.isNotBlank() && it.price in 0..Money.MAXIMUM) }
    require(orders.size <= 50 && orders.map { it.sale.id }.distinct().size == orders.size) { "不正な復元応答です" }
    var previous = after
    orders.forEach { row ->
      require(row.sale.id > previous) { "不正な復元順序です" }; previous = row.sale.id
      CloudJSON.validate(row)
    }
    require(if (orders.isEmpty()) next == null else next == orders.last().sale.id) { "不正な復元カーソルです" }
  }
  companion object {
    fun parse(json: JSONObject, expectedAfter: String, expectedCatalog: String?): RestorePage {
      require(CloudJSON.integer(json, "schema_version") == 1L && json.getString("after") == expectedAfter && CloudJSON.nullable(json, "catalog_id") == expectedCatalog) { "不正な復元応答です" }
      val p = json.getJSONArray("products"); val rows = json.getJSONArray("orders")
      val products = (0 until p.length()).map { p.getJSONObject(it).let { Product(it.getString("id"), it.getString("name"), CloudJSON.integer(it, "price")) } }
      val orders = (0 until rows.length()).map { CloudJSON.order(rows.getJSONObject(it)) }
      return RestorePage(products, orders, expectedAfter, CloudJSON.nullable(json,"next"), expectedCatalog).also { it.validate() }
    }
  }
}

/** One /v1/feed page. Products and orders carry their store sequence number. */
data class FeedPage(val after: Long, val next: Long, val hasMore: Boolean, val products: List<Product>, val orders: List<PendingSale>, val productSeqs: List<Long> = emptyList(), val orderSeqs: List<Long> = emptyList()) {
  fun validate() {
    require(after >= 0 && next >= after && (!hasMore || next > after)) { "不正な取り込みカーソルです" }
    require(products.size <= 1000 && orders.size <= 100 && products.map { it.id }.distinct().size == products.size && orders.map { it.sale.id }.distinct().size == orders.size) { "不正な取り込み応答です" }
    require((productSeqs + orderSeqs).all { it in (after + 1)..next }) { "不正な取り込み順序です" }
    products.forEach(CloudJSON::validate); orders.forEach(CloudJSON::validate)
  }
  companion object {
    fun parse(json: JSONObject, expectedAfter: Long): FeedPage {
      require(CloudJSON.integer(json, "schema_version") == 1L && CloudJSON.integer(json, "after") == expectedAfter) { "不正な取り込み応答です" }
      val hasMore = json.get("has_more") as? Boolean ?: error("不正な取り込み応答です")
      val p = json.getJSONArray("products"); val o = json.getJSONArray("orders")
      val products = (0 until p.length()).map { p.getJSONObject(it) }; val orders = (0 until o.length()).map { o.getJSONObject(it) }
      return FeedPage(expectedAfter, CloudJSON.integer(json, "next"), hasMore, products.map(CloudJSON::product), orders.map(CloudJSON::order),
        products.map { CloudJSON.integer(it, "seq") }, orders.map { CloudJSON.integer(it, "seq") }).also { it.validate() }
    }
  }
}

object CloudJSON {
  fun integer(o: JSONObject, key: String): Long = (o.get(key) as? Number)?.toString()?.toLongOrNull() ?: error("不正な数値です")
  fun nullable(o: JSONObject, key: String) = if (o.isNull(key)) null else o.getString(key)
  private fun flag(o: JSONObject, key: String) = o.get(key) as? Boolean ?: error("不正な値です")
  fun order(o: JSONObject): PendingSale {
    val lines = o.getJSONArray("lines")
    val detail = (0 until lines.length()).map { lines.getJSONObject(it).let { l ->
      val qty = integer(l, "quantity"); require(qty in 1..999)
      Line(l.getString("product_id"), l.getString("name"), integer(l,"price"), qty.toInt())
    } }
    val revision = integer(o,"revision"); require(revision in 1..2)
    return PendingSale(Sale(o.getString("id"), o.getString("created_at"), integer(o,"total"), integer(o,"received"), integer(o,"change_yen"),
      nullable(o,"cancelled_at"), nullable(o,"cancellation_reason"), detail, optional(o, "device_id"), optional(o, "customer_age"), optional(o, "customer_gender"), customerGroup = optional(o, "customer_group"), ticketNo = optional(o, "ticket_no")), revision.toInt())
  }
  private fun optional(o: JSONObject, key: String) = if (!o.has(key)) null else nullable(o, key)
  /** Cloud product representation shared by /v1/products, /v1/stock and /v1/feed. */
  // track_stock is always true since stock is always kept; it is ignored. stop_at_zero defaults to false.
  fun product(o: JSONObject): Product = Product(o.getString("id"), o.getString("name"), integer(o, "price"), flag(o, "active"),
    if (o.isNull("stop_at_zero")) false else flag(o, "stop_at_zero"), integer(o, "version"),
    if (o.isNull("stock")) null else integer(o, "stock"), dirty = false, imageHash = if (o.isNull("image_hash")) null else o.getString("image_hash")).also(::validate)
  fun validate(p: Product) {
    require(CodePoints.length(p.id) in 1..128 && p.name.isNotBlank() && CodePoints.length(p.name) <= 100 && p.price in 0..Money.MAXIMUM && p.version >= 1 && (p.imageHash == null || ProductImages.isHash(p.imageHash))) { "不正な商品データです" }
  }
  fun validate(row: PendingSale) {
    val s = row.sale
    require(CodePoints.length(s.id) in 1..128)
    require(s.createdAt.endsWith("Z")); Instant.parse(s.createdAt)
    require(Money.total(s.lines) == s.total && s.received in s.total..Money.MAXIMUM && s.change == s.received - s.total)
    require(s.lines.all { CodePoints.length(it.productID) in 1..128 })
    require(row.revision == if (s.cancelledAt == null) 1 else 2)
    require((s.deviceID == null || CodePoints.length(s.deviceID) in 1..64) && Customer.validAge(s.customerAge) && Customer.validGender(s.customerGender) && Customer.validGroup(s.customerGroup) && (s.ticketNo == null || Tickets.valid(s.ticketNo))) { "不正な客層・端末IDです" }
    if (s.cancelledAt != null) { require(s.cancelledAt.endsWith("Z") && !s.cancellationReason.isNullOrBlank()); Instant.parse(s.cancelledAt) }
    else require(s.cancellationReason == null)
  }
}
