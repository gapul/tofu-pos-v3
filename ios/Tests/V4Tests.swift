import XCTest
import CSQLite
@testable import TofuPOSCore

final class V4Tests: XCTestCase {
    private let tofu = Line(productID: "p1", name: "豆腐", price: 500, quantity: 2)
    private func sale(_ id: String, at created: String, total: Int64 = 500, cancelled: String? = nil, here: Bool = false, device: String? = "me", age: String? = "adult", gender: String? = "female") -> Sale {
        Sale(id: id, createdAt: created, total: total, received: total, change: 0, cancelledAt: cancelled, cancellationReason: cancelled == nil ? nil : "返金",
             lines: [Line(productID: "p1", name: "豆腐", price: total, quantity: 1)], deviceID: device, customerAge: age, customerGender: gender, cancelledHere: here)
    }
    func testChangeBreakdownSkips2000AndFormats() {
        XCTAssertEqual(Cash.changeText(1300), "1,000円札×1・100円玉×3")
        XCTAssertEqual(Cash.change(2000).map(\.denomination), [1000]); XCTAssertEqual(Cash.change(2000).first?.count, 2)
        XCTAssertEqual(Cash.changeText(0), "なし")
        XCTAssertEqual(Cash.change(18766).map { $0.denomination * $0.count }.reduce(0, +), 18766)
        XCTAssertEqual(Cash.changeText(16_666), "10,000円札×1・5,000円札×1・1,000円札×1・500円玉×1・100円玉×1・50円玉×1・10円玉×1・5円玉×1・1円玉×1")
        XCTAssertEqual(Yen.format(1_000_000_000), "1,000,000,000"); XCTAssertEqual(Yen.format(-1500), "-1,500"); XCTAssertEqual(Yen.format(999), "999")
        XCTAssertEqual(try Cash.total(["10000": 1, "1": 3]), 10003)
        XCTAssertThrowsError(try Cash.total(["3": 1])); XCTAssertThrowsError(try Cash.total(["100": 10000]))
    }
    func testDisplayedStock() throws {
        var p = Product(id: "p1", name: "豆腐", price: 500)
        XCTAssertNil(StockMath.displayed(p, pending: [:]))
        p.cloudStock = 10
        XCTAssertEqual(StockMath.displayed(p, pending: ["p1": 3]), 7)
        XCTAssertNil(StockMath.displayed(Product(id: "p1", name: "豆腐", price: 500), pending: ["p1": 3]), "not fetched is not 0")
        XCTAssertFalse(StockMath.soldOut(p, displayed: -3)); XCTAssertEqual(StockMath.label(-3), "在庫 −3")
        XCTAssertTrue(StockMath.soldOut(Product(id: "s", name: "s", price: 1, stopAtZero: true), displayed: 0))
        XCTAssertFalse(StockMath.soldOut(Product(id: "s", name: "s", price: 1, stopAtZero: true), displayed: nil))
        let pending = StockMath.pendingQuantities([(sale("a", at: "2026-11-21T00:00:00Z"), true), (sale("b", at: "2026-11-21T00:00:00Z"), false),
                                                   (sale("c", at: "2026-11-21T00:00:00Z", cancelled: "2026-11-21T00:01:00Z"), true)])
        XCTAssertEqual(pending, ["p1": 1])
        let store = try SQLiteStore(path: ":memory:")
        try store.saveProduct(Product(id: "p1", name: "豆腐", price: 500))
        let sent = try store.dirtyProducts().map(ProductUpload.init)
        let server = CloudProduct(id: "p1", name: "豆腐", price: 500, active: true, version: 1, stock: 10, seq: 1)
        _ = try store.applyProductResults([ProductResponse.Result(id: "p1", status: "applied", product: server)], sent: sent)
        _ = try store.checkout(id: "o1", lines: [tofu], received: 1000)
        XCTAssertEqual(try store.displayedStock()["p1"], 8)
        try store.cancel(id: "o1", reason: "返金")
        XCTAssertEqual(try store.displayedStock()["p1"], 10)
        _ = try store.checkout(id: "o2", lines: [tofu], received: 1000)
        try store.acknowledge([SyncReceipt(id: "o2", revision: 1)])
        XCTAssertEqual(try store.displayedStock()["p1"], 10)
    }
    func testExpectedCash() {
        let sales = [
            sale("before", at: "2026-11-21T00:59:59Z", total: 300, cancelled: "2026-11-21T01:30:00Z", here: true),
            sale("in", at: "2026-11-21T01:00:00Z", total: 500),
            sale("in-cancelled", at: "2026-11-21T01:10:00Z", total: 700, cancelled: "2026-11-21T01:20:00Z", here: true),
            sale("in-cancelled-elsewhere", at: "2026-11-21T01:11:00Z", total: 50, cancelled: "2026-11-21T01:21:00Z"),
            sale("legacy", at: "2026-11-21T01:15:00.250Z", total: 100, device: nil, age: nil, gender: nil),
            sale("other-device", at: "2026-11-21T01:20:00Z", total: 9000, device: "other"),
            sale("other-cancelled-here", at: "2026-11-21T00:10:00Z", total: 400, cancelled: "2026-11-21T01:40:00Z", here: true, device: "other"),
            sale("after", at: "2026-11-21T02:00:00Z", total: 800)
        ]
        let s = DrawerMath.summary(floatTotal: 10000, sales: sales, deviceID: "me", openedAt: "2026-11-21T01:00:00Z", closedAt: "2026-11-21T02:00:00Z")
        XCTAssertEqual(s.salesTotal, 1250); XCTAssertEqual(s.cancelTotal, 1400); XCTAssertEqual(s.orderCount, 3)
        XCTAssertEqual(s.expected, 9850); XCTAssertEqual(s.segments, ["adult/female": 1])
        XCTAssertEqual(DrawerMath.summary(floatTotal: 0, sales: [sale("x", at: "2026-11-21T00:00:00Z", cancelled: "2026-11-21T01:30:00Z", here: true)], deviceID: "me", openedAt: "2026-11-21T01:00:00Z", closedAt: nil).expected, -500)
        XCTAssertEqual(DrawerMath.summary(floatTotal: 10000, sales: sales, deviceID: "me", openedAt: "2026-11-21T01:00:00Z", closedAt: nil).salesTotal, 2050)
    }
    func testDrawerSessionLifecycle() throws {
        let store = try SQLiteStore(path: ":memory:")
        let open = try store.openSession(float: ["1000": 5, "100": 10])
        XCTAssertEqual(open.floatTotal, 6000); XCTAssertThrowsError(try store.openSession(float: [:]))
        _ = try store.checkout(id: "o1", lines: [tofu], received: 1000, customer: Customer(age: .student, gender: .male))
        XCTAssertEqual(try store.sessionSummary(open).expected, 7000)
        let pendingOpen = try store.pendingSessions()
        let closed = try store.closeSession(id: open.id, counted: ["1000": 7])
        XCTAssertEqual(closed.countedTotal, 7000); XCTAssertEqual(closed.expectedTotal, 7000); XCTAssertEqual(closed.orderCount, 1)
        try store.acknowledgeSessions(pendingOpen, accepted: [open.id])
        XCTAssertEqual(try store.pendingSessions().count, 1, "closed after read: still pending")
        let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SessionUpload(session: closed, deviceID: store.deviceID, deviceLabel: "iPhone", summary: try store.sessionSummary(closed)))) as! [String: Any]
        XCTAssertEqual(payload["expected_total"] as? Int, 7000); XCTAssertEqual((payload["float"] as? [String: Int])?["1000"], 5)
        try store.acknowledgeSessions(try store.pendingSessions(), accepted: [open.id])
        XCTAssertTrue(try store.pendingSessions().isEmpty); XCTAssertNil(try store.currentSession())
        XCTAssertNoThrow(try store.openSession(float: [:]))
        let reopened = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SessionUpload(session: try store.currentSession()!, deviceID: "d", deviceLabel: "x", summary: try store.sessionSummary(try store.currentSession()!)))) as! [String: Any]
        XCTAssertTrue(reopened["closed_at"] is NSNull); XCTAssertTrue(reopened["counted"] is NSNull)
    }
    func testOrderPayloadOmitsNilFields() throws {
        let store = try SQLiteStore(path: ":memory:")
        _ = try store.checkout(id: "new", lines: [tofu], received: 1000, customer: Customer(age: .senior, gender: .other))
        let order = try XCTUnwrap(store.pendingSales().first)
        let json = String(decoding: try JSONEncoder().encode(order), as: UTF8.self)
        XCTAssertTrue(json.contains("\"customer_age\":\"senior\"")); XCTAssertTrue(json.contains("\"device_id\":\"\(store.deviceID)\""))
        let legacy = CloudOrder(sale: Sale(id: "old", createdAt: "2026-11-20T00:00:00Z", total: 500, received: 500, change: 0, cancelledAt: nil, cancellationReason: nil, lines: [tofu]), revision: 1)
        let legacyJSON = String(decoding: try JSONEncoder().encode(legacy), as: UTF8.self)
        for key in ["device_id", "customer_age", "customer_gender", "cancelled_at"] { XCTAssertFalse(legacyJSON.contains(key), key) }
    }
    func testVersionTwoMigrationKeepsDataAndAddsDevice() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tofu-v2-\(UUID()).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: file) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, V4Fixture.versionTwo, nil, nil, nil), SQLITE_OK); sqlite3_close(db)
        let store = try SQLiteStore(path: file)
        let id = store.deviceID
        XCTAssertFalse(id.isEmpty)
        XCTAssertEqual(try store.products().first?.dirty, true); XCTAssertEqual(try store.products().first?.version, 0)
        XCTAssertEqual(try store.sales().count, 1); XCTAssertNil(try store.sales().first?.deviceID); XCTAssertEqual(try store.pendingCount(), 0)
        XCTAssertEqual(try store.syncGate().failures, 2)
        XCTAssertEqual(try SQLiteStore(path: file).deviceID, id)
    }
    func testFeedApply() throws {
        let store = try SQLiteStore(path: ":memory:")
        try store.saveProduct(Product(id: "local", name: "編集中", price: 100))
        let remote = Sale(id: "remote", createdAt: "2026-11-21T01:00:00Z", total: 500, received: 1000, change: 500, cancelledAt: nil, cancellationReason: nil,
                          lines: [Line(productID: "p1", name: "豆腐", price: 500, quantity: 1)], deviceID: "other", customerAge: "child", customerGender: "male")
        let page = FeedPage(after: 0, next: 3, has_more: false, products: [
            CloudProduct(id: "p1", name: "豆腐", price: 500, active: true, version: 2, stock: 9, seq: 1),
            CloudProduct(id: "local", name: "他端末", price: 200, active: true, version: 1, stock: nil, seq: 2)
        ], orders: [FeedOrder(order: CloudOrder(sale: remote, revision: 1), seq: 3)])
        XCTAssertThrowsError(try store.applyFeed(FeedPage(after: 5, next: 6, has_more: false, products: page.products, orders: [])))
        XCTAssertThrowsError(try store.applyFeed(FeedPage(after: 0, next: 9, has_more: false, products: page.products, orders: page.orders)))
        XCTAssertEqual(try store.feedAfter(), 0)
        let result = try store.applyFeed(page)
        XCTAssertEqual(result.products, 1); XCTAssertEqual(result.orders, 1)
        XCTAssertEqual(try store.feedAfter(), 3); XCTAssertNotNil(try store.lastFeedAt())
        XCTAssertEqual(try store.products().first { $0.id == "local" }?.name, "編集中")
        XCTAssertEqual(try store.products().first { $0.id == "p1" }?.cloudStock, 9)
        XCTAssertEqual(try store.pendingCount(), 0); XCTAssertEqual(try store.sales().first?.customerAge, "child")
        let cancelled = Sale(id: "remote", createdAt: remote.createdAt, total: 500, received: 1000, change: 500, cancelledAt: "2026-11-21T01:05:00Z", cancellationReason: "返金",
                             lines: remote.lines, deviceID: "other", customerAge: "child", customerGender: "male")
        XCTAssertEqual(try store.applyFeed(FeedPage(after: 3, next: 4, has_more: false, products: [], orders: [FeedOrder(order: CloudOrder(sale: cancelled, revision: 2), seq: 4)])).cancellations, 1)
        XCTAssertEqual(try store.applyFeed(FeedPage(after: 4, next: 5, has_more: false, products: [], orders: [FeedOrder(order: CloudOrder(sale: remote, revision: 1), seq: 5)])).orders, 0)
        XCTAssertNotNil(try store.sales().first?.cancelledAt, "cancellation is monotonic")
        XCTAssertEqual(try store.sales().first?.cancelledHere, false, "feed cancellation was not recorded here")
        _ = try store.checkout(id: "mine", lines: [tofu], received: 1000, customer: Customer(age: .adult, gender: .male))
        let mine = try XCTUnwrap(store.pendingSales().first)
        XCTAssertEqual(try store.applyFeed(FeedPage(after: 5, next: 6, has_more: false, products: [], orders: [FeedOrder(order: mine, seq: 6)])).conflicts, 0)
        XCTAssertEqual(try store.pendingCount(), 0)
    }
    func testProductResultsAndStockEvents() throws {
        let store = try SQLiteStore(path: ":memory:")
        try store.saveProduct(Product(id: "p1", name: "豆腐", price: 500))
        try store.saveProduct(Product(id: "p2", name: "揚げ", price: 300))
        let sent = try store.dirtyProducts().map(ProductUpload.init)
        XCTAssertEqual(sent.map(\.base_version), [0, 0])
        try store.saveProduct(Product(id: "p2", name: "厚揚げ", price: 300))
        let names = try store.applyProductResults([
            ProductResponse.Result(id: "p1", status: "conflict", product: CloudProduct(id: "p1", name: "絹豆腐", price: 550, active: true, version: 4, stock: 3, seq: 9)),
            ProductResponse.Result(id: "p2", status: "applied", product: CloudProduct(id: "p2", name: "揚げ", price: 300, active: true, version: 1, stock: nil, seq: 10))
        ], sent: sent)
        XCTAssertEqual(names, ["絹豆腐"])
        XCTAssertEqual(try store.dirtyProducts().map(\.id), ["p2"]); XCTAssertEqual(try store.dirtyProducts().first?.version, 1)
        try store.saveProduct(Product(id: "p1", name: "絹豆腐", price: 550))
        XCTAssertEqual(try store.dirtyProducts().map(\.id), ["p2"], "unchanged save stays clean")
        XCTAssertThrowsError(try store.addStockEvent(productID: "missing", kind: "add", quantity: 5))
        XCTAssertThrowsError(try store.addStockEvent(productID: "p1", kind: "set", quantity: -1))
        try store.addStockEvent(productID: "p1", kind: "add", quantity: 5)
        try store.addStockEvent(productID: "p1", kind: "set", quantity: 20, reason: "棚卸")
        let events = try store.pendingStockEvents()
        XCTAssertEqual(events.map(\.kind), ["add", "set"])
        try store.acknowledgeStock(events.map(\.id), products: [CloudProduct(id: "p1", name: "絹豆腐", price: 550, active: true, version: 4, stock: 20, seq: 11)])
        XCTAssertEqual(try store.pendingStockEventCount(), 0); XCTAssertEqual(try store.displayedStock()["p1"], 20)
        XCTAssertThrowsError(try store.saveProduct(Product(id: "p3", name: String(repeating: "👨‍👩‍👧", count: 21), price: 1)), "100 code points max")
        try store.saveProduct(Product(id: "p3", name: String(repeating: "あ", count: 100), price: 1))
    }
    func testProductImages() throws {
        XCTAssertTrue(ProductImages.fitted(width: 4032, height: 3024) == (800, 600))
        XCTAssertTrue(ProductImages.fitted(width: 1000, height: 3000) == (267, 800))
        XCTAssertTrue(ProductImages.fitted(width: 640, height: 480) == (640, 480), "never enlarges")
        XCTAssertEqual(ProductImages.sha256(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tofu-images-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let images = try ProductImages(directory: dir)
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
        XCTAssertThrowsError(try images.save(Data([0x89, 0x50, 0x4E, 0x47])), "JPEG only")
        XCTAssertThrowsError(try images.save(jpeg, expected: String(repeating: "0", count: 64)), "content must match the hash")
        let hash = try images.save(jpeg)
        XCTAssertTrue(images.exists(hash)); XCTAssertEqual(images.data(hash), jpeg)
        let other = try images.save(Data([0xFF, 0xD8, 0xFF, 9]))
        XCTAssertEqual(images.cleanup(keep: [hash]), 1); XCTAssertFalse(images.exists(other))

        let store = try SQLiteStore(path: ":memory:")
        try store.saveProduct(Product(id: "p", name: "田楽豆腐", price: 500))
        let first = try store.dirtyProducts().map(ProductUpload.init)
        _ = try store.applyProductResults([ProductResponse.Result(id: "p", status: "applied", product: CloudProduct(id: "p", name: "田楽豆腐", price: 500, active: true, version: 1, stock: 0, seq: 1))], sent: first)
        try store.registerImage(hash)
        try store.saveProduct(Product(id: "p", name: "田楽豆腐", price: 500, imageHash: hash))
        XCTAssertEqual(try store.products().first?.imageHash, hash)
        XCTAssertTrue(try store.dirtyProducts().isEmpty, "waits for its photo upload")
        XCTAssertEqual(try store.pendingImages(), [hash]); XCTAssertEqual(try store.imageHashesInUse(), [hash])
        try store.markImageUploaded(hash)
        let sent = try store.dirtyProducts().map(ProductUpload.init)
        XCTAssertEqual(sent.first?.image_hash, hash); XCTAssertTrue(try store.pendingImages().isEmpty)
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(sent[0]), as: UTF8.self).contains("\"image_hash\":\"\(hash)\""))
        try store.saveProduct(Product(id: "p", name: "田楽豆腐", price: 500))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(try store.dirtyProducts().map(ProductUpload.init)[0]), as: UTF8.self).contains("image_hash"), "removed photo")
        let bad = String(repeating: "b", count: 64)
        try store.registerImage(bad); try store.rejectImage(bad)
        try store.saveProduct(Product(id: "q", name: "揚げ", price: 300, imageHash: bad))
        XCTAssertEqual(try store.rejectedImageCount(), 1); XCTAssertFalse(try store.dirtyProducts().map(\.id).contains("q"), "product with a rejected photo is held")
        let remote = String(repeating: "c", count: 64)
        _ = try store.applyFeed(FeedPage(after: 0, next: 1, has_more: false, products: [CloudProduct(id: "r", name: "他", price: 1, active: true, image_hash: remote, version: 1, stock: 0, seq: 1)], orders: []))
        XCTAssertTrue(try store.productImageHashes().contains(remote))
        XCTAssertThrowsError(try store.registerImage("not-a-hash"))
        XCTAssertThrowsError(try JSONDecoder().decode(FeedPage.self, from: Data(#"{"schema_version":1,"after":1,"next":2,"has_more":false,"orders":[],"products":[{"id":"x","name":"x","price":1,"active":true,"version":1,"stock":0,"seq":2,"image_hash":"ZZ"}]}"#.utf8)).validate(after: 1))
    }
    func testQuickSale() throws {
        var p = Product(id: "p", name: "田楽豆腐", price: 500)
        XCTAssertEqual(QuickSale.maxQuantity(p, displayed: -3), 999)
        p.stopAtZero = true
        XCTAssertEqual(QuickSale.maxQuantity(p, displayed: 42), 42); XCTAssertEqual(QuickSale.maxQuantity(p, displayed: -1), 0)
        XCTAssertEqual(QuickSale.maxQuantity(p, displayed: nil), 999)
        XCTAssertEqual(QuickSale.changeNote(0), "お釣りなし"); XCTAssertEqual(QuickSale.changeNote(4000), "1,000円札×4")
        let store = try SQLiteStore(path: ":memory:")
        let sale = try store.checkout(id: "q", lines: [Line(productID: "p", name: "田楽豆腐", price: 500, quantity: 2)], received: 5000)
        XCTAssertEqual(QuickSale.savedText(sale), "¥1,000（2本）を保存しました・お釣り ¥4,000")
        XCTAssertNil(sale.customerAge, "segment is optional")
        XCTAssertEqual(try store.pendingSales().first.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self).contains("customer_age") }, false)
        try store.cancel(id: "q", reason: QuickSale.undoReason)
        XCTAssertEqual(try store.sales().first?.cancelledHere, true); XCTAssertEqual(try store.sales().first?.cancellationReason, "確定直後の取消")
    }
    func testStopAtZeroRoundTrip() throws {
        let store = try SQLiteStore(path: ":memory:")
        try store.saveProduct(Product(id: "p", name: "豆腐", price: 500, stopAtZero: true))
        let sent = try store.dirtyProducts().map(ProductUpload.init)
        let json = String(decoding: try JSONEncoder().encode(sent[0]), as: UTF8.self)
        XCTAssertTrue(json.contains("\"stop_at_zero\":true")); XCTAssertTrue(json.contains("\"track_stock\":true"))
        let decoded = try JSONDecoder().decode(CloudProduct.self, from: Data(#"{"id":"p","name":"豆腐","price":500,"active":true,"track_stock":true,"version":1,"stock":-2,"seq":3}"#.utf8))
        XCTAssertFalse(decoded.stop_at_zero); XCTAssertEqual(decoded.stock, -2)
        _ = try store.applyProductResults([ProductResponse.Result(id: "p", status: "applied", product: decoded)], sent: sent)
        XCTAssertEqual(try store.products().first?.stopAtZero, false); XCTAssertEqual(try store.displayedStock()["p"], -2)
        try store.addStockEvent(productID: "p", kind: "add", quantity: 5)
        XCTAssertEqual(try store.pendingStockEventCount(), 1)
    }
    func testRejectedItemsAreHeldPerStep() throws {
        let store = try SQLiteStore(path: ":memory:")
        try store.saveProduct(Product(id: "p1", name: "豆腐", price: 500))
        try store.addStockEvent(productID: "p1", kind: "add", quantity: 3)
        let open = try store.openSession(float: ["1000": 1])
        try store.rejectProducts(try store.dirtyProducts().map(\.id))
        try store.rejectStockEvents(try store.pendingStockEvents().map(\.id))
        try store.rejectSessions(try store.pendingSessions().map(\.id))
        XCTAssertTrue(try store.dirtyProducts().isEmpty); XCTAssertTrue(try store.pendingStockEvents().isEmpty); XCTAssertTrue(try store.pendingSessions().isEmpty)
        XCTAssertEqual(try store.rejectedCounts().products, 1); XCTAssertEqual(try store.rejectedCounts().stock, 1); XCTAssertEqual(try store.rejectedCounts().sessions, 1)
        try store.saveProduct(Product(id: "p1", name: "絹豆腐", price: 500))
        XCTAssertEqual(try store.dirtyProducts().count, 1, "a new edit is sent again")
        _ = try store.closeSession(id: open.id, counted: ["1000": 1])
        XCTAssertEqual(try store.pendingSessions().count, 1, "closing makes the session sendable again")
    }
    func testConflictsPersistAndManualRelease() throws {
        let store = try SQLiteStore(path: ":memory:")
        _ = try store.checkout(id: "c", lines: [tofu], received: 1000)
        _ = try store.checkout(id: "d", lines: [tofu], received: 1000)
        try store.markConflicts(["c"])
        XCTAssertEqual(try store.pendingSales().map(\.id), ["d"]); XCTAssertEqual(try store.conflictCount(), 1); XCTAssertEqual(try store.heldSyncCount(), 0)
        try store.cancel(id: "c", reason: "返金")
        XCTAssertEqual(try store.sales().first { $0.id == "c" }?.cancelledHere, true)
        try store.releaseConflicts()
        XCTAssertEqual(try store.pendingSales().map(\.id), ["c", "d"]); XCTAssertEqual(try store.conflictCount(), 0)
        try store.setMetadata("auth_blocked", "1"); XCTAssertEqual(try store.metadata("auth_blocked"), "1")
        try store.setMetadata("auth_blocked", nil); XCTAssertNil(try store.metadata("auth_blocked"))
    }
}

enum V4Fixture {
    static let versionTwo = """
    CREATE TABLE products(id TEXT PRIMARY KEY,name TEXT NOT NULL,price INTEGER NOT NULL);
    CREATE TABLE orders(id TEXT PRIMARY KEY,created_at TEXT NOT NULL,total INTEGER NOT NULL,received INTEGER NOT NULL,change_yen INTEGER NOT NULL,cancelled_at TEXT,cancellation_reason TEXT,revision INTEGER NOT NULL DEFAULT 1,synced_revision INTEGER NOT NULL DEFAULT 0,sync_error TEXT);
    CREATE TABLE order_lines(order_id TEXT NOT NULL,line_no INTEGER NOT NULL,product_id TEXT NOT NULL,name TEXT NOT NULL,price INTEGER NOT NULL,quantity INTEGER NOT NULL,PRIMARY KEY(order_id,line_no));
    CREATE TABLE sync_metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);
    INSERT INTO products VALUES('p','豆腐',500);
    INSERT INTO orders VALUES('o','2026-11-20T00:00:00Z',500,1000,500,NULL,NULL,1,1,NULL);
    INSERT INTO order_lines VALUES('o',1,'p','豆腐',500,1);
    INSERT INTO sync_metadata VALUES('failures','2');
    PRAGMA user_version=2;
    """
}
