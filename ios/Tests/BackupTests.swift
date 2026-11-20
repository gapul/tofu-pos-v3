import CSQLite

import XCTest
@testable import TofuPOSCore

final class BackupTests: XCTestCase {
    private func sale(price: Int64 = 500) -> Sale {
        Sale(id: "o", createdAt: "2026-11-20T01:00:00Z", total: price, received: 1000, change: 1000-price,
             cancelledAt: nil, cancellationReason: nil, lines: [Line(productID: "p",name: "豆腐",price: price,quantity: 1)])
    }
    private func page(_ order: Sale, revision: Int = 1) -> RestorePage {
        RestorePage(schema_version: 1, catalog_id: nil, after: "", next: "o", products: [Product(id: "p",name: "豆腐",price: 500)], orders: [CloudOrder(sale: order,revision: revision)])
    }
    func testReplayAndLocalCancellationNeverRollsBack() throws {
        let store = try SQLiteStore(path: ":memory:")
        let p = page(sale())
        XCTAssertEqual(try store.restore(p).orders,1); XCTAssertEqual(try store.pendingCount(),0)
        XCTAssertEqual(try store.restore(p).orders,0); XCTAssertEqual(try store.sales().count,1)
        try store.cancel(id: "o",reason: "端末で返金済み")
        _ = try store.restore(p)
        XCTAssertNotNil(try store.sales().first?.cancelledAt); XCTAssertEqual(try store.pendingCount(),1)
        let cancelled = Sale(id: "o",createdAt: sale().createdAt,total: 500,received: 1000,change: 500,cancelledAt: "2026-11-20T01:01:00Z",cancellationReason: "別の取消",lines: sale().lines)
        XCTAssertEqual(try store.restore(page(cancelled,revision: 2)).conflicts,1)
        XCTAssertEqual(try store.sales().first?.cancellationReason,"端末で返金済み"); XCTAssertEqual(try store.pendingCount(),1)
        let end = RestorePage(schema_version: 1,catalog_id: nil,after: "o",next: nil,products: [],orders: [])
        XCTAssertEqual(try store.restore(end).conflicts,1)
    }
    func testRemoteCancellationAndProductConflict() throws {
        let store = try SQLiteStore(path: ":memory:")
        _ = try store.restore(page(sale()))
        try store.saveProduct(Product(id: "p",name: "新しい豆腐",price: 700))
        let cancelled = Sale(id: "o",createdAt: sale().createdAt,total: 500,received: 1000,change: 500,cancelledAt: "2026-11-20T01:01:00Z",cancellationReason: "返金済み",lines: sale().lines)
        let result = try store.restore(page(cancelled,revision: 2))
        XCTAssertEqual(result.cancellations,1); XCTAssertEqual(result.conflicts,1); XCTAssertEqual(try store.pendingCount(),0)
        _ = try store.restore(page(sale()))
        XCTAssertNotNil(try store.sales().first?.cancelledAt)
        XCTAssertEqual(try store.products().first?.price,700); XCTAssertEqual(try store.sales().first?.lines.first?.price,500)
    }
    func testMalformedPageRollsBackAndConflictingBaseIsKept() throws {
        let store = try SQLiteStore(path: ":memory:")
        let invalid = RestorePage(schema_version: 1,catalog_id: nil,after: "",next: "bad",products: page(sale()).products,orders: page(sale()).orders)
        XCTAssertThrowsError(try store.restore(invalid))
        XCTAssertTrue(try store.products().isEmpty); XCTAssertTrue(try store.sales().isEmpty)
        XCTAssertEqual(try store.restoreCursor().after,"")
        _ = try store.restore(page(sale()))
        XCTAssertEqual(try store.restore(page(sale(price: 600))).conflicts,1)
        XCTAssertEqual(try store.sales().first?.total,500)
        XCTAssertEqual(try store.restoreCursor().after,"o")
    }
    func testRestoreSQLFailureRollsBackEntirePageAndCursor() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: file) }
        let store = try SQLiteStore(path: file)
        // A separate SQLite connection injects an actual storage failure.
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(file,&db),SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db,"CREATE TRIGGER fail_restore BEFORE INSERT ON order_lines BEGIN SELECT RAISE(ABORT,'restore failure'); END",nil,nil,nil),SQLITE_OK)
        XCTAssertThrowsError(try store.restore(page(sale())))
        XCTAssertTrue(try store.products().isEmpty); XCTAssertTrue(try store.sales().isEmpty)
        XCTAssertEqual(try store.restoreCursor().after,"")
    }
    func testRestoreTotalsSurviveTheEmptyCompletionPage() throws {
        let store = try SQLiteStore(path: ":memory:")
        _ = try store.restore(page(sale()))
        let end = RestorePage(schema_version: 1,catalog_id: nil,after: "o",next: nil,products: [],orders: [])
        let total = try store.restore(end)
        XCTAssertEqual(total.products,1); XCTAssertEqual(total.orders,1)
        XCTAssertEqual(try store.restoreCursor().after,"")
    }
}
