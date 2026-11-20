import Foundation

public struct Catalog: Decodable, Identifiable {
    public let id: String
    public let product_count: Int
    public let received_at: String
}
public struct CatalogResponse: Decodable {
    public let schema_version: Int
    public let catalogs: [Catalog]
    public let next: String?
    public func validate() throws {
        guard schema_version == 1, catalogs.count <= 20,
              catalogs.allSatisfy({ $0.id.count == 64 && $0.id.allSatisfy { "0123456789abcdef".contains($0) } && (0...1000).contains($0.product_count) && validCloudDate($0.received_at) }) else { throw POSFailure.invalid("不正なバックアップ一覧です") }
    }
}
func validCloudDate(_ value: String) -> Bool {
    guard value.hasSuffix("Z") else { return false }
    let f = ISO8601DateFormatter()
    if f.date(from: value) != nil { return true }
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: value) != nil
}
public struct RestoreResult {
    public let products: Int
    public let orders: Int
    public let cancellations: Int
    public let conflicts: Int
    public func message(next: String?) -> String {
        "商品\(products)件・会計\(orders)件・取消\(cancellations)件を復元。競合は累計\(conflicts)件は端末の内容を保持。" + (next == nil ? "売上の復元が完了しました" : "続きがあります。「売上の続きを復元」を押してください")
    }
}
public struct RestorePage: Decodable {
    public let schema_version: Int
    public let catalog_id: String?
    public let after: String
    public let next: String?
    public let products: [Product]
    public let orders: [CloudOrder]
    public func validate() throws {
        guard schema_version == 1, products.count <= 1000, Set(products.map(\.id)).count == products.count,
              products.allSatisfy({ !$0.id.isEmpty && $0.id.utf16.count <= 128 && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (0...Money.maximum).contains($0.price) }),
              orders.count <= 50, Set(orders.map(\.id)).count == orders.count else { throw POSFailure.invalid("不正な復元応答です") }
        var previous = after
        for order in orders {
            guard order.id > previous else { throw POSFailure.invalid("不正な復元順序です") }
            _ = try order.validatedSale(); previous = order.id
        }
        guard orders.isEmpty ? next == nil : next == orders.last?.id else { throw POSFailure.invalid("不正な復元カーソルです") }
    }
}
extension CloudOrder {
    public func validatedSale() throws -> Sale {
        let details = lines.map { Line(productID: $0.product_id, name: $0.name, price: $0.price, quantity: $0.quantity) }
        guard !id.isEmpty, id.utf16.count <= 128, validCloudDate(created_at),
              try Money.total(details) == total, received >= total, received <= Money.maximum,
              change_yen == received - total,
              details.allSatisfy({ !$0.productID.isEmpty && $0.productID.utf16.count <= 128 }),
              revision == (cancelled_at == nil ? 1 : 2) else { throw POSFailure.invalid("不正な復元会計です") }
        if let cancelled_at {
            guard validCloudDate(cancelled_at), let cancellation_reason, !cancellation_reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw POSFailure.invalid("不正な取消データです") }
        } else if cancellation_reason != nil { throw POSFailure.invalid("不正な取消データです") }
        guard device_id.map({ (1...64).contains($0.unicodeScalars.count) }) ?? true,
              customer_age.map({ CustomerAge(rawValue: $0) != nil }) ?? true,
              customer_gender.map({ CustomerGender(rawValue: $0) != nil }) ?? true else { throw POSFailure.invalid("不正な会計の端末・客層です") }
        return Sale(id: id, createdAt: created_at, total: total, received: received, change: change_yen,
                    cancelledAt: cancelled_at, cancellationReason: cancellation_reason, lines: details,
                    deviceID: device_id, customerAge: customer_age, customerGender: customer_gender)
    }
}
