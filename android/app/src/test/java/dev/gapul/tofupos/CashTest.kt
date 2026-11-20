package dev.gapul.tofupos

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class CashTest {
  @Test fun changeBreakdownIsGreedyWithoutTwoThousandNotes() {
    assertEquals(listOf(1000 to 1L, 100 to 3L), Cash.breakdown(1300))
    assertEquals(listOf(1000 to 4L, 500 to 1L, 100 to 4L, 50 to 1L, 10 to 4L, 5 to 1L, 1 to 4L), Cash.breakdown(4999))
    assertEquals(listOf(10000 to 2L, 5000 to 1L), Cash.breakdown(25000))
    assertTrue(Cash.breakdown(0).isEmpty())
    assertEquals(2000L, Cash.breakdown(2000).sumOf { it.first * it.second })
    assertEquals("1,000円札×2", Cash.label(2000))
    assertEquals("1,000円札×1・100円玉×3", Cash.label(1300))
    assertEquals("なし", Cash.label(0))
    assertThrows(IllegalArgumentException::class.java) { Cash.breakdown(-1) }
  }
  @Test fun denominationTotals() {
    assertEquals(17_666L, Cash.total(mapOf("10000" to 1, "5000" to 1, "2000" to 1, "500" to 1, "100" to 1, "50" to 1, "10" to 1, "5" to 1, "1" to 1)))
    assertEquals(0L, Cash.total(emptyMap()))
    assertThrows(IllegalArgumentException::class.java) { Cash.total(mapOf("3" to 1)) }
    assertThrows(IllegalArgumentException::class.java) { Cash.total(mapOf("100" to 10000)) }
    assertThrows(IllegalArgumentException::class.java) { Cash.total(mapOf("100" to -1)) }
  }
  @Test fun displayedStock() {
    assertNull(Cash.displayedStock(null, 3))
    assertEquals(7L, Cash.displayedStock(10, 3))
    assertEquals(-2L, Cash.displayedStock(1, 3))
    assertEquals(0L, Cash.displayedStock(0, 0))
  }
  @Test fun onlyStopAtZeroProductsSellOut() {
    assertTrue(Cash.canAdd(false, -3, 5)) // negative stock keeps selling
    assertTrue(Cash.canAdd(false, 0, 0))
    assertTrue(Cash.canAdd(true, null, 10)) // cloud stock unknown: sellable
    assertTrue(Cash.canAdd(true, 3, 2))
    assertFalse(Cash.canAdd(true, 3, 3)) // cart is capped at the displayed stock
    assertFalse(Cash.canAdd(true, 0, 0))
    assertFalse(Cash.canAdd(true, -1, 0))
  }
  private fun sale(id: String, created: String, total: Long, cancelled: String? = null, age: String? = "adult", gender: String? = "female", device: String? = "d", here: Boolean = cancelled != null) =
    Sale(id, created, total, total, 0, cancelled, cancelled?.let { "返金済み" }, listOf(Line("p", "豆腐", total, 1)), device, age, gender, here)
  @Test fun sessionSummaryAndExpectedCash() {
    val open = "2026-11-21T01:00:00Z"; val close = "2026-11-21T05:00:00.5Z"
    val sales = listOf(
      sale("before", "2026-11-21T00:59:59.999Z", 300, cancelled = "2026-11-21T02:00:00Z"), // refund paid from this drawer
      sale("a", "2026-11-21T01:00:00Z", 500),
      sale("b", "2026-11-21T03:00:00.123456Z", 1200, age = "student", gender = "male"),
      sale("c", "2026-11-21T04:00:00Z", 700, cancelled = "2026-11-21T04:10:00Z"),
      sale("late", "2026-11-21T04:59:00Z", 400, cancelled = "2026-11-21T05:00:00.5Z"), // refunded after close
      sale("after", "2026-11-21T05:00:00.5Z", 900),
      sale("other", "2026-11-21T02:00:00Z", 5000, device = "x"), // another device's sale: not in this drawer
      sale("otherCancelledHere", "2026-11-21T00:00:00Z", 800, device = "x", cancelled = "2026-11-21T03:00:00Z"), // refunded from this drawer
      sale("cancelledElsewhere", "2026-11-21T01:30:00Z", 600, cancelled = "2026-11-21T02:30:00Z", here = false), // refund paid by another device
      sale("legacy", "2026-11-21T02:00:00Z", 100, device = null)
    )
    val summary = Cash.summary(sales, "d", open, close)
    assertEquals(500L + 1200 + 700 + 400 + 600, summary.sales)
    assertEquals(300L + 700 + 800, summary.cancels)
    assertEquals(5, summary.orders)
    assertEquals(mapOf(("adult" to "female") to 1, ("student" to "male") to 1), summary.segments)
    assertEquals(10_000L + 3400 - 1800, Cash.expected(10_000, summary))
    assertEquals(6, Cash.summary(sales, "d", open, null).orders)
  }
  @Test fun expectedCashMayBeNegative() {
    val summary = Cash.summary(listOf(sale("old", "2026-11-20T00:00:00Z", 3000, cancelled = "2026-11-21T02:00:00Z")), "d", "2026-11-21T01:00:00Z", null)
    assertEquals(-2000L, Cash.expected(1000, summary))
  }
  @Test fun limitsCountCodePoints() {
    val emoji = "🍢".repeat(70)
    assertEquals(140, emoji.length); assertEquals(70, CodePoints.length(emoji))
    assertEquals(64, CodePoints.length(CodePoints.deviceLabel(emoji)))
    assertEquals("🍢".repeat(64), CodePoints.deviceLabel(emoji))
    assertEquals("Android", CodePoints.deviceLabel("  ")); assertEquals("Pixel 9", CodePoints.deviceLabel("Pixel 9"))
    val name = "🍢".repeat(100)
    CloudJSON.validate(Product("p", name, 1, version = 1))
    assertThrows(IllegalArgumentException::class.java) { CloudJSON.validate(Product("p", name + "a", 1, version = 1)) }
  }
  @Test fun optionalOrderFieldsAreOmittedWhenNull() {
    val old = PendingSale(sale("o", "2026-11-21T01:00:00Z", 500).copy(deviceID = null, customerAge = null, customerGender = null), 1).json()
    assertFalse(old.has("device_id") || old.has("customer_age") || old.has("customer_gender"))
    val current = PendingSale(sale("o", "2026-11-21T01:00:00Z", 500), 1).json()
    assertEquals("d", current.getString("device_id")); assertEquals("adult", current.getString("customer_age")); assertEquals("female", current.getString("customer_gender"))
    assertEquals("female", CloudJSON.order(current).sale.customerGender)
    assertThrows(IllegalArgumentException::class.java) { CloudJSON.validate(CloudJSON.order(JSONObject(current.toString()).put("customer_age", "baby"))) }
  }
  @Test fun feedPageValidation() {
    fun page(after: Long, next: Long, more: Boolean, seq: Long) = JSONObject("""{"schema_version":1,"after":$after,"next":$next,"has_more":$more,
      "products":[{"id":"p","name":"豆腐","price":500,"active":true,"track_stock":true,"version":2,"stock":5,"seq":$seq}],"orders":[]}""")
    val feed = FeedPage.parse(page(3, 4, false, 4), 3)
    assertEquals(5L, feed.products.single().cloudStock); assertFalse(feed.products.single().dirty)
    assertThrows(Exception::class.java) { FeedPage.parse(page(3, 4, false, 4), 2) }
    assertThrows(IllegalArgumentException::class.java) { FeedPage.parse(page(3, 4, false, 5), 3) }
    assertThrows(IllegalArgumentException::class.java) { FeedPage.parse(page(3, 3, true, 4), 3) }
    assertFalse(feed.products.single().stopAtZero) // omitted stop_at_zero means false
    val stop = CloudJSON.product(JSONObject("""{"id":"p","name":"x","price":1,"active":true,"track_stock":false,"stop_at_zero":true,"version":1,"stock":-3}"""))
    assertTrue(stop.stopAtZero); assertEquals(-3L, stop.cloudStock)
    assertThrows(Exception::class.java) { CloudJSON.product(JSONObject("""{"id":"p","name":"x","price":1,"active":true,"stop_at_zero":"yes","version":1,"stock":3}""")) }
    assertThrows(IllegalArgumentException::class.java) { CloudJSON.product(JSONObject("""{"id":"p","name":"x","price":1,"active":true,"version":0,"stock":3}""")) }
  }
  @Test fun singleProductQuantityReselectsExact() {
    val paid = SingleState().withQuantity(2).select("5000")
    assertEquals(5000L, paid.received(1000)); assertEquals(1000L, paid.total(500))
    val changed = paid.withQuantity(3)
    assertEquals(SingleState.EXACT, changed.tender); assertEquals(1500L, changed.received(1500))
    assertEquals(SingleState.EXACT, paid.select(SingleState.MANUAL).copy(manual = "2000").withQuantity(1).tender)
    assertEquals("", paid.select(SingleState.MANUAL).copy(manual = "2000").withQuantity(1).manual)
    assertEquals(1, SingleState().withQuantity(0).quantity); assertEquals(999, SingleState().withQuantity(1000).quantity)
  }
  @Test fun singleProductTenderBelowTotalIsDisabled() {
    assertFalse(SingleState.enabled(1000, 1500)); assertTrue(SingleState.enabled(2000, 1500)); assertTrue(SingleState.enabled(1500, 1500))
    assertFalse(SingleState.enabled(1000, null))
    val three = SingleState().withQuantity(3) // 1,500 yen at 500
    assertTrue(three.canConfirm(500, false, null))
    assertFalse(three.select("1000").canConfirm(500, false, null))
    assertTrue(three.select("2000").canConfirm(500, false, null))
    assertFalse(three.select(SingleState.MANUAL).copy(manual = "1499").canConfirm(500, false, null))
    assertFalse(three.select(SingleState.MANUAL).copy(manual = "").canConfirm(500, false, null))
    assertTrue(three.select(SingleState.MANUAL).copy(manual = "1500").canConfirm(500, false, null))
  }
  @Test fun singleProductStockLimits() {
    assertEquals(999, SingleState.maxQuantity(false, -5))
    assertEquals(999, SingleState.maxQuantity(true, null))
    assertEquals(2, SingleState.maxQuantity(true, 2))
    assertEquals(0, SingleState.maxQuantity(true, -1))
    assertFalse(SingleState().withQuantity(3).canConfirm(500, true, 2))
    assertTrue(SingleState().withQuantity(3).canConfirm(500, false, -10)) // negative stock keeps selling
    assertFalse(SingleState().canConfirm(500, true, 0)) // sold out
    assertFalse(SingleState().withQuantity(999).canConfirm(Money.MAXIMUM, false, null)) // over the order limit
  }
}
