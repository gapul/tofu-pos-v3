package dev.gapul.tofupos

import java.text.NumberFormat
import java.time.Instant
import java.util.Locale

object Customer {
  val AGES = listOf("child" to "子ども", "student" to "学生", "adult" to "大人", "senior" to "シニア")
  val GENDERS = listOf("male" to "男性", "female" to "女性", "other" to "その他")
  fun age(key: String?) = AGES.firstOrNull { it.first == key }?.second ?: "未設定"
  fun gender(key: String?) = GENDERS.firstOrNull { it.first == key }?.second ?: "未設定"
  fun validAge(key: String?) = key == null || AGES.any { it.first == key }
  fun validGender(key: String?) = key == null || GENDERS.any { it.first == key }
}

object CodePoints {
  /** Limits count Unicode code points on every platform; never splits a surrogate pair. */
  fun take(value: String, limit: Int): String = if (value.codePointCount(0, value.length) <= limit) value else value.substring(0, value.offsetByCodePoints(0, limit))
  fun length(value: String) = value.codePointCount(0, value.length)
  fun deviceLabel(model: String?): String = take(model.orEmpty().trim().ifEmpty { "Android" }, 64)
}

object Cash {
  /** Drawer denominations, largest first. Counts are 0..9999 per denomination. */
  val DENOMINATIONS = listOf(10000, 5000, 2000, 1000, 500, 100, 50, 10, 5, 1)
  // 2000-yen notes are rarely kept for change.
  private val CHANGE = DENOMINATIONS - 2000

  fun breakdown(amount: Long): List<Pair<Int, Long>> {
    require(amount >= 0)
    var rest = amount
    return CHANGE.mapNotNull { unit -> (rest / unit).takeIf { it > 0 }?.let { count -> rest -= count * unit; unit to count } }
  }
  fun label(amount: Long): String = breakdown(amount).takeIf { it.isNotEmpty() }?.joinToString("・") { (unit, count) ->
    "${NumberFormat.getIntegerInstance(Locale.JAPAN).format(unit)}円${if (unit >= 1000) "札" else "玉"}×$count"
  } ?: "なし"

  fun total(counts: Map<String, Int>): Long {
    require(counts.keys.all { key -> DENOMINATIONS.any { it.toString() == key } } && counts.values.all { it in 0..9999 }) { "金種の枚数（0〜9999）を確認してください" }
    return counts.entries.sumOf { it.key.toLong() * it.value }
  }

  /** Every product keeps stock and may go negative. null only while the cloud value has not arrived (sellable, no badge). */
  fun displayedStock(cloudStock: Long?, pendingQuantity: Long): Long? = cloudStock?.minus(pendingQuantity)
  /** Only stop_at_zero products are blocked, once the cart would take the displayed stock below 1. */
  fun canAdd(stopAtZero: Boolean, stock: Long?, inCart: Int): Boolean = !stopAtZero || stock == null || stock - inCart > 0

  /**
   * Cash counted against one drawer session (opened_at <= t < closed_at): this device's sales created in the session
   * (even if cancelled later) minus refunds recorded on this device in the session. The result may be negative.
   */
  fun summary(sales: List<Sale>, deviceID: String, openedAt: String, closedAt: String?): SessionSummary {
    val open = Instant.parse(openedAt); val close = closedAt?.let(Instant::parse)
    fun inside(value: String?) = value != null && Instant.parse(value).let { !it.isBefore(open) && (close == null || it.isBefore(close)) }
    val created = sales.filter { it.deviceID == deviceID && inside(it.createdAt) }
    val segments = created.filter { it.cancelledAt == null }.groupingBy { it.customerAge to it.customerGender }.eachCount()
    return SessionSummary(created.sumOf { it.total }, sales.filter { it.cancelledHere && inside(it.cancelledAt) }.sumOf { it.total }, created.size, segments)
  }
  fun expected(floatTotal: Long, summary: SessionSummary) = floatTotal + summary.sales - summary.cancels
}

data class SessionSummary(val sales: Long, val cancels: Long, val orders: Int, val segments: Map<Pair<String?, String?>, Int>)

/** Single-product register: quantity and the tender choice. Changing the quantity always re-selects "exact". */
data class SingleState(val quantity: Int = 1, val tender: String = EXACT, val manual: String = "") {
  fun withQuantity(value: Int) = SingleState(value.coerceIn(1, 999))
  fun select(value: String) = copy(tender = value)
  fun total(price: Long): Long? = runCatching { Money.total(listOf(Line("p", "p", price, quantity))) }.getOrNull()
  fun received(total: Long): Long? = when (tender) { EXACT -> total; MANUAL -> Money.parse(manual); else -> tender.toLongOrNull() }
  fun canConfirm(price: Long, stopAtZero: Boolean, stock: Long?): Boolean {
    val total = total(price) ?: return false; val received = received(total) ?: return false
    return received in total..Money.MAXIMUM && quantity <= maxQuantity(stopAtZero, stock)
  }
  companion object {
    const val EXACT = "exact"
    const val MANUAL = "manual"
    val NOTES = listOf(1000L, 2000L, 5000L, 10000L)
    /** A bill smaller than the total cannot pay for it. */
    fun enabled(amount: Long, total: Long?) = total != null && amount >= total
    /** 999, or the displayed stock for stop_at_zero products (0 = sold out). */
    fun maxQuantity(stopAtZero: Boolean, stock: Long?): Int = if (stopAtZero && stock != null) stock.coerceIn(0, 999).toInt() else 999
  }
}
