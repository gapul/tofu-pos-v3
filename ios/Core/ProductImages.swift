import Foundation
import CryptoKit

/// Photo files under Application Support/product-images/<sha256>.jpg. Content-addressed, so a file
/// never changes once written; the DB stores only the hash.
public struct ProductImages {
    public static let maxSide = 800
    public static let maxBytes = 512 * 1024
    public let directory: URL
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    public static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func validHash(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    public static func isJPEG(_ data: Data) -> Bool { data.count >= 3 && data.prefix(3).elementsEqual([0xFF, 0xD8, 0xFF]) }
    /// Size that fits within maxSide on the long edge, keeping the aspect ratio; never enlarges.
    public static func fitted(width: Int, height: Int, maxSide: Int = maxSide) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (0, 0) }
        let long = max(width, height)
        guard long > maxSide else { return (width, height) }
        let scale = Double(maxSide) / Double(long)
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }
    public func url(_ hash: String) -> URL { directory.appendingPathComponent(hash + ".jpg") }
    public func exists(_ hash: String) -> Bool { ProductImages.validHash(hash) && FileManager.default.fileExists(atPath: url(hash).path) }
    public func data(_ hash: String) -> Data? { ProductImages.validHash(hash) ? try? Data(contentsOf: url(hash)) : nil }
    /// Stores a JPEG and returns its hash. `expected` (a downloaded image) must match the content.
    @discardableResult
    public func save(_ jpeg: Data, expected: String? = nil) throws -> String {
        guard ProductImages.isJPEG(jpeg), jpeg.count <= ProductImages.maxBytes else { throw POSFailure.invalid("写真はJPEG・512KiB以内にしてください") }
        let hash = ProductImages.sha256(jpeg)
        if let expected, expected != hash { throw POSFailure.invalid("写真の内容が一致しません") }
        if !exists(hash) { try jpeg.write(to: url(hash), options: .atomic) }
        return hash
    }
    /// Deletes photo files no longer referenced. Returns how many were removed.
    @discardableResult
    public func cleanup(keep: Set<String>) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var removed = 0
        for name in files where name.hasSuffix(".jpg") && !keep.contains(String(name.dropLast(4))) {
            if (try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))) != nil { removed += 1 }
        }
        return removed
    }
}
