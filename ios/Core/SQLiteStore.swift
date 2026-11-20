import Foundation
#if canImport(CSQLite)
import CSQLite
#else
import SQLite3
#endif

// Confine each instance to one serial executor. The app owns it on MainActor.
public final class SQLiteStore {
    private var db: OpaquePointer?
    public private(set) var deviceID = ""
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String) throws {
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "DBを開けません"
            sqlite3_close(db); db = nil
            throw POSFailure.invalid(message)
        }
        do {
            try exec("PRAGMA foreign_keys=ON")
            try exec("PRAGMA synchronous=FULL")
            let version = try query("PRAGMA user_version").first?.first ?? "0"
            guard ["0", "1", "2", "3", "4"].contains(version) else { throw POSFailure.invalid("未対応のDBバージョンです") }
            if version == "0" {
                try transaction {
                    try exec("CREATE TABLE products(id TEXT PRIMARY KEY,name TEXT NOT NULL,price INTEGER NOT NULL CHECK(price>=0 AND price<=1000000000))")
                    try exec("CREATE TABLE orders(id TEXT PRIMARY KEY,created_at TEXT NOT NULL,total INTEGER NOT NULL,received INTEGER NOT NULL,change_yen INTEGER NOT NULL,cancelled_at TEXT,cancellation_reason TEXT)")
                    try exec("CREATE TABLE order_lines(order_id TEXT NOT NULL REFERENCES orders(id),line_no INTEGER NOT NULL,product_id TEXT NOT NULL,name TEXT NOT NULL,price INTEGER NOT NULL,quantity INTEGER NOT NULL CHECK(quantity BETWEEN 1 AND 999),PRIMARY KEY(order_id,line_no))")
                    try exec("PRAGMA user_version=1")
                }
            }
            if version == "0" || version == "1" {
                try transaction {
                    try exec("ALTER TABLE orders ADD COLUMN revision INTEGER NOT NULL DEFAULT 1")
                    try exec("ALTER TABLE orders ADD COLUMN synced_revision INTEGER NOT NULL DEFAULT 0")
                    try exec("ALTER TABLE orders ADD COLUMN sync_error TEXT")
                    try exec("UPDATE orders SET revision=2 WHERE cancelled_at IS NOT NULL")
                    try exec("CREATE INDEX pending_sync ON orders(id) WHERE synced_revision<revision")
                    try exec("CREATE TABLE sync_metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)")
                    try exec("PRAGMA user_version=2")
                }
            }
            if !["3", "4"].contains(version) {
                try transaction {
                    for column in ["device_id", "customer_age", "customer_gender"] { try exec("ALTER TABLE orders ADD COLUMN \(column) TEXT") }
                    // 1 only when the cancellation was recorded on this device (never sent; restore/feed keep 0).
                    try exec("ALTER TABLE orders ADD COLUMN cancelled_here INTEGER NOT NULL DEFAULT 0")
                    // Existing products have never been sent: dirty 1, version 0.
                    try exec("ALTER TABLE products ADD COLUMN active INTEGER NOT NULL DEFAULT 1")
                    // track_stock stays for compatibility and is always 1: every product tracks stock.
                    try exec("ALTER TABLE products ADD COLUMN track_stock INTEGER NOT NULL DEFAULT 1")
                    try exec("ALTER TABLE products ADD COLUMN stop_at_zero INTEGER NOT NULL DEFAULT 0")
                    try exec("ALTER TABLE products ADD COLUMN image_hash TEXT")
                    // uploaded: 0 = to send, 1 = on the server, -1 = rejected (400), held and not resent.
                    try exec("CREATE TABLE local_images(hash TEXT PRIMARY KEY,uploaded INTEGER NOT NULL DEFAULT 0,created_at TEXT NOT NULL)")
                    try exec("ALTER TABLE products ADD COLUMN version INTEGER NOT NULL DEFAULT 0")
                    try exec("ALTER TABLE products ADD COLUMN cloud_stock INTEGER")
                    try exec("ALTER TABLE products ADD COLUMN dirty INTEGER NOT NULL DEFAULT 1")
                    // sync_error='rejected': the server answered 400 for this item; automatic sends skip it.
                    try exec("ALTER TABLE products ADD COLUMN sync_error TEXT")
                    try exec("CREATE TABLE stock_events(id TEXT PRIMARY KEY,product_id TEXT NOT NULL,kind TEXT NOT NULL,quantity INTEGER NOT NULL,reason TEXT,created_at TEXT NOT NULL,synced INTEGER NOT NULL DEFAULT 0,sync_error TEXT)")
                    try exec("CREATE TABLE drawer_sessions(id TEXT PRIMARY KEY,opened_at TEXT NOT NULL,closed_at TEXT,float_json TEXT NOT NULL,float_total INTEGER NOT NULL,counted_json TEXT,counted_total INTEGER,expected_total INTEGER,sales_total INTEGER,cancel_total INTEGER,order_count INTEGER,synced INTEGER NOT NULL DEFAULT 0,sync_error TEXT)")
                    try exec("INSERT OR IGNORE INTO sync_metadata VALUES('device_id',?)", [UUID().uuidString.lowercased()])
                    try exec("PRAGMA user_version=3")
                }
            }
            // v4 (v3 is in use on devices): customer group and ticket number. Columns only; no data rewritten.
            if version != "4" {
                try transaction {
                    try exec("ALTER TABLE orders ADD COLUMN customer_group TEXT")
                    try exec("ALTER TABLE orders ADD COLUMN ticket_no TEXT")
                    try exec("PRAGMA user_version=4")
                }
            }
            if let id = try query("SELECT value FROM sync_metadata WHERE key='device_id'").first?.first, !id.isEmpty { deviceID = id }
            else { deviceID = UUID().uuidString.lowercased(); try exec("INSERT OR REPLACE INTO sync_metadata VALUES('device_id',?)", [deviceID]) }
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }

    public func products() throws -> [Product] {
        try productRows("SELECT id,name,price,active,stop_at_zero,version,cloud_stock,dirty,image_hash FROM products ORDER BY rowid")
    }
    private func productRows(_ sql: String, _ values: [String?] = []) throws -> [Product] {
        try query(sql, values).map {
            var p = Product(id: $0[0], name: $0[1], price: Int64($0[2])!, active: $0[3] == "1", stopAtZero: $0[4] == "1")
            p.version = Int($0[5]) ?? 0; p.cloudStock = Int64($0[6]); p.dirty = $0[7] == "1"; p.imageHash = $0[8].isEmpty ? nil : $0[8]
            return p
        }
    }
    /// Local edits are kept as dirty until the next sync cycle sends them to /v1/products.
    public func saveProduct(_ product: Product) throws {
        let name = product.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.unicodeScalars.count <= 100, (0...Money.maximum).contains(product.price) else {
            throw POSFailure.invalid("商品名（100文字以内）と価格を確認してください")
        }
        try exec("""
            INSERT INTO products(id,name,price,active,stop_at_zero,image_hash) VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
            sync_error=CASE WHEN \(Self.sameProduct) THEN sync_error ELSE NULL END,
            dirty=CASE WHEN \(Self.sameProduct) THEN dirty ELSE 1 END,
            name=excluded.name,price=excluded.price,active=excluded.active,stop_at_zero=excluded.stop_at_zero,image_hash=excluded.image_hash
            """, [product.id, name, String(product.price), flag(product.active), flag(product.stopAtZero), product.imageHash])
    }
    public func dirtyProducts() throws -> [Product] {
        try productRows("SELECT id,name,price,active,stop_at_zero,version,cloud_stock,dirty,image_hash FROM products WHERE dirty=1 AND sync_error IS NULL AND NOT EXISTS(SELECT 1 FROM local_images i WHERE i.hash=products.image_hash AND i.uploaded<>1) ORDER BY rowid LIMIT 100")
    }
    /// HTTP 400 for a whole step: hold exactly the sent items so the remaining steps still run.
    public func rejectProducts(_ ids: [String]) throws { try mark("products", ids, where: "dirty=1") }
    public func rejectStockEvents(_ ids: [String]) throws { try mark("stock_events", ids, where: "synced=0") }
    public func rejectSessions(_ ids: [String]) throws { try mark("drawer_sessions", ids, where: "synced=0") }
    private func mark(_ table: String, _ ids: [String], where condition: String) throws {
        try transaction { for id in ids { try exec("UPDATE \(table) SET sync_error='rejected' WHERE id=? AND \(condition)", [id]) } }
    }
    // MARK: product images (files live in product-images/<hash>.jpg; the DB only tracks upload state)
    private static let sameProduct = "name=excluded.name AND price=excluded.price AND active=excluded.active AND stop_at_zero=excluded.stop_at_zero AND image_hash IS excluded.image_hash"
    /// A photo picked on this device; one already known (downloaded or sent) keeps its state.
    public func registerImage(_ hash: String) throws {
        guard ProductImages.validHash(hash) else { throw POSFailure.invalid("不正な写真です") }
        try exec("INSERT OR IGNORE INTO local_images(hash,created_at) VALUES(?,?)", [hash, now()])
    }
    /// Downloaded from (or confirmed by) the server.
    public func markImageUploaded(_ hash: String) throws {
        try exec("INSERT INTO local_images(hash,uploaded,created_at) VALUES(?,1,?) ON CONFLICT(hash) DO UPDATE SET uploaded=1", [hash, now()])
    }
    public func rejectImage(_ hash: String) throws { try exec("UPDATE local_images SET uploaded=-1 WHERE hash=? AND uploaded=0", [hash]) }
    public func pendingImages() throws -> [String] { try query("SELECT hash FROM local_images WHERE uploaded=0 ORDER BY created_at,hash LIMIT 5").map { $0[0] } }
    public func rejectedImageCount() throws -> Int { Int(try query("SELECT COUNT(*) FROM local_images WHERE uploaded=-1")[0][0])! }
    public func productImageHashes() throws -> Set<String> { Set(try query("SELECT DISTINCT image_hash FROM products WHERE image_hash IS NOT NULL").map { $0[0] }) }
    /// Files to keep on cleanup: photos of products plus photos still waiting to be sent.
    public func imageHashesInUse() throws -> Set<String> {
        try productImageHashes().union(try query("SELECT hash FROM local_images WHERE uploaded=0").map { $0[0] })
    }
    public func rejectedCounts() throws -> (products: Int, stock: Int, sessions: Int) {
        let row = try query("SELECT (SELECT COUNT(*) FROM products WHERE dirty=1 AND sync_error IS NOT NULL),(SELECT COUNT(*) FROM stock_events WHERE synced=0 AND sync_error IS NOT NULL),(SELECT COUNT(*) FROM drawer_sessions WHERE synced=0 AND sync_error IS NOT NULL)")[0]
        return (Int(row[0])!, Int(row[1])!, Int(row[2])!)
    }
    /// Applies /v1/products results. The server value wins ("applied" and "conflict"), unless the row was
    /// edited again during the request: then only the base version and stock are taken and it stays dirty.
    /// Returns the names of products where another device's change won.
    public func applyProductResults(_ results: [ProductResponse.Result], sent: [ProductUpload]) throws -> [String] {
        let byID = Dictionary(uniqueKeysWithValues: sent.map { ($0.id, $0) })
        return try transaction {
            var overridden: [String] = []
            for result in results {
                let server = result.product
                guard let request = byID[result.id], let local = try productRows("SELECT id,name,price,active,stop_at_zero,version,cloud_stock,dirty,image_hash FROM products WHERE id=?", [result.id]).first else { continue }
                if local.name == request.name && local.price == request.price && local.active == request.active && local.stopAtZero == request.stop_at_zero && local.imageHash == request.image_hash {
                    try exec("UPDATE products SET name=?,price=?,active=?,stop_at_zero=?,image_hash=?,version=?,cloud_stock=?,dirty=0 WHERE id=?",
                             [server.name, String(server.price), flag(server.active), flag(server.stop_at_zero), server.image_hash, String(server.version), server.stock.map(String.init), server.id])
                    if result.status == "conflict" { overridden.append(server.name) }
                } else {
                    try exec("UPDATE products SET version=?,cloud_stock=? WHERE id=?", [String(server.version), server.stock.map(String.init), server.id])
                }
            }
            return overridden
        }
    }
    /// Stock shown on the device: cloud stock minus this device's unsent, uncancelled sales.
    public func displayedStock() throws -> [String: Int64] {
        let pending = Dictionary(uniqueKeysWithValues: try query("SELECT l.product_id,SUM(l.quantity) FROM order_lines l JOIN orders o ON o.id=l.order_id WHERE o.synced_revision<o.revision AND o.cancelled_at IS NULL GROUP BY l.product_id").map { ($0[0], Int64($0[1]) ?? 0) })
        var result: [String: Int64] = [:]
        for product in try products() { if let value = StockMath.displayed(product, pending: pending) { result[product.id] = value } }
        return result
    }
    public func addStockEvent(productID: String, kind: String, quantity: Int64, reason: String? = nil) throws {
        let clean = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard kind == "add" ? (-1_000_000...1_000_000).contains(quantity) && quantity != 0 : kind == "set" && (0...1_000_000).contains(quantity),
              (clean?.unicodeScalars.count ?? 0) <= 200 else { throw POSFailure.invalid("在庫数（0〜1,000,000）を確認してください") }
        try transaction {
            guard try query("SELECT 1 FROM products WHERE id=?", [productID]).first != nil else { throw POSFailure.invalid("商品がありません") }
            try exec("INSERT INTO stock_events(id,product_id,kind,quantity,reason,created_at) VALUES(?,?,?,?,?,?)",
                     [UUID().uuidString.lowercased(), productID, kind, String(quantity), clean?.isEmpty == false ? clean : nil, now()])
        }
    }
    public func pendingStockEvents() throws -> [StockEvent] {
        try query("SELECT id,product_id,kind,quantity,reason,created_at FROM stock_events WHERE synced=0 AND sync_error IS NULL ORDER BY created_at,rowid LIMIT 100").map {
            StockEvent(id: $0[0], product_id: $0[1], kind: $0[2], quantity: Int64($0[3])!, reason: $0[4].isEmpty ? nil : $0[4], created_at: $0[5])
        }
    }
    public func pendingStockEventCount() throws -> Int { Int(try query("SELECT COUNT(*) FROM stock_events WHERE synced=0 AND sync_error IS NULL")[0][0])! }
    public func acknowledgeStock(_ ids: [String], products: [CloudProduct]) throws {
        try transaction {
            for id in ids { try exec("UPDATE stock_events SET synced=1 WHERE id=?", [id]) }
            for p in products { try exec("UPDATE products SET cloud_stock=? WHERE id=?", [p.stock.map(String.init), p.id]) }
        }
    }
    public func checkout(id: String, lines: [Line], received: Int64, customer: Customer? = nil) throws -> Sale {
        try transaction {
            if let existing = try sale(id: id) {
                guard existing.lines == lines, existing.received == received, existing.customerAge == customer?.age?.rawValue,
                      existing.customerGender == customer?.gender?.rawValue, existing.customerGroup == customer?.group?.rawValue else { throw POSFailure.invalid("同じ会計IDで内容が異なります") }
                return existing  // an idempotent replay keeps its ticket and takes no new number
            }
            let total = try Money.total(lines)
            guard !id.isEmpty, received >= total, received <= Money.maximum else { throw POSFailure.invalid("預り金が不足しているか上限を超えています") }
            let ticket = try nextTicket()
            try exec("INSERT INTO orders(id,created_at,total,received,change_yen,device_id,customer_age,customer_gender,customer_group,ticket_no) VALUES(?,?,?,?,?,?,?,?,?,?)",
                     [id, now(), String(total), String(received), String(received - total), deviceID, customer?.age?.rawValue, customer?.gender?.rawValue, customer?.group?.rawValue, ticket])
            for (index, line) in lines.enumerated() {
                try exec("INSERT INTO order_lines VALUES(?,?,?,?,?,?)",
                         [id, String(index + 1), line.productID, line.name, String(line.price), String(line.quantity)])
            }
            guard let result = try sale(id: id) else { throw POSFailure.invalid("会計を確認できません") }
            return result
        }
    }
    public func cancel(id: String, reason: String) throws {
        let clean = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.unicodeScalars.count <= 200 else { throw POSFailure.invalid("取消理由（200文字以内）を入力してください") }
        try transaction {
            guard let current = try sale(id: id), current.cancelledAt == nil else { throw POSFailure.invalid("取消済み、または注文がありません") }
            try exec("UPDATE orders SET cancelled_at=?,cancellation_reason=?,revision=2,cancelled_here=1 WHERE id=? AND cancelled_at IS NULL",
                     [now(), clean, id])
        }
    }
    public func sales() throws -> [Sale] {
        let orders = try query("SELECT \(Self.orderColumns) FROM orders ORDER BY created_at DESC,rowid DESC")
        let details = try query("SELECT order_id,product_id,name,price,quantity FROM order_lines ORDER BY order_id,line_no")
        let grouped = Dictionary(grouping: details, by: { $0[0] })
        return orders.map { row in makeSale(row, details: grouped[row[0]] ?? []) }
    }
    public func pendingCount() throws -> Int {
        Int(try query("SELECT COUNT(*) FROM orders WHERE synced_revision<revision")[0][0])!
    }
    public func pendingSales() throws -> [CloudOrder] {
        let rows = try query("SELECT \(Self.orderColumns),revision FROM orders WHERE synced_revision<revision AND sync_error IS NULL ORDER BY id LIMIT 50")
        guard !rows.isEmpty else { return [] }
        let ids = rows.map { $0[0] }
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let details = try query("SELECT order_id,product_id,name,price,quantity FROM order_lines WHERE order_id IN (\(marks)) ORDER BY order_id,line_no", ids)
        let grouped = Dictionary(grouping: details, by: { $0[0] })
        return rows.map { CloudOrder(sale: makeSale($0, details: grouped[$0[0]] ?? []), revision: Int($0[13])!) }
    }
    public func acknowledge(_ receipts: [SyncReceipt]) throws {
        guard !receipts.isEmpty else { return }
        try transaction {
            for receipt in receipts {
                guard (1...2).contains(receipt.revision) else { throw POSFailure.invalid("不正な同期応答です") }
                try exec("UPDATE orders SET synced_revision=MAX(synced_revision,CAST(? AS INTEGER)) WHERE id=? AND revision>=?", [String(receipt.revision), receipt.id, String(receipt.revision)])
            }
        }
    }
    public func holdSync(_ ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try transaction {
            for id in ids { try exec("UPDATE orders SET sync_error='payload_too_large' WHERE id=?", [id]) }
        }
    }
    public func heldSyncCount() throws -> Int {
        Int(try query("SELECT COUNT(*) FROM orders WHERE synced_revision<revision AND sync_error='payload_too_large'")[0][0])!
    }
    /// Conflicting orders are persisted out of automatic sends; a manual send releases them for one retry.
    public func markConflicts(_ ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try transaction { for id in ids { try exec("UPDATE orders SET sync_error='conflict' WHERE id=? AND synced_revision<revision", [id]) } }
    }
    public func releaseConflicts() throws { try exec("UPDATE orders SET sync_error=NULL WHERE sync_error='conflict'") }
    public func conflictCount() throws -> Int {
        Int(try query("SELECT COUNT(*) FROM orders WHERE synced_revision<revision AND sync_error='conflict'")[0][0])!
    }
    public func metadata(_ key: String) throws -> String? { try query("SELECT value FROM sync_metadata WHERE key=?", [key]).first?.first }
    public func setMetadata(_ key: String, _ value: String?) throws {
        if let value { try exec("INSERT OR REPLACE INTO sync_metadata VALUES(?,?)", [key, value]) } else { try exec("DELETE FROM sync_metadata WHERE key=?", [key]) }
    }
    public func syncGate() throws -> (next: Double, failures: Int) {
        let values = Dictionary(uniqueKeysWithValues: try query("SELECT key,value FROM sync_metadata").map { ($0[0], $0[1]) })
        return (Double(values["next"] ?? "0") ?? 0, Int(values["failures"] ?? "0") ?? 0)
    }
    public func setSyncGate(next: Double, failures: Int) throws {
        try transaction {
            try exec("INSERT OR REPLACE INTO sync_metadata VALUES('next',?)", [String(next)])
            try exec("INSERT OR REPLACE INTO sync_metadata VALUES('failures',?)", [String(failures)])
        }
    }
    public func bindSyncTarget(_ target: String) throws {
        if let existing = try query("SELECT value FROM sync_metadata WHERE key='target'").first {
            guard existing[0] == target else { throw POSFailure.invalid("同期先の変更はできません。元の接続先を指定してください") }
        } else { try exec("INSERT INTO sync_metadata VALUES('target',?)", [target]) }
    }
    public func restoreCursor() throws -> (catalog: String?, after: String) {
        let values = Dictionary(uniqueKeysWithValues: try query("SELECT key,value FROM sync_metadata WHERE key IN ('restore_catalog','restore_after')").map { ($0[0],$0[1]) })
        let catalog = values["restore_catalog"] ?? ""
        return (catalog.isEmpty ? nil : catalog, values["restore_after"] ?? "")
    }
    public func restore(_ page: RestorePage) throws -> RestoreResult {
        try page.validate()
        return try transaction {
            let previous: [String:String] = page.after.isEmpty ? [:] : Dictionary(uniqueKeysWithValues: try query("SELECT key,value FROM sync_metadata WHERE key LIKE 'restore_%'").map { ($0[0],$0[1]) })
            var productsAdded = Int(previous["restore_products"] ?? "0") ?? 0
            var ordersAdded = Int(previous["restore_orders"] ?? "0") ?? 0
            var cancellations = Int(previous["restore_cancellations"] ?? "0") ?? 0
            var conflicts = Int(previous["restore_conflicts"] ?? "0") ?? 0
            for p in page.products {
                if let old = try query("SELECT name,price FROM products WHERE id=?", [p.id]).first {
                    if old[0] != p.name || Int64(old[1]) != p.price { conflicts += 1 }
                } else {
                    try exec("INSERT INTO products(id,name,price) VALUES(?,?,?)", [p.id,p.name,String(p.price)]); productsAdded += 1
                }
            }
            for row in page.orders {
                switch try merge(row) {
                case .inserted: ordersAdded += 1
                case .cancelled: cancellations += 1
                case .conflict: conflicts += 1
                case .unchanged: break
                }
            }
            try exec("INSERT OR REPLACE INTO sync_metadata VALUES('restore_catalog',?)", [page.catalog_id ?? ""])
            try exec("INSERT OR REPLACE INTO sync_metadata VALUES('restore_after',?)", [page.next ?? ""])
            try exec("INSERT OR REPLACE INTO sync_metadata VALUES('restore_conflicts',?)", [String(conflicts)])
            for (key,value) in [("restore_products",productsAdded),("restore_orders",ordersAdded),("restore_cancellations",cancellations)] {
                try exec("INSERT OR REPLACE INTO sync_metadata VALUES(?,?)", [key,String(value)])
            }
            return RestoreResult(products: productsAdded, orders: ordersAdded, cancellations: cancellations, conflicts: conflicts)
        }
    }
    enum MergeOutcome { case inserted, cancelled, conflict, unchanged }
    /// Restore and feed share these rules: a missing order is inserted as synced, a cancellation is
    /// never undone, and a different content keeps the device's version.
    private func merge(_ row: CloudOrder) throws -> MergeOutcome {
        let incoming = try row.validatedSale()
        if let old = try sale(id: row.id) {
            if old.createdAt != incoming.createdAt || old.total != incoming.total || old.received != incoming.received || old.change != incoming.change || old.lines != incoming.lines
                || old.deviceID != incoming.deviceID || old.customerAge != incoming.customerAge || old.customerGender != incoming.customerGender
                || old.customerGroup != incoming.customerGroup || old.ticketNo != incoming.ticketNo {
                return .conflict
            } else if old.cancelledAt != nil && incoming.cancelledAt != nil && (old.cancelledAt != incoming.cancelledAt || old.cancellationReason != incoming.cancellationReason) {
                return .conflict
            }
            var outcome = MergeOutcome.unchanged
            if old.cancelledAt == nil && row.revision == 2 {
                try exec("UPDATE orders SET cancelled_at=?,cancellation_reason=?,revision=2,sync_error=NULL WHERE id=?", [incoming.cancelledAt!, incoming.cancellationReason!, incoming.id]); outcome = .cancelled
            }
            try exec("UPDATE orders SET synced_revision=CAST(? AS INTEGER) WHERE id=? AND synced_revision<?", [String(row.revision),row.id,String(row.revision)])
            return outcome
        }
        try exec("INSERT INTO orders(id,created_at,total,received,change_yen,cancelled_at,cancellation_reason,revision,synced_revision,device_id,customer_age,customer_gender,customer_group,ticket_no) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                 [row.id,row.created_at,String(row.total),String(row.received),String(row.change_yen),row.cancelled_at,row.cancellation_reason,String(row.revision),String(row.revision),row.device_id,row.customer_age,row.customer_gender,row.customer_group,row.ticket_no])
        for (index,l) in incoming.lines.enumerated() {
            try exec("INSERT INTO order_lines VALUES(?,?,?,?,?,?)", [row.id,String(index+1),l.productID,l.name,String(l.price),String(l.quantity)])
        }
        return .inserted
    }
    public func feedAfter() throws -> Int { Int(try query("SELECT value FROM sync_metadata WHERE key='feed_after'").first?.first ?? "0") ?? 0 }
    public func lastFeedAt() throws -> String? { try query("SELECT value FROM sync_metadata WHERE key='feed_at'").first?.first }
    /// One page = one transaction, cursor included. Dirty local products are left for the next upload.
    public func applyFeed(_ page: FeedPage) throws -> (products: Int, orders: Int, cancellations: Int, conflicts: Int) {
        try transaction {
            try page.validate(after: try feedAfter())
            var products = 0, orders = 0, cancellations = 0, conflicts = 0
            for p in page.products {
                let values: [String?] = [p.name, String(p.price), flag(p.active), flag(p.stop_at_zero), p.image_hash, String(p.version), p.stock.map(String.init), p.id]
                if let row = try query("SELECT dirty,sync_error FROM products WHERE id=?", [p.id]).first {
                    // A held (rejected) local edit yields to the cloud master instead of staying stuck.
                    guard row[0] == "0" || !row[1].isEmpty else { continue }
                    try exec("UPDATE products SET name=?,price=?,active=?,stop_at_zero=?,image_hash=?,version=?,cloud_stock=?,dirty=0,sync_error=NULL WHERE id=?", values)
                } else {
                    try exec("INSERT INTO products(name,price,active,stop_at_zero,image_hash,version,cloud_stock,id,dirty) VALUES(?,?,?,?,?,?,?,?,0)", values)
                }
                products += 1
            }
            for row in page.orders {
                switch try merge(row.order) {
                case .inserted: orders += 1
                case .cancelled: cancellations += 1
                case .conflict: conflicts += 1
                case .unchanged: break
                }
            }
            try exec("INSERT OR REPLACE INTO sync_metadata VALUES('feed_after',?)", [String(page.next)])
            try exec("INSERT OR REPLACE INTO sync_metadata VALUES('feed_at',?)", [now()])
            return (products, orders, cancellations, conflicts)
        }
    }
    // MARK: drawer sessions (at most one open per device)
    public func currentSession() throws -> DrawerSession? { try sessions("WHERE closed_at IS NULL").first }
    public func lastClosedSession() throws -> DrawerSession? { try sessions("WHERE closed_at IS NOT NULL ORDER BY closed_at DESC LIMIT 1").first }
    public func openSession(float: [String: Int]) throws -> DrawerSession {
        let counts = Cash.clean(float); let total = try Cash.total(counts)
        return try transaction {
            guard try currentSession() == nil else { throw POSFailure.invalid("レジはすでに開いています") }
            let id = UUID().uuidString.lowercased()
            // Never overlap the previous session, whose closed_at was rounded up to the next second.
            let last = try query("SELECT MAX(closed_at) FROM drawer_sessions").first?.first ?? ""
            try exec("INSERT INTO drawer_sessions(id,opened_at,float_json,float_total) VALUES(?,?,?,?)", [id, max(now(), last), try json(counts), String(total)])
            return try sessions("WHERE id=?", [id])[0]
        }
    }
    public func sessionSummary(_ session: DrawerSession) throws -> DrawerSummary {
        DrawerMath.summary(floatTotal: session.floatTotal, sales: try sales(), deviceID: deviceID, openedAt: session.openedAt, closedAt: session.closedAt)
    }
    public func closeSession(id: String, counted: [String: Int]) throws -> DrawerSession {
        let counts = Cash.clean(counted); let total = try Cash.total(counts)
        return try transaction {
            guard let open = try sessions("WHERE id=? AND closed_at IS NULL", [id]).first else { throw POSFailure.invalid("開いているレジがありません") }
            // Timestamps have whole seconds; rounding up keeps an order from the closing second inside (created_at < closed_at).
            let closedAt = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 1).rounded(.down)))
            let summary = DrawerMath.summary(floatTotal: open.floatTotal, sales: try sales(), deviceID: deviceID, openedAt: open.openedAt, closedAt: closedAt)
            try exec("UPDATE drawer_sessions SET closed_at=?,counted_json=?,counted_total=?,expected_total=?,sales_total=?,cancel_total=?,order_count=?,synced=0,sync_error=NULL WHERE id=?",
                     [closedAt, try json(counts), String(total), String(summary.expected), String(summary.salesTotal), String(summary.cancelTotal), String(summary.orderCount), id])
            return try sessions("WHERE id=?", [id])[0]
        }
    }
    public func pendingSessions() throws -> [DrawerSession] { try sessions("WHERE synced=0 AND sync_error IS NULL ORDER BY opened_at LIMIT 20") }
    /// A session closed after it was read is sent again: only rows unchanged since then are marked.
    public func acknowledgeSessions(_ sent: [DrawerSession], accepted: [String]) throws {
        let ok = Set(accepted)
        try transaction {
            for s in sent where ok.contains(s.id) {
                try exec(s.closedAt == nil ? "UPDATE drawer_sessions SET synced=1 WHERE id=? AND closed_at IS NULL" : "UPDATE drawer_sessions SET synced=1 WHERE id=?", [s.id])
            }
        }
    }
    private func sessions(_ clause: String, _ values: [String?] = []) throws -> [DrawerSession] {
        try query("SELECT id,opened_at,closed_at,float_json,float_total,counted_json,counted_total,expected_total,sales_total,cancel_total,order_count FROM drawer_sessions \(clause)", values).map {
            DrawerSession(id: $0[0], openedAt: $0[1], closedAt: $0[2].isEmpty ? nil : $0[2], float: counts($0[3]) ?? [:], floatTotal: Int64($0[4])!,
                          counted: counts($0[5]), countedTotal: Int64($0[6]), expectedTotal: Int64($0[7]), salesTotal: Int64($0[8]),
                          cancelTotal: Int64($0[9]), orderCount: Int($0[10]))
        }
    }
    private func counts(_ text: String) -> [String: Int]? { text.isEmpty ? nil : try? JSONDecoder().decode([String: Int].self, from: Data(text.utf8)) }
    private func json(_ counts: [String: Int]) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(counts), as: UTF8.self)
    }
    private func flag(_ value: Bool) -> String { value ? "1" : "0" }
    /// Injectable for tests (ticket date rollover); everything else uses the real time.
    public var clock: () -> Date = { Date() }
    private func now() -> String { ISO8601DateFormatter().string(from: clock()) }
    // MARK: tickets (per environment because the counter lives in this DB)
    public func ticketPrefix() throws -> String { try metadata("ticket_prefix") ?? "" }
    public func setTicketPrefix(_ prefix: String) throws {
        guard Ticket.validPrefix(prefix) else { throw POSFailure.invalid("整理番号の接頭辞は英大文字1〜2文字（空欄可）です") }
        try setMetadata("ticket_prefix", prefix.isEmpty ? nil : prefix)
    }
    /// Called inside the checkout transaction: the counter restarts at 1 when the JST date changes.
    private func nextTicket() throws -> String {
        let today = Ticket.day(clock())
        let seq = try metadata("ticket_date") == today ? Ticket.next(Int(try metadata("ticket_seq") ?? "0") ?? 0) : 1
        try setMetadata("ticket_date", today); try setMetadata("ticket_seq", String(seq))
        return Ticket.format(prefix: try ticketPrefix(), seq: seq)
    }
    private static let orderColumns = "id,created_at,total,received,change_yen,cancelled_at,cancellation_reason,device_id,customer_age,customer_gender,cancelled_here,customer_group,ticket_no"
    private func sale(id: String) throws -> Sale? {
        guard let row = try query("SELECT \(Self.orderColumns) FROM orders WHERE id=?", [id]).first else { return nil }
        return makeSale(row, details: try query("SELECT order_id,product_id,name,price,quantity FROM order_lines WHERE order_id=? ORDER BY line_no", [id]))
    }
    private func makeSale(_ row: [String], details: [[String]]) -> Sale {
        Sale(id: row[0], createdAt: row[1], total: Int64(row[2])!, received: Int64(row[3])!, change: Int64(row[4])!,
             cancelledAt: row[5].isEmpty ? nil : row[5], cancellationReason: row[6].isEmpty ? nil : row[6],
             lines: details.map { Line(productID: $0[1], name: $0[2], price: Int64($0[3])!, quantity: Int($0[4])!) },
             deviceID: row[7].isEmpty ? nil : row[7], customerAge: row[8].isEmpty ? nil : row[8], customerGender: row[9].isEmpty ? nil : row[9],
             customerGroup: row[11].isEmpty ? nil : row[11], ticketNo: row[12].isEmpty ? nil : row[12], cancelledHere: row[10] == "1")
    }
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do { let result = try body(); try exec("COMMIT"); return result }
        catch { try? exec("ROLLBACK"); throw error }
    }
    private func exec(_ sql: String, _ values: [String?] = []) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
    private func query(_ sql: String, _ values: [String?] = []) throws -> [[String]] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var result: [[String]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return result }
            guard step == SQLITE_ROW else { throw failure() }
            result.append((0..<sqlite3_column_count(statement)).map {
                sqlite3_column_text(statement, $0).map { String(cString: $0) } ?? ""
            })
        }
    }
    private func prepare(_ sql: String, _ values: [String?]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement); throw failure()
        }
        for (index, value) in values.enumerated() {
            let bound = value.map { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, transient) } ?? sqlite3_bind_null(statement, Int32(index + 1))
            guard bound == SQLITE_OK else {
                sqlite3_finalize(statement); throw failure()
            }
        }
        return statement
    }
    private func failure() -> POSFailure { .invalid(String(cString: sqlite3_errmsg(db))) }
}
