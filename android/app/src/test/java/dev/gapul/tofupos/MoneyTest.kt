package dev.gapul.tofupos

import org.junit.Assert.*
import org.junit.Test
import java.io.File

class MoneyTest {
  private fun line(price: Long = 500, quantity: Int = 2) = Line("p1", "豆腐", price, quantity)
  @Test fun moneyBoundaries() {
    assertEquals(1000L, Money.total(listOf(line())))
    assertEquals(0L, Money.total(listOf(line(0))))
    assertEquals(Money.MAXIMUM, Money.parse("1000000000"))
    listOf("", "-1", "1.5", " 500", "１００", "1000000001", "9".repeat(50)).forEach { assertNull(it, Money.parse(it)) }
    listOf(emptyList(), listOf(line(quantity = 0)), listOf(line(quantity = 1000)), listOf(line(-1)), listOf(line(Money.MAXIMUM)), listOf(line(), line())).forEach {
      assertThrows(IllegalArgumentException::class.java) { Money.total(it) }
    }
  }
  @Test fun goldenCSV() {
    val sales = listOf(
      Sale("order-a", "2026-11-18T00:00:00Z", 1100, 2000, 900, null, null, listOf(line(), Line("p2", "=SUM(1,2)\n\"商品\"", 100, 1))),
      Sale("order-b", "2026-11-18T00:01:00Z", 500, 1000, 500, "2026-11-18T00:02:00Z", "返金済み", listOf(line(quantity = 1)))
    )
    assertArrayEquals(File("../../shared/golden-sales.csv").readBytes(), SalesCSV.make(sales).toByteArray(Charsets.UTF_8))
  }
  @Test fun syncRetryBoundsAndEndpointValidation() {
    assertEquals(15.0, SyncRules.delay(1), 0.0)
    assertEquals(300.0, SyncRules.delay(100), 0.0)
    assertEquals(3600.0, SyncRules.delay(1, "999999"), 0.0)
    listOf("http://test.workers.dev", "https://user:pass@test.workers.dev", "https://test.workers.dev/path", "https://test.workers.dev?q=token").forEach {
      assertThrows(IllegalArgumentException::class.java) { SyncRules.endpoint(it) }
    }
    assertEquals("https://test.workers.dev/v1/sync", SyncRules.endpoint("https://test.workers.dev/").toString())
    assertThrows(IllegalArgumentException::class.java) { SyncRules.readLimited(java.io.ByteArrayInputStream(ByteArray(4097)), 4096) }
  }
}
