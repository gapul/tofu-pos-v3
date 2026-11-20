package dev.gapul.tofupos

import java.time.Instant

object Customer {
  val AGES = listOf("child" to "子ども", "student" to "学生", "adult" to "大人", "senior" to "シニア")
  val GENDERS = listOf("male" to "男性", "female" to "女性", "other" to "その他")
  fun age(key: String?) = AGES.firstOrNull { it.first == key }?.second ?: "未設定"
  val GROUPS = listOf("solo" to "一人", "friends" to "友人", "family" to "家族", "couple" to "カップル", "group" to "グループ")
  fun gender(key: String?) = GENDERS.firstOrNull { it.first == key }?.second ?: "未設定"
  fun group(key: String?) = GROUPS.firstOrNull { it.first == key }?.second ?: "未設定"
  fun validGroup(key: String?) = key == null || GROUPS.any { it.first == key }
  /** "大人・女性・家族"; only the axes that were chosen, null when none. */
  fun describe(age: String?, gender: String?, group: String?): String? =
    listOfNotNull(age?.let(::age), gender?.let(::gender), group?.let(::group)).takeIf { it.isNotEmpty() }?.joinToString("・")
  fun validAge(key: String?) = key == null || AGES.any { it.first == key }
  fun validGender(key: String?) = key == null || GENDERS.any { it.first == key }
}

object CodePoints {
  /** Limits count Unicode code points on every platform; never splits a surrogate pair. */
  fun take(value: String, limit: Int): String = if (value.codePointCount(0, value.length) <= limit) value else value.substring(0, value.offsetByCodePoints(0, limit))
  fun length(value: String) = value.codePointCount(0, value.length)
  fun deviceLabel(model: String?): String = take(model.orEmpty().trim().ifEmpty { "Android" }, 64)
}

/** Ticket numbers: optional device prefix plus a per-device counter that restarts at 1 every JST day. */
object Tickets {
  private val JST = java.time.ZoneId.of("Asia/Tokyo")
  private val PREFIX = Regex("[A-Z]{0,2}")
  private val TICKET = Regex("[A-Z]{1,2}-[0-9]{1,4}|[0-9]{1,4}")
  fun date(now: Instant): String = now.atZone(JST).toLocalDate().toString()
  /** Next counter value; a new day starts at 1 and 9999 wraps to 1 to stay within four digits. */
  fun next(lastDate: String?, lastSeq: Int, today: String): Int = if (lastDate != today || lastSeq !in 1..9998) 1 else lastSeq + 1
  fun format(prefix: String, seq: Int) = if (prefix.isEmpty()) "$seq" else "$prefix-$seq"
  fun validPrefix(prefix: String) = PREFIX.matches(prefix)
  fun valid(ticket: String) = TICKET.matches(ticket)
}

object Cash {
  /** Drawer denominations, largest first. Counts are 0..9999 per denomination. Change itself is shown as an amount only. */
  val DENOMINATIONS = listOf(10000, 5000, 2000, 1000, 500, 100, 50, 10, 5, 1)
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
    val groups = created.filter { it.cancelledAt == null }.groupingBy { it.customerGroup }.eachCount()
    return SessionSummary(created.sumOf { it.total }, sales.filter { it.cancelledHere && inside(it.cancelledAt) }.sumOf { it.total }, created.size, segments, groups)
  }
  fun expected(floatTotal: Long, summary: SessionSummary) = floatTotal + summary.sales - summary.cancels
}

data class SessionSummary(val sales: Long, val cancels: Long, val orders: Int, val segments: Map<Pair<String?, String?>, Int>, val groups: Map<String?, Int> = emptyMap())

/** Single-product register: quantity and the tender choice. Nothing is tendered until chosen; a quantity change clears it. */
data class SingleState(val quantity: Int = 1, val tender: String? = null, val manual: String = "") {
  fun withQuantity(value: Int) = SingleState(value.coerceIn(1, 999))
  /** Tapping the chosen button again clears the choice. Manual entry always starts empty. */
  fun select(value: String) = if (tender == value) copy(tender = null, manual = "") else copy(tender = value, manual = "")
  fun total(price: Long): Long? = runCatching { Money.total(listOf(Line("p", "p", price, quantity))) }.getOrNull()
  fun received(total: Long): Long? = when (tender) { null -> null; EXACT -> total; MANUAL -> Money.parse(manual); else -> tender.toLongOrNull() }
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
