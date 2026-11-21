import Foundation

public enum POSFailure: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

public struct Product: Identifiable, Equatable, Codable {
    public let id: String
    public let name: String
    public let price: Int64
    public var active = true
    /// Stock is always tracked and may go negative; only these products stop selling at zero.
    public var stopAtZero = false
    /// SHA-256 (lowercase hex) of the product photo in product-images/, nil = no photo.
    public var imageHash: String?
    public var version = 0
    public var cloudStock: Int64?
    public var dirty = true
    // Catalog backups (/v1/catalogs, /v1/restore) keep the 0.3.0 shape and hash.
    private enum CodingKeys: String, CodingKey { case id, name, price }
    public init(id: String = UUID().uuidString, name: String, price: Int64, active: Bool = true, stopAtZero: Bool = false, imageHash: String? = nil) {
        self.id = id; self.name = name; self.price = price; self.active = active; self.stopAtZero = stopAtZero; self.imageHash = imageHash
    }
}

public enum CustomerAge: String, CaseIterable, Identifiable {
    case child, student, adult, senior
    public var id: String { rawValue }
    public var label: String { ["child": "子ども", "student": "学生", "adult": "大人", "senior": "シニア"][rawValue]! }
}
public enum CustomerGender: String, CaseIterable, Identifiable {
    case male, female, other
    public var id: String { rawValue }
    public var label: String { ["male": "男性", "female": "女性", "other": "その他"][rawValue]! }
}
/// Segment chosen at checkout. Optional per axis; an unselected axis is sent as absent (null).
public enum CustomerGroup: String, CaseIterable, Identifiable {
    case solo, friends, family, couple, group
    public var id: String { rawValue }
    public var label: String { ["solo": "一人", "friends": "友人", "family": "家族", "couple": "カップル", "group": "グループ"][rawValue]! }
}
public enum CustomerRelation: String, CaseIterable, Identifiable {
    case acquaintance, relative, member, tofu_fan, general
    public var id: String { rawValue }
    public var label: String { ["acquaintance": "知り合い", "relative": "親族", "member": "メンバー", "tofu_fan": "豆腐狂", "general": "一般人"][rawValue]! }
}
public struct Customer: Equatable {
    public let age: CustomerAge?
    public let gender: CustomerGender?
    public let group: CustomerGroup?
    public let relation: CustomerRelation?
    public init(age: CustomerAge?, gender: CustomerGender?, group: CustomerGroup? = nil, relation: CustomerRelation? = nil) {
        self.age = age; self.gender = gender; self.group = group; self.relation = relation
    }
    public var isEmpty: Bool { age == nil && gender == nil && group == nil && relation == nil }
    /// "大人・女性・家族・知り合い"; unselected axes are left out.
    public static func text(age: String?, gender: String?, group: String?, relation: String? = nil) -> String {
        let parts = [age.flatMap(CustomerAge.init(rawValue:))?.label, gender.flatMap(CustomerGender.init(rawValue:))?.label,
                     group.flatMap(CustomerGroup.init(rawValue:))?.label, relation.flatMap(CustomerRelation.init(rawValue:))?.label].compactMap { $0 }
        return parts.isEmpty ? "未選択" : parts.joined(separator: "・")
    }
}

public struct Line: Identifiable, Equatable {
    public var id: String { productID }
    public let productID: String
    public let name: String
    public let price: Int64
    public var quantity: Int
    public init(productID: String, name: String, price: Int64, quantity: Int) {
        self.productID = productID; self.name = name; self.price = price; self.quantity = quantity
    }
}

public struct Sale: Identifiable {
    public let id: String
    public let createdAt: String
    public let total: Int64
    public let received: Int64
    public let change: Int64
    public let cancelledAt: String?
    public let cancellationReason: String?
    public let lines: [Line]
    public var deviceID: String? = nil
    public var customerAge: String? = nil
    public var customerGender: String? = nil
    public var customerGroup: String? = nil
    public var customerRelation: String? = nil
    /// Per-device daily ticket ("12" or "A-12"), issued in the checkout transaction.
    public var ticketNo: String? = nil
    /// Local only: the cancellation was recorded on this device (drawer cash went out here).
    public var cancelledHere = false
}

public enum Money {
    public static let maximum: Int64 = 1_000_000_000
    public static func parse(_ text: String) -> Int64? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int64(text), value <= maximum else { return nil }
        return value
    }
    public static func total(_ lines: [Line]) throws -> Int64 {
        guard !lines.isEmpty else { throw POSFailure.invalid("商品を選択してください") }
        guard Set(lines.map(\.productID)).count == lines.count else { throw POSFailure.invalid("商品が重複しています") }
        var result: Int64 = 0
        for line in lines {
            guard (1...999).contains(line.quantity), (0...maximum).contains(line.price),
                  !line.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw POSFailure.invalid("商品・数量・金額を確認してください")
            }
            let amount = line.price * Int64(line.quantity)
            guard amount <= maximum - result else { throw POSFailure.invalid("会計金額が上限を超えています") }
            result += amount
        }
        return result
    }
}

public enum SalesCSV {
    /// `ticket` appends a ticket_no column. Off by default so the shared golden CSV (shared/golden-sales.csv,
    /// also checked by Android) stays byte-identical until it is updated on both platforms.
    public static func make(_ sales: [Sale], ticket: Bool = false) -> String {
        let header = "order_id,created_at_utc,status,cancelled_at_utc,cancellation_reason,order_total_yen,received_yen,change_yen,line_no,product_id,product_name,quantity,unit_price_yen,line_total_yen,net_line_sales_yen" + (ticket ? ",ticket_no" : "")
        var rows = [header]
        for sale in sales {
            for (index, line) in sale.lines.enumerated() {
                let amount = line.price * Int64(line.quantity)
                // Order totals appear only on the first line to avoid accidental double counting.
                let fields = [sale.id, sale.createdAt, sale.cancelledAt == nil ? "paid" : "cancelled",
                              sale.cancelledAt ?? "", sale.cancellationReason ?? "",
                              index == 0 ? String(sale.total) : "", index == 0 ? String(sale.received) : "",
                              index == 0 ? String(sale.change) : "", String(index + 1), line.productID,
                              line.name, String(line.quantity), String(line.price), String(amount),
                              sale.cancelledAt == nil ? String(amount) : "0"] + (ticket ? [index == 0 ? sale.ticketNo ?? "" : ""] : [])
                rows.append(fields.map(cell).joined(separator: ","))
            }
        }
        return "\u{FEFF}" + rows.joined(separator: "\r\n") + "\r\n"
    }
    private static func cell(_ value: String) -> String {
        let first = value.drop(while: { $0.isWhitespace }).first
        let safe = first.map { "=+-@".contains($0) } == true || value.first == "\t" || value.first == "\r"
            ? "'" + value : value
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
