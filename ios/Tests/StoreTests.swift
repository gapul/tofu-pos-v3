import XCTest
import CSQLite
@testable import TofuPOSCore

final class StoreTests: XCTestCase {
    private func path() -> String { FileManager.default.temporaryDirectory.appendingPathComponent("tofu-test-\(UUID()).sqlite").path }
    private func line(price: Int64 = 500, quantity: Int = 2) -> Line {
        Line(productID: "p1", name: "豆腐", price: price, quantity: quantity)
    }
    func testMoneyBoundaries() throws {
        XCTAssertEqual(try Money.total([line()]), 1000)
        XCTAssertEqual(try Money.total([line(price: 0)]), 0)
        XCTAssertEqual(Money.parse("1000000000"), Money.maximum)
        for input in ["", "-1", "1.5", " 500", "１００", "1000000001", String(repeating: "9", count: 50)] { XCTAssertNil(Money.parse(input), input) }
        for lines in [[], [line(quantity: 0)], [line(quantity: 1000)], [line(price: -1)], [line(price: Money.maximum)], [line(), line()]] {
            XCTAssertThrowsError(try Money.total(lines))
        }
    }
    func testReopenSnapshotAndCancellation() throws {
        let file = path(); defer { try? FileManager.default.removeItem(atPath: file) }
        do {
            let store = try SQLiteStore(path: file)
            try store.saveProduct(Product(id: "p1", name: "豆腐", price: 500))
            let sale = try store.checkout(id: "order1", lines: [line()], received: 2000)
            XCTAssertEqual(sale.change, 1000)
            try store.saveProduct(Product(id: "p1", name: "新豆腐", price: 700))
        }
        let reopened = try SQLiteStore(path: file)
        XCTAssertEqual(try reopened.products().first?.price, 700)
        XCTAssertEqual(try reopened.sales().first?.lines.first?.price, 500)
        XCTAssertEqual(try reopened.sales().first?.lines.first?.name, "豆腐")
        XCTAssertThrowsError(try reopened.cancel(id: "order1", reason: " "))
        try reopened.cancel(id: "order1", reason: "誤会計・全額返金済み")
        XCTAssertThrowsError(try reopened.cancel(id: "order1", reason: "二度目"))
        XCTAssertEqual(try reopened.sales().count, 1)
        XCTAssertNotNil(try reopened.sales().first?.cancelledAt)
        XCTAssertEqual(try reopened.sales().first?.total, 1000)
        XCTAssertEqual(try reopened.sales().filter { $0.cancelledAt == nil }.reduce(0) { $0 + $1.total }, 0)
    }
    func testIdempotencyAndInsufficientCash() throws {
        let store = try SQLiteStore(path: ":memory:")
        XCTAssertThrowsError(try store.checkout(id: "short", lines: [line()], received: 999))
        XCTAssertEqual(try store.sales().count, 0)
        for _ in 0..<100 { _ = try store.checkout(id: "same", lines: [line()], received: 1000) }
        XCTAssertEqual(try store.sales().count, 1)
        XCTAssertThrowsError(try store.checkout(id: "same", lines: [line(price: 600)], received: 1200))
    }
    func testRollbackOnSecondLineWriteFailure() throws {
        let file = path(); defer { try? FileManager.default.removeItem(atPath: file) }
        let store = try SQLiteStore(path: file)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TRIGGER fail_second BEFORE INSERT ON order_lines WHEN NEW.line_no=2 BEGIN SELECT RAISE(ABORT,'injected write failure'); END", nil, nil, nil), SQLITE_OK)
        let second = Line(productID: "p2", name: "別商品", price: 100, quantity: 1)
        XCTAssertThrowsError(try store.checkout(id: "rollback", lines: [line(), second], received: 2000))
        XCTAssertEqual(try store.sales().count, 0)
        XCTAssertEqual(sqlite3_exec(db, "DROP TRIGGER fail_second", nil, nil, nil), SQLITE_OK)
        _ = try store.checkout(id: "rollback", lines: [line(), second], received: 2000)
        XCTAssertEqual(try store.sales().first?.lines.count, 2)
    }
    func testZeroPriceSale() throws {
        let store = try SQLiteStore(path: ":memory:")
        let sale = try store.checkout(id: "free", lines: [line(price: 0)], received: 0)
        XCTAssertEqual(sale.total, 0); XCTAssertEqual(sale.change, 0)
    }
    func testGoldenCSV() throws {
        let sales = [
            Sale(id: "order-a", createdAt: "2026-11-18T00:00:00Z", total: 1100, received: 2000, change: 900, cancelledAt: nil, cancellationReason: nil, lines: [line(), Line(productID: "p2", name: "=SUM(1,2)\n\"商品\"", price: 100, quantity: 1)]),
            Sale(id: "order-b", createdAt: "2026-11-18T00:01:00Z", total: 500, received: 1000, change: 500, cancelledAt: "2026-11-18T00:02:00Z", cancellationReason: "返金済み", lines: [line(quantity: 1)])
        ]
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("shared/golden-sales.csv")
        XCTAssertEqual(Data(SalesCSV.make(sales).utf8), try Data(contentsOf: fixture))
    }
    func testUnknownSchemaIsNotOverwritten() throws {
        let file = path(); defer { try? FileManager.default.removeItem(atPath: file) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA user_version=99", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        XCTAssertThrowsError(try SQLiteStore(path: file))
    }
    func testOldAcknowledgementDoesNotLoseCancellation() throws {
        let store = try SQLiteStore(path: ":memory:")
        _ = try store.checkout(id: "race", lines: [line()], received: 2000)
        XCTAssertEqual(try store.pendingSales().first?.revision, 1)
        try store.cancel(id: "race", reason: "返金済み")
        try store.acknowledge([SyncReceipt(id: "race", revision: 1)])
        XCTAssertEqual(try store.pendingCount(), 1)
        XCTAssertEqual(try store.pendingSales().first?.revision, 2)
        try store.acknowledge([SyncReceipt(id: "race", revision: 2)])
        XCTAssertEqual(try store.pendingCount(), 0)
        try store.acknowledge([SyncReceipt(id: "race", revision: 1)])
        XCTAssertEqual(try store.pendingCount(), 0)
    }
    func testPendingLimitAndGateSurviveRestart() throws {
        let file = path(); defer { try? FileManager.default.removeItem(atPath: file) }
        do {
            let store = try SQLiteStore(path: file)
            for i in 0..<60 { _ = try store.checkout(id: "o\(i)", lines: [line()], received: 2000) }
            XCTAssertEqual(try store.pendingSales().count, 50)
            try store.setSyncGate(next: 1234567890, failures: 3)
            try store.bindSyncTarget("https://test.workers.dev/v1/sync")
            XCTAssertThrowsError(try store.bindSyncTarget("https://other.workers.dev/v1/sync"))
        }
        let reopened = try SQLiteStore(path: file)
        XCTAssertEqual(try reopened.pendingCount(), 60)
        XCTAssertEqual(try reopened.syncGate().next, 1234567890)
        XCTAssertEqual(try reopened.syncGate().failures, 3)
    }
    func testSyncResponseValidationAndBounds() throws {
        let store = try SQLiteStore(path: ":memory:")
        _ = try store.checkout(id: "o1", lines: [line()], received: 2000)
        let pending = try store.pendingSales(); let batch = try SyncPayload.make(pending)
        XCTAssertLessThanOrEqual(batch.data.count, 256 * 1024)
        for json in [
            #"{"schema_version":1,"accepted":[{"id":"other","revision":1}],"conflicts":[]}"#,
            #"{"schema_version":1,"accepted":[{"id":"o1","revision":2}],"conflicts":[]}"#,
            #"{"schema_version":1,"accepted":[],"conflicts":[]}"#,
            #"{"schema_version":1,"accepted":[{"id":"o1","revision":1},{"id":"o1","revision":1}],"conflicts":[]}"#
        ] {
            let response = try JSONDecoder().decode(SyncResponse.self, from: Data(json.utf8))
            XCTAssertThrowsError(try response.validate(for: pending))
        }
        let good = try JSONDecoder().decode(SyncResponse.self, from: Data(#"{"schema_version":1,"accepted":[{"id":"o1","revision":1}],"conflicts":[]}"#.utf8))
        XCTAssertNoThrow(try good.validate(for: pending))
        XCTAssertEqual(SyncPayload.delay(failures: 100), 300)
        XCTAssertEqual(SyncPayload.delay(failures: 1, retryAfter: "999999"), 3600)
        for url in ["http://test.workers.dev", "https://user:pass@test.workers.dev", "https://test.workers.dev/path", "https://test.workers.dev?q=token"] {
            XCTAssertThrowsError(try SyncPayload.endpoint(url))
        }
    }
    func testVersionOneMigrationPreservesPaidAndCancelledSales() throws {
        let file = path(); defer { try? FileManager.default.removeItem(atPath: file) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file, &db), SQLITE_OK)
        let sql = """
        CREATE TABLE products(id TEXT PRIMARY KEY,name TEXT NOT NULL,price INTEGER NOT NULL);
        CREATE TABLE orders(id TEXT PRIMARY KEY,created_at TEXT NOT NULL,total INTEGER NOT NULL,received INTEGER NOT NULL,change_yen INTEGER NOT NULL,cancelled_at TEXT,cancellation_reason TEXT);
        CREATE TABLE order_lines(order_id TEXT NOT NULL,line_no INTEGER NOT NULL,product_id TEXT NOT NULL,name TEXT NOT NULL,price INTEGER NOT NULL,quantity INTEGER NOT NULL,PRIMARY KEY(order_id,line_no));
        INSERT INTO orders VALUES('paid','2026-11-20T00:00:00Z',500,1000,500,NULL,NULL);
        INSERT INTO orders VALUES('cancelled','2026-11-20T00:00:00Z',500,1000,500,'2026-11-20T00:01:00Z','返金済み');
        INSERT INTO order_lines VALUES('paid',1,'p','豆腐',500,1);
        INSERT INTO order_lines VALUES('cancelled',1,'p','豆腐',500,1);
        PRAGMA user_version=1;
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK); sqlite3_close(db)
        let store = try SQLiteStore(path: file)
        XCTAssertEqual(try store.sales().count, 2)
        let pending = try store.pendingSales()
        XCTAssertEqual(pending.first(where: { $0.id == "paid" })?.revision, 1)
        XCTAssertEqual(pending.first(where: { $0.id == "cancelled" })?.revision, 2)
        XCTAssertEqual(try store.sales().filter { $0.cancelledAt == nil }.reduce(Int64(0)) { $0 + $1.total }, 500)
    }
    func testOversizedOrderIsHeldWithoutBlockingOtherOrders() throws {
        let store = try SQLiteStore(path: ":memory:")
        let huge = Line(productID: "huge", name: String(repeating: "a", count: 300000), price: 1, quantity: 1)
        _ = try store.checkout(id: "a-huge", lines: [huge], received: 1)
        _ = try store.checkout(id: "z-small", lines: [line()], received: 2000)
        let batch = try SyncPayload.make(store.pendingSales())
        XCTAssertEqual(batch.oversized, ["a-huge"])
        XCTAssertEqual(batch.orders.map(\.id), ["z-small"])
        try store.holdSync(batch.oversized)
        try store.acknowledge([SyncReceipt(id: "z-small", revision: 1)])
        XCTAssertEqual(try store.pendingCount(), 1)
        XCTAssertEqual(try store.heldSyncCount(), 1)
        XCTAssertTrue(try store.pendingSales().isEmpty)
        XCTAssertEqual(try store.sales().count, 2)
    }
}
