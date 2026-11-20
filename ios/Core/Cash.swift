import Foundation

public enum Yen {
    public static func format(_ value: Int64) -> String {
        let digits = String(value.magnitude)
        var out = ""
        for (index, character) in digits.enumerated() {
            if index > 0 && (digits.count - index) % 3 == 0 { out.append(",") }
            out.append(character)
        }
        return (value < 0 ? "-" : "") + out
    }
}

public enum Cash {
    public static let denominations: [Int64] = [10000, 5000, 2000, 1000, 500, 100, 50, 10, 5, 1]
    public static func label(_ denomination: Int64) -> String {
        Yen.format(denomination) + (denomination >= 1000 ? "円札" : "円玉")
    }
    /// Greedy from the largest denomination. 2,000-yen notes are rarely stocked, so change never uses them.
    public static func change(_ amount: Int64) -> [(denomination: Int64, count: Int64)] {
        var rest = max(0, amount)
        var result: [(denomination: Int64, count: Int64)] = []
        for denomination in denominations where denomination != 2000 {
            let count = rest / denomination
            if count > 0 { result.append((denomination, count)); rest -= count * denomination }
        }
        return result
    }
    public static func changeText(_ amount: Int64) -> String {
        let parts = change(amount).map { "\(label($0.denomination))×\($0.count)" }
        return parts.isEmpty ? "なし" : parts.joined(separator: "・")
    }
    /// Counts are keyed by the denomination string ("10000" … "1"); each count is 0…9999.
    public static func total(_ counts: [String: Int]) throws -> Int64 {
        let allowed = Set(denominations.map(String.init))
        var result: Int64 = 0
        for (key, count) in counts {
            guard allowed.contains(key), (0...9999).contains(count) else { throw POSFailure.invalid("金種と枚数（0〜9999）を確認してください") }
            result += Int64(key)! * Int64(count)
        }
        return result
    }
    public static func clean(_ counts: [String: Int]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: denominations.map { (String($0), counts[String($0)] ?? 0) })
    }
}

func cloudDate(_ value: String) -> Date? {
    let f = ISO8601DateFormatter()
    if let date = f.date(from: value) { return date }
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: value)
}

public struct DrawerSummary: Equatable {
    public let salesTotal: Int64
    public let cancelTotal: Int64
    public let orderCount: Int
    public let expected: Int64
    /// "age/gender" → paid orders in the session; legacy orders without a segment are not counted.
    public let segments: [String: Int]
    /// customer_group → paid orders in the session.
    public var groups: [String: Int] = [:]
}

public enum DrawerMath {
    /// Cash view of one drawer: orders with this device's device_id created in [openedAt, closedAt) brought
    /// their total in; cancellations recorded on this device (cancelledHere) in the same window paid it out.
    public static func summary(floatTotal: Int64, sales: [Sale], deviceID: String, openedAt: String, closedAt: String?) -> DrawerSummary {
        guard let start = cloudDate(openedAt) else { return DrawerSummary(salesTotal: 0, cancelTotal: 0, orderCount: 0, expected: floatTotal, segments: [:]) }
        let end = closedAt.flatMap(cloudDate)
        func inside(_ value: String?) -> Bool {
            guard let value, let date = cloudDate(value) else { return false }
            return date >= start && (end.map { date < $0 } ?? true)
        }
        var salesTotal: Int64 = 0, cancelTotal: Int64 = 0, count = 0
        var segments: [String: Int] = [:], groups: [String: Int] = [:]
        for sale in sales {
            if sale.deviceID == deviceID && inside(sale.createdAt) {
                salesTotal += sale.total; count += 1
                if sale.cancelledAt == nil, let age = sale.customerAge, let gender = sale.customerGender { segments["\(age)/\(gender)", default: 0] += 1 }
                if sale.cancelledAt == nil, let group = sale.customerGroup { groups[group, default: 0] += 1 }
            }
            if sale.cancelledHere && inside(sale.cancelledAt) { cancelTotal += sale.total }
        }
        return DrawerSummary(salesTotal: salesTotal, cancelTotal: cancelTotal, orderCount: count, expected: floatTotal + salesTotal - cancelTotal, segments: segments, groups: groups)
    }
}

public enum StockMath {
    /// Shown stock = cloud value minus this device's not-yet-sent, not-cancelled sales. nil = not fetched yet
    /// (shown without stock and still sellable, never treated as 0).
    public static func displayed(_ product: Product, pending: [String: Int64]) -> Int64? {
        guard let stock = product.cloudStock else { return nil }
        return stock - pending[product.id, default: 0]
    }
    /// Only stop-at-zero products are sold out; others keep selling into negative stock.
    public static func soldOut(_ product: Product, displayed: Int64?) -> Bool { product.stopAtZero && (displayed ?? 1) <= 0 }
    public static func label(_ value: Int64) -> String { "在庫 " + (value < 0 ? "−" + Yen.format(-value) : Yen.format(value)) }
    public static func pendingQuantities(_ sales: [(sale: Sale, unsynced: Bool)]) -> [String: Int64] {
        var result: [String: Int64] = [:]
        for (sale, unsynced) in sales where unsynced && sale.cancelledAt == nil {
            for line in sale.lines { result[line.productID, default: 0] += Int64(line.quantity) }
        }
        return result
    }
}

/// Single-product register: fixed cash buttons, limits and the post-checkout notice.
public enum QuickSale {
    public static let presets: [Int64] = [1000, 2000, 5000, 10000]
    public static let undoReason = "確定直後の取消"
    /// Upper bound for the quantity: the displayed stock only for stop-at-zero products, else 999.
    public static func maxQuantity(_ product: Product, displayed: Int64?) -> Int {
        guard product.stopAtZero, let displayed else { return 999 }
        return Int(min(999, max(0, displayed)))
    }
    public static func savedText(_ sale: Sale) -> String {
        let count = sale.lines.reduce(0) { $0 + $1.quantity }
        return "¥\(Yen.format(sale.total))（\(count)本）を保存しました・お釣り ¥\(Yen.format(sale.change))"
    }
    public static func changeNote(_ amount: Int64) -> String { amount == 0 ? "お釣りなし" : Cash.changeText(amount) }
}

/// Ticket numbers: optional device prefix (1–2 uppercase letters) + that device's daily sequence in JST.
public enum Ticket {
    public static func validPrefix(_ value: String) -> Bool { value.utf8.count <= 2 && value.utf8.allSatisfy { (65...90).contains($0) } }
    public static func format(prefix: String, seq: Int) -> String { prefix.isEmpty ? String(seq) : "\(prefix)-\(seq)" }
    /// 1…9999, wrapping back to 1 so the number always fits the payload format.
    public static func next(_ previous: Int) -> Int { previous >= 9999 ? 1 : previous + 1 }
    public static func day(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    /// Payload rule: [A-Z]{0,2}-?[0-9]{1,4}, 1–8 characters.
    public static func valid(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...8).contains(bytes.count) else { return false }
        var i = 0
        while i < bytes.count, i < 2, (65...90).contains(bytes[i]) { i += 1 }
        if i < bytes.count, bytes[i] == 45 { i += 1 }
        let digits = bytes[i...]
        return (1...4).contains(digits.count) && digits.allSatisfy { (48...57).contains($0) }
    }
}
