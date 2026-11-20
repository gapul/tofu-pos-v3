import Foundation

public struct CloudLine: Codable {
    public let product_id: String
    public let name: String
    public let price: Int64
    public let quantity: Int
}
public struct CloudOrder: Codable {
    public let id: String
    public let revision: Int
    public let created_at: String
    public let total: Int64
    public let received: Int64
    public let change_yen: Int64
    public let cancelled_at: String?
    public let cancellation_reason: String?
    public let lines: [CloudLine]
    // Optional since 0.4.0. Synthesized Encodable uses encodeIfPresent, so nil keys are omitted and
    // 0.3.0-era orders keep the same payload hash on the server.
    public let device_id: String?
    public let customer_age: String?
    public let customer_gender: String?
    public let customer_group: String?
    public let ticket_no: String?
    init(sale: Sale, revision: Int) {
        id = sale.id; self.revision = revision; created_at = sale.createdAt
        total = sale.total; received = sale.received; change_yen = sale.change
        cancelled_at = sale.cancelledAt; cancellation_reason = sale.cancellationReason
        lines = sale.lines.map { CloudLine(product_id: $0.productID, name: $0.name, price: $0.price, quantity: $0.quantity) }
        device_id = sale.deviceID; customer_age = sale.customerAge; customer_gender = sale.customerGender
        customer_group = sale.customerGroup; ticket_no = sale.ticketNo
    }
}
public struct SyncReceipt: Codable, Equatable {
    public let id: String
    public let revision: Int
    public init(id: String, revision: Int) { self.id = id; self.revision = revision }
}
public struct SyncResponse: Decodable {
    public struct Conflict: Decodable { public let id: String }
    public let schema_version: Int
    public let accepted: [SyncReceipt]
    public let conflicts: [Conflict]
    public func validate(for orders: [CloudOrder]) throws {
        let allowed = Set(orders.map { "\($0.id)/\($0.revision)" })
        let receipts = accepted.map { "\($0.id)/\($0.revision)" }
        guard schema_version == 1, Set(receipts).count == receipts.count,
              receipts.allSatisfy({ allowed.contains($0) }),
              Set(accepted.map(\.id)).isDisjoint(with: Set(conflicts.map(\.id))),
              Set(accepted.map(\.id) + conflicts.map(\.id)) == Set(orders.map(\.id)),
              Set(conflicts.map(\.id)).count == conflicts.count else { throw POSFailure.invalid("不正な同期応答です。データは未同期のまま保持しました") }
    }
}
public enum SyncPayload {
    private struct Batch: Encodable { let schema_version = 1; let orders: [CloudOrder] }
    public static func make(_ candidates: [CloudOrder]) throws -> (orders: [CloudOrder], data: Data, oversized: [String]) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var orders: [CloudOrder] = []; var oversized: [String] = []
        for candidate in candidates.prefix(50) {
            if try encoder.encode(Batch(orders: [candidate])).count > 256 * 1024 { oversized.append(candidate.id); continue }
            if try encoder.encode(Batch(orders: orders + [candidate])).count <= 256 * 1024 { orders.append(candidate) }
        }
        return (orders, try encoder.encode(Batch(orders: orders)), oversized)
    }
    public static func endpoint(_ base: String) throws -> URL {
        guard let c = URLComponents(string: base.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme == "https", let host = c.host, !host.isEmpty, c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil, c.port == nil || c.port == 443,
              c.path.isEmpty || c.path == "/", let url = c.url else { throw POSFailure.invalid("CloudflareのHTTPS URLを入力してください（パスなし）") }
        return url.appendingPathComponent("v1/sync")
    }
    public static func url(_ path: String, base: String) throws -> URL {
        guard let url = URL(string: path, relativeTo: try endpoint(base))?.absoluteURL else { throw POSFailure.invalid("不正な接続先です") }
        return url
    }
    public static func delay(failures: Int, retryAfter: String? = nil) -> Double {
        if let retryAfter, let seconds = Double(retryAfter), seconds.isFinite { return min(3600, max(15, seconds)) }
        return min(300, 15 * pow(2, Double(min(5, max(0, failures - 1)))))
    }
}

private struct DynamicKey: CodingKey {
    var stringValue: String; var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
public struct CloudBatch<T: Encodable>: Encodable {
    let key: String; let items: [T]
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        try c.encode(1, forKey: DynamicKey("schema_version")); try c.encode(items, forKey: DynamicKey(key))
    }
    /// Takes items in order while the request stays within `limit` items and 256KiB; the first item is always taken.
    public static func make(key: String, _ candidates: [T], limit: Int) throws -> (items: [T], data: Data) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var items: [T] = []
        for candidate in candidates.prefix(limit) {
            if !items.isEmpty, try encoder.encode(CloudBatch(key: key, items: items + [candidate])).count > 256 * 1024 { break }
            items.append(candidate)
        }
        return (items, try encoder.encode(CloudBatch(key: key, items: items)))
    }
}

public struct CloudProduct: Decodable, Equatable {
    public let id: String
    public let name: String
    public let price: Int64
    public let active: Bool
    public let stop_at_zero: Bool
    public let image_hash: String?
    public let version: Int
    public let stock: Int64?
    public let seq: Int?
    public init(id: String, name: String, price: Int64, active: Bool, stop_at_zero: Bool = false, image_hash: String? = nil, version: Int, stock: Int64?, seq: Int?) {
        self.id = id; self.name = name; self.price = price; self.active = active; self.stop_at_zero = stop_at_zero; self.image_hash = image_hash
        self.version = version; self.stock = stock; self.seq = seq
    }
    // track_stock (always true since revision 2) is ignored; stop_at_zero defaults to false.
    private enum CodingKeys: String, CodingKey { case id, name, price, active, stop_at_zero, image_hash, version, stock, seq }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); name = try c.decode(String.self, forKey: .name); price = try c.decode(Int64.self, forKey: .price)
        active = try c.decode(Bool.self, forKey: .active); stop_at_zero = try c.decodeIfPresent(Bool.self, forKey: .stop_at_zero) ?? false
        image_hash = try c.decodeIfPresent(String.self, forKey: .image_hash)
        version = try c.decode(Int.self, forKey: .version); stock = try c.decodeIfPresent(Int64.self, forKey: .stock); seq = try c.decodeIfPresent(Int.self, forKey: .seq)
    }
    public var valid: Bool {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !id.isEmpty && id.utf16.count <= 128 && !clean.isEmpty && clean.unicodeScalars.count <= 100 && (0...Money.maximum).contains(price) && version >= 1 && (image_hash.map(ProductImages.validHash) ?? true)
    }
}
public struct ProductUpload: Encodable, Equatable {
    public let id: String
    public let name: String
    public let price: Int64
    public let active: Bool
    public let track_stock = true
    public let stop_at_zero: Bool
    /// Omitted when nil; the server treats an omitted image_hash as null (no photo).
    public let image_hash: String?
    public let base_version: Int
    public init(_ p: Product) { id = p.id; name = p.name; price = p.price; active = p.active; stop_at_zero = p.stopAtZero; image_hash = p.imageHash; base_version = p.version }
}
public struct ProductResponse: Decodable {
    public struct Result: Decodable { public let id: String; public let status: String; public let product: CloudProduct }
    public let schema_version: Int
    public let results: [Result]
    public func validate(for sent: [ProductUpload]) throws {
        guard schema_version == 1, results.map(\.id).sorted() == sent.map(\.id).sorted(),
              results.allSatisfy({ ["applied", "conflict"].contains($0.status) && $0.product.id == $0.id && $0.product.valid }) else { throw POSFailure.invalid("不正な商品同期応答です") }
    }
}
public struct StockEvent: Codable, Equatable {
    public let id: String
    public let product_id: String
    public let kind: String
    public let quantity: Int64
    public let reason: String?
    public let created_at: String
}
public struct StockResponse: Decodable {
    public struct Rejected: Decodable { public let id: String; public let reason: String? }
    public let schema_version: Int
    public let accepted: [String]
    public let rejected: [Rejected]
    public let products: [CloudProduct]
    public func validate(for sent: [StockEvent]) throws {
        let ids = accepted + rejected.map(\.id)
        guard schema_version == 1, Set(ids).count == ids.count, Set(ids).isSubset(of: Set(sent.map(\.id))),
              products.allSatisfy(\.valid) else { throw POSFailure.invalid("不正な在庫同期応答です") }
    }
}
public struct DrawerSession: Equatable, Identifiable {
    public let id: String
    public let openedAt: String
    public let closedAt: String?
    public let float: [String: Int]
    public let floatTotal: Int64
    public let counted: [String: Int]?
    public let countedTotal: Int64?
    public let expectedTotal: Int64?
    public let salesTotal: Int64?
    public let cancelTotal: Int64?
    public let orderCount: Int?
}
public struct SessionUpload: Encodable {
    public let session: DrawerSession
    public let deviceID: String
    public let deviceLabel: String
    public let summary: DrawerSummary
    private enum K: String, CodingKey { case id, device_id, device_label, opened_at, closed_at, float, float_total, counted, counted_total, expected_total, sales_total, cancel_total, order_count }
    public func encode(to encoder: Encoder) throws {
        // Nullable fields are sent as explicit null, matching the API shape.
        var c = encoder.container(keyedBy: K.self)
        try c.encode(session.id, forKey: .id); try c.encode(deviceID, forKey: .device_id); try c.encode(deviceLabel, forKey: .device_label)
        try c.encode(session.openedAt, forKey: .opened_at); try c.encode(session.closedAt, forKey: .closed_at)
        try c.encode(session.float, forKey: .float); try c.encode(session.floatTotal, forKey: .float_total)
        try c.encode(session.counted, forKey: .counted); try c.encode(session.countedTotal, forKey: .counted_total)
        try c.encode(session.closedAt == nil ? nil : session.expectedTotal, forKey: .expected_total)
        try c.encode(session.salesTotal ?? summary.salesTotal, forKey: .sales_total)
        try c.encode(session.cancelTotal ?? summary.cancelTotal, forKey: .cancel_total)
        try c.encode(session.orderCount ?? summary.orderCount, forKey: .order_count)
    }
}
public struct SessionResponse: Decodable {
    public struct Rejected: Decodable { public let id: String; public let reason: String? }
    public let schema_version: Int
    public let accepted: [String]
    /// A row the cloud already holds as closed with other content; resending cannot fix it, so it counts as done.
    public let rejected: [Rejected]
    private enum CodingKeys: String, CodingKey { case schema_version, accepted, rejected }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema_version = try c.decode(Int.self, forKey: .schema_version); accepted = try c.decode([String].self, forKey: .accepted)
        rejected = try c.decodeIfPresent([Rejected].self, forKey: .rejected) ?? []
    }
    public func validate(for sent: [SessionUpload]) throws {
        let ids = accepted + rejected.map(\.id)
        guard schema_version == 1, Set(ids).count == ids.count, Set(ids).isSubset(of: Set(sent.map(\.session.id))) else { throw POSFailure.invalid("不正なレジ締め同期応答です") }
    }
}
public struct FeedOrder: Decodable {
    public let order: CloudOrder
    public let seq: Int
    private enum K: String, CodingKey { case seq }
    public init(order: CloudOrder, seq: Int) { self.order = order; self.seq = seq }
    public init(from decoder: Decoder) throws {
        order = try CloudOrder(from: decoder)
        seq = try decoder.container(keyedBy: K.self).decode(Int.self, forKey: .seq)
    }
}
public struct FeedPage: Decodable {
    public let schema_version: Int
    public let after: Int
    public let next: Int
    public let has_more: Bool
    public let products: [CloudProduct]
    public let orders: [FeedOrder]
    public init(after: Int, next: Int, has_more: Bool, products: [CloudProduct], orders: [FeedOrder]) {
        schema_version = 1; self.after = after; self.next = next; self.has_more = has_more; self.products = products; self.orders = orders
    }
    public func validate(after expected: Int) throws {
        let seqs = products.map { $0.seq ?? -1 } + orders.map(\.seq)
        guard schema_version == 1, after == expected, products.count <= 1000, orders.count <= 100,
              Set(products.map(\.id)).count == products.count, Set(orders.map(\.order.id)).count == orders.count,
              products.allSatisfy(\.valid), seqs.allSatisfy({ $0 > after && $0 <= next }),
              next == (seqs.max() ?? after), !has_more || next > after else { throw POSFailure.invalid("不正な取り込み応答です") }
        for row in orders { _ = try row.order.validatedSale() }
    }
}
