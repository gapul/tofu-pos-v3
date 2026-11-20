import SwiftUI
import UniformTypeIdentifiers
import Security
#if canImport(UIKit)
import UIKit
#endif

private struct SyncConnection: Codable { let url: String; let token: String }
/// One Keychain item per environment (production keeps the original account "connection").
private enum ConnectionKeychain {
    private static func query(_ env: AppEnvironment) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.gapul.tofupos.v3.sync", kSecAttrAccount as String: env.keychainAccount]
    }
    static func load(_ env: AppEnvironment) throws -> SyncConnection? {
        var q = query(env); q[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw POSFailure.invalid("接続設定を読み込めません。端末のロックを解除してください") }
        return try JSONDecoder().decode(SyncConnection.self, from: data)
    }
    /// Saved settings win; otherwise the git-ignored Config/sync-default(-test).json bundled at build time, if any.
    static func current(_ env: AppEnvironment) throws -> SyncConnection? {
        if let saved = try load(env) { return saved }
        guard let url = Bundle.main.url(forResource: env.bundledConnection, withExtension: "json"),
              let data = try? Data(contentsOf: url), data.count <= 4096 else { return nil }
        return try? JSONDecoder().decode(SyncConnection.self, from: data)
    }
    static func save(_ value: SyncConnection, _ env: AppEnvironment) throws {
        let data = try JSONEncoder().encode(value)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query(env) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(env); q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw POSFailure.invalid("接続設定を安全に保存できません") }
        } else if status != errSecSuccess { throw POSFailure.invalid("接続設定を安全に保存できません") }
    }
}
private final class NoSyncRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor
final class CloudSyncController: ObservableObject {
    @Published var isSyncing = false
    @Published var pending = 0
    @Published var held = 0
    @Published var serverURL = ""
    @Published var message = "未設定です"
    @Published var configured = false
    @Published var nextAllowedAt = Date.distantPast
    @Published var catalogs: [Catalog] = []
    @Published var catalogNext: String?
    @Published var canContinueRestore = false
    @Published var lastFeedAt: String?
    @Published var conflicts = 0
    @Published var failed = false
    @Published var rejectedImages = 0
    @Published var lastSyncAt: String?
    var deviceID: String { store.deviceID }
    var ticketPrefix: String { (try? store.ticketPrefix()) ?? "" }
    func setTicketPrefix(_ value: String) throws { try store.setTicketPrefix(value.trimmingCharacters(in: .whitespaces)); objectWillChange.send() }
    @Published var rejected = (products: 0, stock: 0, sessions: 0)
    let deviceLabel: String
    /// Called after a sync cycle or restore changed local products/orders, so the UI reloads once.
    var didChange: (() -> Void)?
    /// Online-first: automatic cycles (after sales and edits, on activation, every 60s for the feed,
    /// after a retryable failure) run only while the scene is active. One cycle at a time; the persisted
    /// backoff decides the timing.
    var active = false { didSet { if active && !stopped { requestAutoSync() } else { autoTask?.cancel(); autoTask = nil } } }
    /// Set when the environment is switched away: this controller never starts another cycle.
    private var stopped = false
    func shutdown() { stopped = true; active = false }
    let environment: AppEnvironment
    /// Asks the model to switch environments (confirmed in the settings screen, refused while syncing).
    var onSwitchEnvironment: ((AppEnvironment) -> Void)?
    private var autoTask: Task<Void, Never>?
    private var again = false
    /// After 401/403 every automatic trigger stops (persisted) until settings are saved or a manual run.
    private var authBlocked = false { didSet { try? store.setMetadata("auth_blocked", authBlocked ? "1" : nil) } }
    private let store: SQLiteStore
    let images: ProductImages?
    init(store: SQLiteStore, images: ProductImages?, environment: AppEnvironment) {
        self.store = store; self.images = images; self.environment = environment
        #if targetEnvironment(macCatalyst)
        // UIDevice.name is generic on the Mac; the host name ("Gapul-MacBook.local") identifies the machine.
        let host = ProcessInfo.processInfo.hostName
        let name = (host.hasSuffix(".local") ? String(host.dropLast(6)) : host).trimmingCharacters(in: .whitespacesAndNewlines)
        #elseif canImport(UIKit)
        let name = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        let name = Host.current().localizedName ?? ""
        #endif
        // Limits count Unicode scalars (code points) on every platform.
        deviceLabel = String(String.UnicodeScalarView((name.isEmpty ? "iOS" : name).unicodeScalars.prefix(64)))
        authBlocked = ((try? store.metadata("auth_blocked")) ?? nil) != nil
        do {
            if let connection = try ConnectionKeychain.current(environment) { serverURL = connection.url; configured = true; message = "接続済み" }
            nextAllowedAt = Date(timeIntervalSince1970: try store.syncGate().next)
            try refreshCount()
        } catch { message = error.localizedDescription }
    }
    func refreshCount() throws {
        pending = try store.pendingCount(); held = try store.heldSyncCount(); canContinueRestore = !(try store.restoreCursor().after).isEmpty
        lastFeedAt = try store.lastFeedAt(); conflicts = try store.conflictCount(); rejected = try store.rejectedCounts()
        lastSyncAt = try store.metadata("sync_at"); rejectedImages = try store.rejectedImageCount()
    }
    func configure(url: String, token: String) throws {
        guard !isSyncing else { throw POSFailure.invalid("同期完了後に設定してください") }
        let endpoint = try SyncPayload.endpoint(url)
        let old = try ConnectionKeychain.current(environment)
        let token = token.isEmpty ? old?.token ?? "" : token
        guard (32...256).contains(token.utf8.count), token.utf8.allSatisfy({ (33...126).contains($0) }) else { throw POSFailure.invalid("端末用トークンを入力してください") }
        try store.bindSyncTarget(endpoint.absoluteString)
        try ConnectionKeychain.save(SyncConnection(url: url.trimmingCharacters(in: .whitespacesAndNewlines), token: token), environment)
        serverURL = url; configured = true; message = "接続設定を保存しました"; authBlocked = false
        requestAutoSync()
    }
    func requestAutoSync() {
        guard configured, active, !stopped, !authBlocked else { return }
        if isSyncing { again = true; return }
        autoTask?.cancel(); autoTask = nil
        Task { await run(manual: false) }
    }
    private func finished(retryAt: Double?) {
        if again { again = false; requestAutoSync(); return }
        guard active, configured, !stopped, !authBlocked else { return }
        // Without pending work the next cycle runs in 60s to pull other devices' sales and stock.
        let delay = max(1, (retryAt ?? Date().timeIntervalSince1970 + 60) - Date().timeIntervalSince1970)
        autoTask?.cancel()
        autoTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.requestAutoSync()
        }
    }
    func importConnection(_ file: URL) throws {
        let allowed = file.startAccessingSecurityScopedResource()
        defer { if allowed { file.stopAccessingSecurityScopedResource() } }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 4096 else { throw POSFailure.invalid("設定ファイルが大きすぎます") }
        let connection = try JSONDecoder().decode(SyncConnection.self, from: Data(contentsOf: file))
        try configure(url: connection.url, token: connection.token)
    }
    func backupProducts() async {
        do {
            let products = try store.products()
            guard products.count <= 1000 else { throw POSFailure.invalid("商品バックアップは最大1000件です") }
            struct Body: Encodable { let schema_version = 1; let products: [Product] }
            let data = try JSONEncoder().encode(Body(products: products))
            let _: Bool? = await backupRequest(path: "/v1/catalogs", body: data) { data in
                struct Receipt: Decodable { let schema_version: Int; let id: String; let product_count: Int }
                let receipt = try JSONDecoder().decode(Receipt.self, from: data)
                guard receipt.schema_version == 1, receipt.id.count == 64, receipt.id.allSatisfy({ "0123456789abcdef".contains($0) }), receipt.product_count == products.count else { throw POSFailure.invalid("不正なバックアップ応答です") }
                self.message = "商品\(products.count)件をバックアップしました"
                return true
            }
        } catch { message = error.localizedDescription }
    }
    func listBackups(before: String? = nil) async -> Bool {
        var parts = URLComponents(); parts.queryItems = before.map { [URLQueryItem(name: "before",value: $0)] }
        let result: Bool? = await backupRequest(path: "/v1/catalogs" + (parts.string ?? "")) { data in
            let response = try JSONDecoder().decode(CatalogResponse.self, from: data); try response.validate()
            self.catalogs = before == nil ? response.catalogs : self.catalogs + response.catalogs
            self.catalogNext = response.next; return true
        }
        return result == true
    }
    func restore(catalog: String?, continuation: Bool) async {
        do {
            let cursor = try store.restoreCursor()
            let after = continuation ? cursor.after : ""
            let selected = continuation ? cursor.catalog : catalog
            guard !continuation || !after.isEmpty else { throw POSFailure.invalid("復元の続きはありません") }
            var components = URLComponents()
            components.queryItems = [URLQueryItem(name: "after", value: after)] + (selected.map { [URLQueryItem(name: "catalog_id", value: $0)] } ?? [])
            let _: Bool? = await backupRequest(path: "/v1/restore" + (components.string ?? "")) { data in
                let page = try JSONDecoder().decode(RestorePage.self, from: data)
                guard page.after == after, page.catalog_id == selected else { throw POSFailure.invalid("不正な復元応答です") }
                let result = try self.store.restore(page)
                self.message = result.message(next: page.next); try self.refreshCount(); self.didChange?()
                return true
            }
        } catch { message = error.localizedDescription }
    }
    // Every action makes exactly one bounded request and shares upload's persistent backoff.
    private func backupRequest<T>(path: String, body: Data? = nil, apply: (Data) throws -> T) async -> T? {
        guard !isSyncing else { return nil }
        isSyncing = true; defer { isSyncing = false; finished(retryAt: nil) }
        var failures = 0; var reserved = false; var retryAfter: String?
        do {
            guard let connection = try ConnectionKeychain.current(environment) else { throw POSFailure.invalid("先に同期設定をしてください") }
            let gate = try store.syncGate(); failures = gate.failures
            guard Date().timeIntervalSince1970 >= gate.next else { throw POSFailure.invalid("待機中です。少し待ってから実行してください") }
            let endpoint = try SyncPayload.endpoint(connection.url); try store.bindSyncTarget(endpoint.absoluteString)
            guard body == nil || body!.count <= 256 * 1024 else { throw POSFailure.invalid("商品バックアップが256KiBを超えています") }
            guard let url = URL(string: path, relativeTo: endpoint)?.absoluteURL else { throw POSFailure.invalid("不正な接続先です") }
            try store.setSyncGate(next: Date().timeIntervalSince1970 + 30, failures: failures); reserved = true
            var request = URLRequest(url: url); request.httpMethod = body == nil ? "GET" : "POST"; request.httpBody = body
            request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("TofuPOS/0.4.0 (iOS)", forHTTPHeaderField: "User-Agent")
            let config = URLSessionConfiguration.ephemeral; config.waitsForConnectivity = false
            config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 25
            let session = URLSession(configuration: config, delegate: NoSyncRedirect(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (data,response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw POSFailure.invalid("接続先から応答がありません") }
            retryAfter = http.value(forHTTPHeaderField: "Retry-After")
            if http.statusCode == 401 || http.statusCode == 403 { retryAfter = "300"; authBlocked = true; throw POSFailure.invalid("同期設定のトークンを確認してください") }
            guard http.statusCode == 200, data.count <= 512 * 1024 + 4096 else { throw POSFailure.invalid("通信できませんでした（HTTP \(http.statusCode)）。端末データは保持しています") }
            let result = try apply(data)
            try store.setSyncGate(next: 0, failures: 0); nextAllowedAt = .distantPast
            return result
        } catch {
            if reserved {
                let next = Date().timeIntervalSince1970 + SyncPayload.delay(failures: failures + 1, retryAfter: retryAfter) * Double.random(in: 1...1.2)
                do { try store.setSyncGate(next: next, failures: min(10, failures+1)); nextAllowedAt = Date(timeIntervalSince1970: next) }
                catch { message = "待機状態を保存できません。\(error.localizedDescription)"; return nil }
            }
            message = error.localizedDescription; return nil
        }
    }
    func run() async { await run(manual: true) }
    func run(manual: Bool) async {
        guard !isSyncing else { again = true; return }
        if manual {
            authBlocked = false
            // A manual send releases conflicting orders for exactly one more attempt.
            do { try store.releaseConflicts() } catch { message = error.localizedDescription }
        }
        let retryAt = await cycle(manual: manual)
        finished(retryAt: retryAt)
    }
    private struct RequestFailure: LocalizedError {
        let message: String; let retryAfter: String?; let unauthorized: Bool; var status = 0
        var errorDescription: String? { message }
    }
    private func send(_ session: URLSession, path: String, connection: SyncConnection, body: Data?, limit: Int, contentType: String = "application/json") async throws -> Data {
        var request = URLRequest(url: try SyncPayload.url(path, base: connection.url))
        request.httpMethod = body == nil ? "GET" : "POST"; request.httpBody = body
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("TofuPOS/0.4.0 (iOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw POSFailure.invalid("同期先から応答がありません") }
        let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
        if http.statusCode == 401 || http.statusCode == 403 { throw RequestFailure(message: "同期設定のトークンを確認してください", retryAfter: "300", unauthorized: true) }
        guard http.statusCode == 200, data.count <= limit else { throw RequestFailure(message: "同期できませんでした（HTTP \(http.statusCode)）。未同期データは端末に残っています", retryAfter: retryAfter, unauthorized: false, status: http.statusCode) }
        return data
    }
    /// One bounded cycle: ④ orders (50) → photos (5) → ① dirty products → ② stock events → ③ drawer sessions →
    /// ⑤ feed (up to 5 pages). Orders go first so a stock count (set) is computed after this device's sales.
    /// HTTP 400 in ①②③ holds the sent items (sync_error='rejected') and moves on; any other failure stops
    /// the cycle and stores the backoff in the shared gate.
    /// Returns when the next automatic cycle should run, or nil for the regular 60s cadence (or no
    /// automatic retry at all after 401/403).
    private func cycle(manual: Bool) async -> Double? {
        func isRejected(_ error: Error) -> Bool { (error as? RequestFailure)?.status == 400 }
        isSyncing = true
        var changed = false
        defer { isSyncing = false; if changed { didChange?() } }
        var previousFailures = 0
        var reserved = false
        do {
            guard let connection = try ConnectionKeychain.current(environment) else { throw POSFailure.invalid("先に同期設定をしてください") }
            let gate = try store.syncGate(); previousFailures = gate.failures
            guard Date().timeIntervalSince1970 >= gate.next else {
                message = "待機中です。\(Date(timeIntervalSince1970: gate.next).formatted(date: .omitted, time: .standard)) 以降に再送します"; return gate.next
            }
            let endpoint = try SyncPayload.endpoint(connection.url)
            try store.bindSyncTarget(endpoint.absoluteString)
            // Persist before starting I/O: restarting the app cannot create a retry storm.
            try store.setSyncGate(next: Date().timeIntervalSince1970 + 30, failures: gate.failures)
            reserved = true
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = false
            configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 25
            let session = URLSession(configuration: configuration, delegate: NoSyncRedirect(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let decoder = JSONDecoder()
            var notes: [String] = []
            // ④ orders
            var orderConflicts = 0
            let candidates = try store.pendingSales()
            if !candidates.isEmpty {
                let batch = try SyncPayload.make(candidates)
                try store.holdSync(batch.oversized)
                if !batch.orders.isEmpty {
                    let result = try decoder.decode(SyncResponse.self, from: try await send(session, path: "/v1/sync", connection: connection, body: batch.data, limit: 64 * 1024))
                    try result.validate(for: batch.orders)
                    try store.acknowledge(result.accepted)
                    try store.markConflicts(result.conflicts.map(\.id)); orderConflicts = result.conflicts.count
                    notes.append(result.conflicts.isEmpty ? "会計\(result.accepted.count)件を同期" : "会計\(result.accepted.count)件を同期。競合\(result.conflicts.count)件は自動送信から外し、端末に保持しています")
                }
                if !batch.oversized.isEmpty { notes.append("サイズ超過の会計を保留しました") }
            }
            // photos: sent before products, which may reference them (the server rejects unknown hashes)
            if let images {
                for hash in try store.pendingImages() {
                    guard let data = images.data(hash) else { try store.rejectImage(hash); continue }
                    do {
                        struct Receipt: Decodable { let schema_version: Int; let hash: String }
                        let receipt = try decoder.decode(Receipt.self, from: try await send(session, path: "/v1/images", connection: connection, body: data, limit: 4096, contentType: "image/jpeg"))
                        guard receipt.schema_version == 1, receipt.hash == hash else { throw POSFailure.invalid("不正な写真の応答です") }
                        try store.markImageUploaded(hash)
                    } catch where isRejected(error) { try store.rejectImage(hash) }
                }
            }
            // ① products
            let dirty = try store.dirtyProducts()
            if !dirty.isEmpty {
                let batch = try CloudBatch<ProductUpload>.make(key: "products", dirty.map(ProductUpload.init), limit: 100)
                do {
                    let response = try decoder.decode(ProductResponse.self, from: try await send(session, path: "/v1/products", connection: connection, body: batch.data, limit: 1024 * 1024))
                    try response.validate(for: batch.items)
                    let overridden = try store.applyProductResults(response.results, sent: batch.items); changed = true
                    notes.append("商品\(batch.items.count)件を送信")
                    notes += overridden.map { "商品\($0)は他の端末の変更を優先しました" }
                } catch where isRejected(error) { try store.rejectProducts(batch.items.map(\.id)) }
            }
            // ② stock events
            let events = try store.pendingStockEvents()
            if !events.isEmpty {
                let batch = try CloudBatch<StockEvent>.make(key: "events", events, limit: 100)
                do {
                    let response = try decoder.decode(StockResponse.self, from: try await send(session, path: "/v1/stock", connection: connection, body: batch.data, limit: 1024 * 1024))
                    try response.validate(for: batch.items)
                    try store.acknowledgeStock(response.accepted + response.rejected.map(\.id), products: response.products); changed = true
                    notes.append("在庫\(response.accepted.count)件を送信" + (response.rejected.isEmpty ? "" : "（\(response.rejected.count)件は商品が無いため反映されませんでした）"))
                } catch where isRejected(error) { try store.rejectStockEvents(batch.items.map(\.id)) }
            }
            // ③ drawer sessions
            let drawers = try store.pendingSessions()
            if !drawers.isEmpty {
                let uploads = try drawers.map { SessionUpload(session: $0, deviceID: store.deviceID, deviceLabel: deviceLabel, summary: try store.sessionSummary($0)) }
                let batch = try CloudBatch<SessionUpload>.make(key: "sessions", uploads, limit: 20)
                do {
                    let response = try decoder.decode(SessionResponse.self, from: try await send(session, path: "/v1/sessions", connection: connection, body: batch.data, limit: 64 * 1024))
                    try response.validate(for: batch.items)
                    try store.acknowledgeSessions(batch.items.map(\.session), accepted: response.accepted + response.rejected.map(\.id))
                    notes.append("レジ記録\(response.accepted.count)件を送信")
                    if !response.rejected.isEmpty { notes.append("レジセッション\(response.rejected.count)件はクラウドの締め済み内容を優先しました") }
                } catch where isRejected(error) { try store.rejectSessions(batch.items.map(\.session.id)) }
            }
            // ⑤ feed
            var hasMore = true, pages = 0, fedOrders = 0, fedProducts = 0
            while hasMore && pages < 5 {
                let after = try store.feedAfter()
                let page = try decoder.decode(FeedPage.self, from: try await send(session, path: "/v1/feed?after=\(after)", connection: connection, body: nil, limit: 1024 * 1024))
                let applied = try store.applyFeed(page)
                fedOrders += applied.orders + applied.cancellations; fedProducts += applied.products
                if applied.orders + applied.cancellations + applied.products > 0 { changed = true }
                hasMore = page.has_more; pages += 1
            }
            // Missing photos of products are fetched best-effort (10 per cycle); a failure waits for the next cycle.
            if let images {
                var fetched = 0
                for hash in try store.productImageHashes().sorted() where !images.exists(hash) {
                    guard fetched < 10 else { break }
                    fetched += 1
                    guard let data = try? await send(session, path: "/v1/images/\(hash)", connection: connection, body: nil, limit: ProductImages.maxBytes),
                          (try? images.save(data, expected: hash)) != nil else { break }
                    try store.markImageUploaded(hash); changed = true
                }
            }
            if fedOrders + fedProducts > 0 { notes.append("取り込み: 会計\(fedOrders)件・商品\(fedProducts)件") }
            let next = Date().timeIntervalSince1970 + (orderConflicts == 0 ? 5 : 300)
            try store.setSyncGate(next: next, failures: 0); nextAllowedAt = Date(timeIntervalSince1970: next)
            try store.setMetadata("sync_at", ISO8601DateFormatter().string(from: Date())); failed = false
            try refreshCount()
            message = notes.isEmpty ? (held > 0 ? "\(held)件はサイズ超過のため保留中です。CSVで取り出せます" : "すべて同期済みです") : notes.joined(separator: "。") + "。残り\(pending)件"
            guard orderConflicts == 0 else { return nil }
            let more = try hasMore || dirty.count >= 100 || events.count >= 100 || !store.dirtyProducts().isEmpty || !store.pendingSales().isEmpty
            return more ? next : nil
        } catch {
            let failure = error as? RequestFailure
            failed = true
            if reserved {
                let failures = min(10, previousFailures + 1)
                let seconds = SyncPayload.delay(failures: failures, retryAfter: failure?.retryAfter)
                let next = Date().timeIntervalSince1970 + seconds * Double.random(in: 1...1.2)
                do { try store.setSyncGate(next: next, failures: failures); nextAllowedAt = Date(timeIntervalSince1970: next) }
                catch { message = "同期の待機状態を保存できません。\(error.localizedDescription)"; return nil }
                try? refreshCount()
                message = error.localizedDescription
                if failure?.unauthorized == true { authBlocked = true; return nil }
                return next
            }
            message = error.localizedDescription
            return nil
        }
    }
}

struct CloudSyncView: View {
    @ObservedObject var controller: CloudSyncController
    @State private var url = ""
    @State private var token = ""
    @State private var importing = false
    @State private var failure: String?
    @State private var choosingCatalogs = false
    @State private var chosen = false
    @State private var selectedCatalog: Catalog?
    @State private var continuing = false
    @State private var confirmRestore = false
    @State private var switchTarget: AppEnvironment?
    @State private var prefix = ""
    @FocusState private var focused: Bool
    private func catalogDate(_ value: String) -> String {
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        guard let date = parser.date(from: value) ?? ISO8601DateFormatter().date(from: value) else { return value }
        let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.timeZone = TimeZone(identifier: "Asia/Tokyo"); f.dateFormat = "yyyy/M/d HH:mm:ss 'JST'"
        return f.string(from: date)
    }
    var body: some View {
        Form {
            Section("環境") {
                Picker("環境", selection: Binding(get: { controller.environment }, set: { if $0 != controller.environment { switchTarget = $0 } })) {
                    ForEach(AppEnvironment.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented).disabled(controller.isSyncing)
            }
            Section("この端末") {
                LabeledContent("端末名", value: controller.deviceLabel)
                HStack {
                    Text("整理番号の接頭辞")
                    Spacer()
                    TextField("なし", text: $prefix).textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .multilineTextAlignment(.trailing).frame(width: 60).focused($focused)
                    IconButton("接頭辞を保存", .symbol("checkmark")) {
                        focused = false
                        do { try controller.setTicketPrefix(prefix.uppercased()); prefix = controller.ticketPrefix; failure = nil }
                        catch { failure = error.localizedDescription }
                    }.disabled(prefix.uppercased() == controller.ticketPrefix)
                }
                LabeledContent("端末ID") { Text(controller.deviceID).font(.caption.monospaced()).textSelection(.enabled) }
            }
            Section("バックアップ・復元") {
                HStack(spacing: 16) {
                    IconButton("商品をバックアップ", .symbol("icloud.and.arrow.up")) { focused = false; Task { await controller.backupProducts() } }
                    IconButton("クラウドから復元", .symbol("icloud.and.arrow.down")) { focused = false; Task { if await controller.listBackups() { choosingCatalogs = true } } }
                    if controller.canContinueRestore { IconButton("売上の続きを復元", .symbol("arrow.down.to.line.circle")) { continuing = true; confirmRestore = true } }
                    Spacer()
                }
            }.disabled(controller.isSyncing || !controller.configured)
            Section("接続設定") {
                TextField("https://…workers.dev", text: $url).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).focused($focused)
                SecureField("端末用トークン（空欄なら変更なし）", text: $token).focused($focused)
                HStack(spacing: 16) {
                    IconButton("接続設定を保存", .symbol("checkmark")) {
                        do { focused = false; try controller.configure(url: url, token: token); token = ""; failure = nil }
                        catch { failure = error.localizedDescription }
                    }
                    IconButton("設定ファイルを読み込む", .symbol("square.and.arrow.down")) { focused = false; importing = true }
                    Spacer()
                }
                if let failure { Text(failure).foregroundStyle(.red) }
            }.disabled(controller.isSyncing)
        }.navigationTitle("詳細設定")
            .tofuSurface()
            .sheet(isPresented: $choosingCatalogs, onDismiss: { if chosen { chosen = false; confirmRestore = true } }) {
                NavigationStack {
                    List {
                        Button("売上のみ復元") { selectedCatalog = nil; continuing = false; chosen = true; choosingCatalogs = false }
                        ForEach(controller.catalogs) { catalog in
                            Button("\(catalogDate(catalog.received_at)) · 商品\(catalog.product_count)件") { selectedCatalog = catalog; continuing = false; chosen = true; choosingCatalogs = false }
                        }
                        if let before = controller.catalogNext {
                            IconButton("さらに表示", .symbol("ellipsis.circle")) { Task { _ = await controller.listBackups(before: before) } }
                        }
                    }.disabled(controller.isSyncing).navigationTitle("バックアップを選択")
                        .toolbar { ToolbarItem(placement: .cancellationAction) { IconButton("戻る", .symbol("xmark")) { choosingCatalogs = false } } }
                }
            }
            .alert("クラウドから復元", isPresented: $confirmRestore) {
                Button("復元する") { Task { await controller.restore(catalog: selectedCatalog?.id, continuation: continuing) } }
                Button("戻る", role: .cancel) { }
            } message: { Text("端末のデータは消さずに取り込みます。") }
            .alert("環境の切り替え", isPresented: Binding(get: { switchTarget != nil }, set: { if !$0 { switchTarget = nil } })) {
                Button(switchTarget == .test ? "テストに切り替える" : "本番に戻す", role: .destructive) {
                    if let target = switchTarget, !controller.isSyncing { controller.onSwitchEnvironment?(target) }
                    switchTarget = nil
                }
                Button("戻る", role: .cancel) { switchTarget = nil }
            } message: { Text(switchTarget?.switchPrompt ?? "") }
            .onAppear { url = controller.serverURL; prefix = controller.ticketPrefix }
            .onDisappear { focused = false }
            .scrollDismissesKeyboard(.interactively)
            .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); IconButton("キーボードを閉じる", .symbol("keyboard.chevron.compact.down")) { focused = false } } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                do { try controller.importConnection(result.get()); url = controller.serverURL; token = ""; failure = nil }
                catch { failure = error.localizedDescription }
            }
    }
}
