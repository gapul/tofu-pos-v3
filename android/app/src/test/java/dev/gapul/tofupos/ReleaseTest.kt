package dev.gapul.tofupos

import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

class ReleaseTest {
  @Test fun environmentsKeepSeparateNamesAndProductionKeepsTheOldOnes() {
    val p = AppEnvironment.PRODUCTION; val t = AppEnvironment.TEST
    assertEquals("tofu-pos.sqlite", p.database); assertEquals("tofu-pos-test.sqlite", t.database)
    assertEquals("product-images", p.imageFolder); assertEquals("product-images-test", t.imageFolder)
    assertEquals("connection", p.connectionKey); assertEquals("connection-test", t.connectionKey)
    assertEquals("dev.gapul.tofupos.sync", p.keyAlias); assertEquals("dev.gapul.tofupos.sync.test", t.keyAlias)
    assertEquals("sync-default.json", p.bundledConnection); assertEquals("sync-default-test.json", t.bundledConnection)
    assertEquals(p, AppEnvironment.parse(null)); assertEquals(p, AppEnvironment.parse("staging")); assertEquals(t, AppEnvironment.parse("test"))
    val names = AppEnvironment.entries.flatMap { listOf(it.database, it.imageFolder, it.connectionKey, it.keyAlias, it.bundledConnection) }
    assertEquals(names.size, names.toSet().size)
  }
  @Test fun ticketCounterRestartsEachJstDay() {
    assertEquals("2026-11-21", Tickets.date(Instant.parse("2026-11-20T15:00:00Z"))) // 00:00 JST
    assertEquals("2026-11-20", Tickets.date(Instant.parse("2026-11-20T14:59:59Z")))
    assertEquals(1, Tickets.next(null, 0, "2026-11-21"))
    assertEquals(13, Tickets.next("2026-11-21", 12, "2026-11-21"))
    assertEquals(1, Tickets.next("2026-11-20", 12, "2026-11-21"))
    assertEquals(1, Tickets.next("2026-11-21", 9999, "2026-11-21"))
    assertEquals("12", Tickets.format("", 12)); assertEquals("A-12", Tickets.format("A", 12)); assertEquals("AB-1", Tickets.format("AB", 1))
    listOf("", "A", "ZZ").forEach { assertTrue(it, Tickets.validPrefix(it)) }
    listOf("a", "ABC", "1", "A-").forEach { assertFalse(it, Tickets.validPrefix(it)) }
    listOf("1", "9999", "A-12", "AB-1").forEach { assertTrue(it, Tickets.valid(it)) }
    listOf("", "A12", "10000", "a-1", "ABC-1", "A-").forEach { assertFalse(it, Tickets.valid(it)) }
  }
  private fun sale(group: String? = null, ticket: String? = null) =
    Sale("o", "2026-11-21T01:00:00Z", 500, 500, 0, null, null, listOf(Line("p", "豆腐", 500, 1)), "d", "adult", "female", customerGroup = group, ticketNo = ticket)
  @Test fun groupAndTicketAreOptionalPayloadFields() {
    val bare = PendingSale(sale(), 1).json()
    assertFalse(bare.has("customer_group") || bare.has("ticket_no"))
    val full = PendingSale(sale("couple", "A-3"), 1).json()
    assertEquals("couple", full.getString("customer_group")); assertEquals("A-3", full.getString("ticket_no"))
    val parsed = CloudJSON.order(full).sale
    assertEquals("couple", parsed.customerGroup); assertEquals("A-3", parsed.ticketNo)
    CloudJSON.validate(PendingSale(parsed, 1))
    assertThrows(IllegalArgumentException::class.java) { CloudJSON.validate(PendingSale(sale("crowd"), 1)) }
    assertThrows(IllegalArgumentException::class.java) { CloudJSON.validate(PendingSale(sale(ticket = "x-1"), 1)) }
  }
  @Test fun groupsInOrderAndInTheSessionSummary() {
    assertEquals(listOf("一人", "友人", "家族", "カップル", "グループ"), Customer.GROUPS.map { it.second })
    assertEquals(listOf("solo", "friends", "family", "couple", "group"), Customer.GROUPS.map { it.first })
    assertEquals("大人・女性・家族", Customer.describe("adult", "female", "family"))
    assertEquals("家族", Customer.describe(null, null, "family")); assertNull(Customer.describe(null, null, null))
    val sales = listOf(sale("family"), sale("family").copy(id = "b"), sale().copy(id = "c"), sale("solo").copy(id = "d", cancelledAt = "2026-11-21T02:00:00Z", cancellationReason = "x"))
    assertEquals(mapOf("family" to 2, null to 1), Cash.summary(sales, "d", "2026-11-21T00:00:00Z", null).groups)
  }
  @Test fun csvAddsTicketColumnOnlyWhenPresent() {
    assertFalse(SalesCSV.make(listOf(sale())).contains("ticket_no"))
    val csv = SalesCSV.make(listOf(sale(ticket = "12")))
    assertTrue(csv.lines().first().endsWith(",ticket_no")); assertTrue(csv.lines()[1].endsWith(",\"12\""))
  }
  @Test fun relationIsAnOptionalFourthAxis() {
    assertEquals(listOf("知り合い", "親族", "メンバー", "豆腐狂", "一般人"), Customer.RELATIONS.map { it.second })
    assertEquals(listOf("acquaintance", "relative", "member", "tofu_fan", "general"), Customer.RELATIONS.map { it.first })
    assertEquals("大人・女性・家族・豆腐狂", Customer.describe("adult", "female", "family", "tofu_fan"))
    assertEquals("一般人", Customer.describe(null, null, null, "general"))
    val plain = sale()
    assertFalse(PendingSale(plain, 1).json().has("customer_relation"))
    val json = PendingSale(plain.copy(customerRelation = "member"), 1).json()
    assertEquals("member", json.getString("customer_relation"))
    assertEquals("member", CloudJSON.order(json).sale.customerRelation)
    assertThrows(IllegalArgumentException::class.java) { CloudJSON.validate(PendingSale(plain.copy(customerRelation = "boss"), 1)) }
    val sales = listOf(plain.copy(customerRelation = "relative"), plain.copy(id = "b", customerRelation = "relative"), plain.copy(id = "c"))
    assertEquals(mapOf("relative" to 2, null to 1), Cash.summary(sales, "d", "2026-11-21T00:00:00Z", null).relations)
  }
}
