import Foundation
import CSQLite

func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
    if try !condition() { throw POSFailure.invalid("FAILED: " + label) }
}
func rejects(_ label: String, _ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw POSFailure.invalid("Expected rejection: " + label)
}
let file = FileManager.default.temporaryDirectory.appendingPathComponent("tofu-verify-\(UUID()).sqlite").path
defer { try? FileManager.default.removeItem(atPath: file) }
let line = Line(productID: "p1", name: "豆腐", price: 500, quantity: 2)
do {
    try check(Money.total([line]) == 1000, "integer total")
    for invalid in ["", "-1", "1.5", " 500", "１００", "1000000001", String(repeating: "9", count: 50)] {
        try check(Money.parse(invalid) == nil, "money input")
    }
    try rejects("quantity") { _ = try Money.total([Line(productID: "p", name: "p", price: 1, quantity: 1000)]) }
    try rejects("overflow") { _ = try Money.total([Line(productID: "p", name: "p", price: Money.maximum, quantity: 2)]) }
    do {
        let store = try SQLiteStore(path: file)
        try store.saveProduct(Product(id: "p1", name: "豆腐", price: 500))
        try rejects("insufficient cash") { _ = try store.checkout(id: "short", lines: [line], received: 999) }
        try check(store.sales().isEmpty, "invalid checkout creates nothing")
        for _ in 0..<100 { _ = try store.checkout(id: "same", lines: [line], received: 2000) }
        try check(store.sales().count == 1, "100 retries yield 1 order")
        try rejects("mismatched command") { _ = try store.checkout(id: "same", lines: [line], received: 3000) }
        try store.saveProduct(Product(id: "p1", name: "新豆腐", price: 700))
    }
    let store = try SQLiteStore(path: file)
    try check(store.products().first?.price == 700, "product survives reopen")
    try check(store.sales().first?.lines.first?.price == 500, "sale price snapshot")
    try store.cancel(id: "same", reason: "全額返金済み")
    try check(store.sales().first?.cancelledAt != nil, "cancellation persists")
    try rejects("double cancel") { try store.cancel(id: "same", reason: "再度") }
    var db: OpaquePointer?
    try check(sqlite3_open(file, &db) == SQLITE_OK, "open fault injection connection")
    defer { sqlite3_close(db) }
    try check(sqlite3_exec(db, "CREATE TRIGGER fail_second BEFORE INSERT ON order_lines WHEN NEW.line_no=2 BEGIN SELECT RAISE(ABORT,'injected failure'); END", nil, nil, nil) == SQLITE_OK, "install fault")
    let second = Line(productID: "p2", name: "別商品", price: 100, quantity: 1)
    try rejects("second write failure") { _ = try store.checkout(id: "rollback", lines: [line, second], received: 2000) }
    try check(store.sales().count == 1, "failed order rolled back")
    try check(sqlite3_exec(db, "DROP TRIGGER fail_second", nil, nil, nil) == SQLITE_OK, "remove fault")
    _ = try store.checkout(id: "rollback", lines: [line, second], received: 2000)
    try check(store.sales().count == 2, "retry after rollback")
    let free = try store.checkout(id: "free", lines: [Line(productID: "p3", name: "無料", price: 0, quantity: 1)], received: 0)
    try check(free.total == 0 && free.change == 0, "zero price")
    let fixture = [
        Sale(id: "order-a", createdAt: "2026-11-18T00:00:00Z", total: 1100, received: 2000, change: 900, cancelledAt: nil, cancellationReason: nil, lines: [line, Line(productID: "p2", name: "=SUM(1,2)\n\"商品\"", price: 100, quantity: 1)]),
        Sale(id: "order-b", createdAt: "2026-11-18T00:01:00Z", total: 500, received: 1000, change: 500, cancelledAt: "2026-11-18T00:02:00Z", cancellationReason: "返金済み", lines: [Line(productID: "p1", name: "豆腐", price: 500, quantity: 1)])
    ]
    try check(Data(SalesCSV.make(fixture).utf8) == Data(contentsOf: URL(fileURLWithPath: "shared/golden-sales.csv")), "shared golden CSV")
    try v4Checks()
    print("PASS: money boundaries, persistence, price snapshots, 100 retries, conflicting payload, cancellation, rollback, zero price, shared CSV, v4 change/stock/drawer/feed/migration")
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}

func v4Checks() throws {
    try check(Cash.changeText(1300) == "1,000円札×1・100円玉×3", "change breakdown")
    try check(Cash.change(2000).map(\.denomination) == [1000] && Cash.change(2000)[0].count == 2, "no 2000 notes in change")
    try check(Cash.changeText(0) == "なし" && Yen.format(1_000_000_000) == "1,000,000,000" && Yen.format(-1500) == "-1,500", "yen format")
    try check(Cash.change(18766).map { $0.denomination * $0.count }.reduce(0, +) == 18766, "breakdown sums")
    try rejects("bad denomination") { _ = try Cash.total(["3": 1]) }
    try rejects("too many pieces") { _ = try Cash.total(["100": 10000]) }
    func sale(_ id: String, _ created: String, _ total: Int64, cancelled: String? = nil, here: Bool = false, device: String? = "me", age: String? = "adult") -> Sale {
        Sale(id: id, createdAt: created, total: total, received: total, change: 0, cancelledAt: cancelled, cancellationReason: cancelled == nil ? nil : "返金",
             lines: [Line(productID: "p1", name: "豆腐", price: total, quantity: 1)], deviceID: device, customerAge: age, customerGender: age == nil ? nil : "female", cancelledHere: here)
    }
    let window = [sale("before", "2026-11-21T00:59:59Z", 300, cancelled: "2026-11-21T01:30:00Z", here: true), sale("in", "2026-11-21T01:00:00Z", 500),
                  sale("in-cancelled", "2026-11-21T01:10:00Z", 700, cancelled: "2026-11-21T01:20:00Z", here: true),
                  sale("in-cancelled-elsewhere", "2026-11-21T01:11:00Z", 50, cancelled: "2026-11-21T01:21:00Z"),
                  sale("legacy", "2026-11-21T01:15:00.250Z", 100, device: nil, age: nil), sale("other", "2026-11-21T01:20:00Z", 9000, device: "other"),
                  sale("other-cancelled-here", "2026-11-21T00:10:00Z", 400, cancelled: "2026-11-21T01:40:00Z", here: true, device: "other"),
                  sale("after", "2026-11-21T02:00:00Z", 800)]
    let summary = DrawerMath.summary(floatTotal: 10000, sales: window, deviceID: "me", openedAt: "2026-11-21T01:00:00Z", closedAt: "2026-11-21T02:00:00Z")
    try check(summary.salesTotal == 1250 && summary.cancelTotal == 1400 && summary.orderCount == 3 && summary.expected == 9850 && summary.segments == ["adult/female": 1], "expected cash: own device_id only, cancellations recorded here")
    var tracked = Product(id: "p1", name: "豆腐", price: 500)
    try check(StockMath.displayed(tracked, pending: ["p1": 3]) == nil, "unknown stock")
    tracked.cloudStock = 10
    try check(StockMath.displayed(tracked, pending: ["p1": 3]) == 7 && StockMath.displayed(Product(id: "p1", name: "豆腐", price: 500), pending: [:]) == nil, "displayed stock")

    let tofu = Line(productID: "p1", name: "豆腐", price: 500, quantity: 2)
    let store = try SQLiteStore(path: ":memory:")
    try store.saveProduct(Product(id: "p1", name: "豆腐", price: 500))
    try store.saveProduct(Product(id: "p2", name: "揚げ", price: 300))
    let sent = try store.dirtyProducts().map(ProductUpload.init)
    try store.saveProduct(Product(id: "p2", name: "厚揚げ", price: 300))
    let overridden = try store.applyProductResults([
        ProductResponse.Result(id: "p1", status: "conflict", product: CloudProduct(id: "p1", name: "絹豆腐", price: 550, active: true, version: 4, stock: 10, seq: 1)),
        ProductResponse.Result(id: "p2", status: "applied", product: CloudProduct(id: "p2", name: "揚げ", price: 300, active: true, version: 1, stock: nil, seq: 2))], sent: sent)
    try check(overridden == ["絹豆腐"] && store.dirtyProducts().map(\.id) == ["p2"] && store.dirtyProducts().first?.version == 1, "product results")
    _ = try store.checkout(id: "o1", lines: [tofu], received: 1000, customer: Customer(age: .senior, gender: .other))
    try check(store.displayedStock()["p1"] == 8, "pending sale lowers stock")
    let json = String(decoding: try JSONEncoder().encode(store.pendingSales()[0]), as: UTF8.self)
    try check(json.contains("\"customer_age\":\"senior\"") && json.contains(store.deviceID), "order carries segment and device")
    let legacy = String(decoding: try JSONEncoder().encode(CloudOrder(sale: Sale(id: "old", createdAt: "2026-11-20T00:00:00Z", total: 500, received: 500, change: 0, cancelledAt: nil, cancellationReason: nil, lines: [tofu]), revision: 1)), as: UTF8.self)
    try check(!legacy.contains("device_id") && !legacy.contains("customer_") && !legacy.contains("cancelled_at"), "nil keys omitted")
    try store.cancel(id: "o1", reason: "返金")
    try check(store.displayedStock()["p1"] == 10, "cancelled pending sale")
    try check(store.sales().first { $0.id == "o1" }?.cancelledHere == true, "cancelled_here set locally")
    try rejects("100 code points") { try store.saveProduct(Product(id: "long", name: String(repeating: "👨‍👩‍👧", count: 21), price: 1)) }
    try store.rejectProducts(["p2"])
    try check(store.dirtyProducts().isEmpty && store.rejectedCounts().products == 1, "rejected product held")
    try check(ProductImages.fitted(width: 4032, height: 3024) == (800, 600) && ProductImages.fitted(width: 640, height: 480) == (640, 480)
              && ProductImages.fitted(width: 1000, height: 3000) == (267, 800), "photo resize size")
    try check(ProductImages.sha256(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "sha256 hex")
    let imageDir = FileManager.default.temporaryDirectory.appendingPathComponent("tofu-images-\(UUID())")
    defer { try? FileManager.default.removeItem(at: imageDir) }
    let images = try ProductImages(directory: imageDir)
    try rejects("png is not stored") { _ = try images.save(Data([0x89, 0x50, 0x4E, 0x47])) }
    try rejects("hash mismatch") { _ = try images.save(Data([0xFF, 0xD8, 0xFF, 1]), expected: String(repeating: "0", count: 64)) }
    let photo = try images.save(Data([0xFF, 0xD8, 0xFF, 1]))
    let stray = try images.save(Data([0xFF, 0xD8, 0xFF, 2]))
    try check(images.cleanup(keep: [photo]) == 1 && images.exists(photo) && !images.exists(stray), "photo cleanup")
    let pics = try SQLiteStore(path: ":memory:")
    try pics.registerImage(photo)
    try pics.saveProduct(Product(id: "p", name: "田楽豆腐", price: 500, imageHash: photo))
    try check(pics.dirtyProducts().isEmpty && pics.pendingImages() == [photo], "product waits for photo upload")
    try pics.markImageUploaded(photo)
    try check(pics.dirtyProducts().first?.imageHash == photo && pics.pendingImages().isEmpty, "photo uploaded, product sendable")
    let rejected = String(repeating: "b", count: 64)
    try pics.registerImage(rejected); try pics.rejectImage(rejected)
    try pics.saveProduct(Product(id: "q", name: "揚げ", price: 300, imageHash: rejected))
    try check(pics.rejectedImageCount() == 1 && !pics.dirtyProducts().map(\.id).contains("q"), "rejected photo holds product")
    try check(AppEnvironment.stored(nil) == .production && AppEnvironment.stored("test") == .test && AppEnvironment.production.databaseFile == "tofu-pos.sqlite"
              && AppEnvironment.production.keychainAccount == "connection" && AppEnvironment.test.databaseFile != AppEnvironment.production.databaseFile
              && AppEnvironment.test.imageFolder != AppEnvironment.production.imageFolder && AppEnvironment.test.bundledConnection == "sync-default-test", "environment separation")
    let tickets = try SQLiteStore(path: ":memory:")
    let ticketDay = ISO8601DateFormatter().date(from: "2026-11-21T14:59:00Z")!
    tickets.clock = { ticketDay }
    try check(tickets.checkout(id: "a", lines: [tofu], received: 1000).ticketNo == "1" && tickets.checkout(id: "a", lines: [tofu], received: 1000).ticketNo == "1", "ticket idempotent")
    try tickets.setTicketPrefix("A")
    try check(tickets.checkout(id: "b", lines: [tofu], received: 1000).ticketNo == "A-2", "ticket prefix")
    try rejects("lowercase prefix") { try tickets.setTicketPrefix("a") }
    tickets.clock = { ticketDay.addingTimeInterval(60) }
    try check(tickets.checkout(id: "c", lines: [tofu], received: 1000, customer: Customer(age: nil, gender: nil, group: .couple)).ticketNo == "A-1", "ticket resets on JST date change")
    try check(Ticket.valid("AB-9999") && !Ticket.valid("ABC-1") && !Ticket.valid("12345") && Ticket.next(9999) == 1, "ticket format")
    let ticketJSON = String(decoding: try JSONEncoder().encode(tickets.pendingSales().first { $0.id == "c" }!), as: UTF8.self)
    try check(ticketJSON.contains("\"ticket_no\":\"A-1\"") && ticketJSON.contains("\"customer_group\":\"couple\"") && !ticketJSON.contains("customer_age"), "group and ticket in payload")
    try check(SalesCSV.make(tickets.sales(), ticket: true).contains(",ticket_no\r\n") && Customer.text(age: "adult", gender: nil, group: "couple") == "大人・カップル", "ticket csv, segment text")
    let quick = try SQLiteStore(path: ":memory:")
    let quickSale = try quick.checkout(id: "q", lines: [Line(productID: "p", name: "田楽豆腐", price: 500, quantity: 2)], received: 5000)
    try check(QuickSale.savedText(quickSale) == "¥1,000（2本）を保存しました・お釣り ¥4,000" && quickSale.customerAge == nil, "quick sale notice, optional segment")
    try quick.cancel(id: "q", reason: QuickSale.undoReason)
    try check(quick.sales()[0].cancelledHere && quick.sales()[0].cancellationReason == "確定直後の取消", "undo right after checkout")
    try check(QuickSale.maxQuantity(Product(id: "x", name: "x", price: 1, stopAtZero: true), displayed: 42) == 42
              && QuickSale.maxQuantity(Product(id: "x", name: "x", price: 1), displayed: -3) == 999 && QuickSale.changeNote(0) == "お釣りなし", "quick sale limits")
    try check(QuickSale.Choice.exact.toggled(.exact) == .none && QuickSale.Choice.none.toggled(.preset(1000)) == .preset(1000)
              && QuickSale.change(total: 1000, choice: .none, manual: "") == nil && QuickSale.change(total: 1000, choice: .preset(5000), manual: "") == 4000
              && QuickSale.change(total: 1000, choice: .manual, manual: "999") == nil, "received amount starts unselected and toggles")
    try rejects("stock on missing product") { try store.addStockEvent(productID: "missing", kind: "add", quantity: 5) }
    try store.addStockEvent(productID: "p2", kind: "add", quantity: 1)
    try check(!StockMath.soldOut(Product(id: "x", name: "x", price: 1), displayed: -3) && StockMath.soldOut(Product(id: "x", name: "x", price: 1, stopAtZero: true), displayed: 0)
              && !StockMath.soldOut(Product(id: "x", name: "x", price: 1, stopAtZero: true), displayed: nil) && StockMath.label(-3) == "在庫 −3", "stop at zero only")
    let zeroStop = String(decoding: try JSONEncoder().encode(ProductUpload(Product(id: "z", name: "z", price: 1, stopAtZero: true))), as: UTF8.self)
    try check(zeroStop.contains("\"stop_at_zero\":true") && zeroStop.contains("\"track_stock\":true"), "products payload")
    try check(try JSONDecoder().decode(CloudProduct.self, from: Data(#"{"id":"p","name":"x","price":1,"active":true,"version":1,"stock":-2}"#.utf8)).stop_at_zero == false, "stop_at_zero defaults false")
    try store.addStockEvent(productID: "p1", kind: "set", quantity: 20)
    let events = try store.pendingStockEvents()
    try store.acknowledgeStock(events.map(\.id), products: [CloudProduct(id: "p1", name: "絹豆腐", price: 550, active: true, version: 4, stock: 20, seq: 3)])
    try check(store.pendingStockEventCount() == 0 && store.displayedStock()["p1"] == 20, "stock acknowledged")

    let drawer = try SQLiteStore(path: ":memory:")
    let open = try drawer.openSession(float: ["1000": 5, "100": 10])
    try rejects("second open session") { _ = try drawer.openSession(float: [:]) }
    _ = try drawer.checkout(id: "o2", lines: [tofu], received: 1000, customer: Customer(age: .student, gender: .male))
    let pendingOpen = try drawer.pendingSessions()
    let closed = try drawer.closeSession(id: open.id, counted: ["1000": 7])
    try check(closed.expectedTotal == 7000 && closed.countedTotal == 7000 && closed.orderCount == 1, "drawer close")
    try drawer.acknowledgeSessions(pendingOpen, accepted: [open.id])
    try check(drawer.pendingSessions().count == 1, "close after read stays pending")
    try drawer.acknowledgeSessions(drawer.pendingSessions(), accepted: [open.id])
    try check(drawer.pendingSessions().isEmpty && drawer.currentSession() == nil, "session synced")

    let remote = Sale(id: "remote", createdAt: "2026-11-21T01:00:00Z", total: 500, received: 1000, change: 500, cancelledAt: nil, cancellationReason: nil,
                      lines: [Line(productID: "p9", name: "他", price: 500, quantity: 1)], deviceID: "other", customerAge: "child", customerGender: "male")
    let page = FeedPage(after: 0, next: 2, has_more: false, products: [CloudProduct(id: "p9", name: "他", price: 500, active: false, version: 1, stock: nil, seq: 1)],
                        orders: [FeedOrder(order: CloudOrder(sale: remote, revision: 1), seq: 2)])
    try rejects("wrong feed cursor") { _ = try store.applyFeed(FeedPage(after: 1, next: 2, has_more: false, products: [], orders: page.orders)) }
    let fed = try store.applyFeed(page)
    try check(fed.products == 1 && fed.orders == 1 && store.feedAfter() == 2 && store.products().first { $0.id == "p9" }?.active == false, "feed apply")
    let mine = try store.pendingSales()
    try check(store.applyFeed(FeedPage(after: 2, next: 3, has_more: false, products: [], orders: [FeedOrder(order: mine[0], seq: 3)])).conflicts == 0, "own order echo")
    try check(store.sales().first { $0.id == "remote" }?.cancelledHere == false, "feed order not cancelled here")
    _ = try store.checkout(id: "c1", lines: [tofu], received: 1000)
    try store.markConflicts(["c1"])
    try check(store.pendingSales().isEmpty && store.conflictCount() == 1, "conflict persisted out of auto send")
    try store.releaseConflicts()
    try check(store.pendingSales().map(\.id) == ["c1"], "manual release")

    let file = FileManager.default.temporaryDirectory.appendingPathComponent("tofu-v2-\(UUID()).sqlite").path
    defer { try? FileManager.default.removeItem(atPath: file) }
    var db: OpaquePointer?
    try check(sqlite3_open(file, &db) == SQLITE_OK, "open v2 fixture")
    try check(sqlite3_exec(db, """
        CREATE TABLE products(id TEXT PRIMARY KEY,name TEXT NOT NULL,price INTEGER NOT NULL);
        CREATE TABLE orders(id TEXT PRIMARY KEY,created_at TEXT NOT NULL,total INTEGER NOT NULL,received INTEGER NOT NULL,change_yen INTEGER NOT NULL,cancelled_at TEXT,cancellation_reason TEXT,revision INTEGER NOT NULL DEFAULT 1,synced_revision INTEGER NOT NULL DEFAULT 0,sync_error TEXT);
        CREATE TABLE order_lines(order_id TEXT NOT NULL,line_no INTEGER NOT NULL,product_id TEXT NOT NULL,name TEXT NOT NULL,price INTEGER NOT NULL,quantity INTEGER NOT NULL,PRIMARY KEY(order_id,line_no));
        CREATE TABLE sync_metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);
        INSERT INTO products VALUES('p','豆腐',500);
        INSERT INTO orders VALUES('o','2026-11-20T00:00:00Z',500,1000,500,NULL,NULL,1,1,NULL);
        INSERT INTO order_lines VALUES('o',1,'p','豆腐',500,1);
        PRAGMA user_version=2;
        """, nil, nil, nil) == SQLITE_OK, "v2 fixture")
    sqlite3_close(db)
    let migrated = try SQLiteStore(path: file)
    try check(migrated.products().first?.dirty == true && migrated.sales().count == 1 && migrated.pendingCount() == 0 && !migrated.deviceID.isEmpty, "v2 to v3 migration")
    try check(SQLiteStore(path: file).deviceID == migrated.deviceID, "device id stable")
    var v3: OpaquePointer?
    try check(sqlite3_open(file, &v3) == SQLITE_OK, "open for v3 fixture")
    try check(sqlite3_exec(v3, "ALTER TABLE orders DROP COLUMN customer_group; ALTER TABLE orders DROP COLUMN ticket_no; PRAGMA user_version=3", nil, nil, nil) == SQLITE_OK, "downgrade to v3")
    sqlite3_close(v3)
    let fromV3 = try SQLiteStore(path: file)
    try check(fromV3.sales().count == 1 && fromV3.checkout(id: "after-v4", lines: [tofu], received: 1000, customer: Customer(age: nil, gender: nil, group: .solo)).customerGroup == "solo", "v3 to v4 keeps data")
}
