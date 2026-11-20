package dev.gapul.tofupos

import java.util.UUID

data class Product(
  val id: String = UUID.randomUUID().toString(), val name: String, val price: Long,
  val active: Boolean = true, val stopAtZero: Boolean = false, val version: Long = 0, val cloudStock: Long? = null, val dirty: Boolean = true,
  val imageHash: String? = null
) {
  fun sameContent(other: Product) = name == other.name && price == other.price && active == other.active && stopAtZero == other.stopAtZero && imageHash == other.imageHash
}
data class Line(val productID: String, val name: String, val price: Long, val quantity: Int)
data class Sale(
  val id: String, val createdAt: String, val total: Long, val received: Long, val change: Long,
  val cancelledAt: String?, val cancellationReason: String?, val lines: List<Line>,
  val deviceID: String? = null, val customerAge: String? = null, val customerGender: String? = null,
  /** Local only: the cancellation (refund) was recorded on this device. */
  val cancelledHere: Boolean = false,
  val customerGroup: String? = null,
  val ticketNo: String? = null
)
data class DrawerSession(
  val id: String, val openedAt: String, val closedAt: String?, val float: Map<String, Int>, val floatTotal: Long,
  val counted: Map<String, Int>?, val countedTotal: Long?, val expectedTotal: Long?,
  val salesTotal: Long?, val cancelTotal: Long?, val orderCount: Int?
)

object Money {
  const val MAXIMUM = 1_000_000_000L
  fun parse(text: String): Long? = text.takeIf { it.isNotEmpty() && it.all { c -> c in '0'..'9' } }
    ?.toLongOrNull()?.takeIf { it <= MAXIMUM }
  fun total(lines: List<Line>): Long {
    require(lines.isNotEmpty()) { "商品を選択してください" }
    require(lines.map { it.productID }.distinct().size == lines.size) { "商品が重複しています" }
    var total = 0L
    lines.forEach {
      require(it.quantity in 1..999 && it.price in 0..MAXIMUM && it.name.isNotBlank()) { "商品・数量・金額を確認してください" }
      val amount = it.price * it.quantity
      require(amount <= MAXIMUM - total) { "会計金額が上限を超えています" }
      total += amount
    }
    return total
  }
}

object SalesCSV {
  fun make(sales: List<Sale>): String {
    // ticket_no is appended only when some sale has one, so exports of 0.3.0-era data keep the shared golden layout.
    val tickets = sales.any { it.ticketNo != null }
    val rows = mutableListOf("order_id,created_at_utc,status,cancelled_at_utc,cancellation_reason,order_total_yen,received_yen,change_yen,line_no,product_id,product_name,quantity,unit_price_yen,line_total_yen,net_line_sales_yen" + if (tickets) ",ticket_no" else "")
    sales.forEach { sale ->
      sale.lines.forEachIndexed { index, line ->
        val amount = line.price * line.quantity
        rows += listOf(
          sale.id, sale.createdAt, if (sale.cancelledAt == null) "paid" else "cancelled",
          sale.cancelledAt.orEmpty(), sale.cancellationReason.orEmpty(),
          if (index == 0) sale.total.toString() else "", if (index == 0) sale.received.toString() else "",
          if (index == 0) sale.change.toString() else "", (index + 1).toString(), line.productID,
          line.name, line.quantity.toString(), line.price.toString(), amount.toString(),
          if (sale.cancelledAt == null) amount.toString() else "0"
        ).let { if (tickets) it + sale.ticketNo.orEmpty() else it }.joinToString(",") { cell(it) }
      }
    }
    return "\uFEFF" + rows.joinToString("\r\n") + "\r\n"
  }
  private fun cell(value: String): String {
    val unsafe = value.trimStart().firstOrNull()?.let { it in "=+-@" } == true || value.startsWith('\t') || value.startsWith('\r')
    val safe = if (unsafe) "'$value" else value
    return "\"${safe.replace("\"", "\"\"")}\""
  }
}
