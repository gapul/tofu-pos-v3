import Foundation

/// Production and test are fully separate: their own DB file (sync gate, target binding and feed cursor
/// live in it), photo folder, Keychain account and bundled default connection. Production keeps the
/// names used before environments existed, so existing data stays production.
public enum AppEnvironment: String, CaseIterable, Identifiable {
    case production, test
    public static let defaultsKey = "environment"
    public var id: String { rawValue }
    public var label: String { self == .production ? "本番" : "テスト" }
    public var databaseFile: String { self == .production ? "tofu-pos.sqlite" : "tofu-pos-test.sqlite" }
    public var imageFolder: String { self == .production ? "product-images" : "product-images-test" }
    public var keychainAccount: String { self == .production ? "connection" : "connection-test" }
    public var bundledConnection: String { self == .production ? "sync-default" : "sync-default-test" }
    public var switchPrompt: String { self == .test ? "テスト環境に切り替えます（売上は本番に入りません）。" : "本番環境に戻します。" }
    public static func stored(_ value: String?) -> AppEnvironment { value.flatMap(AppEnvironment.init(rawValue:)) ?? .production }
    /// Test only: deletes the test DB (with its journal files) and photo folder under `directory`, so the
    /// next open starts empty and pulls everything from the test cloud again. Production is refused.
    public func eraseLocalData(in directory: URL) throws {
        guard self == .test else { throw POSFailure.invalid("本番のデータは消去できません") }
        let fm = FileManager.default
        for name in [databaseFile, databaseFile + "-journal", databaseFile + "-wal", databaseFile + "-shm", imageFolder] {
            let url = directory.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        }
    }
}
