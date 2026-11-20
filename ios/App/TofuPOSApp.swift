import SwiftUI
import UniformTypeIdentifiers
import PhotosUI

@main
struct TofuPOSApp: App {
    var body: some Scene { WindowGroup { RootView() } }
}

@MainActor
final class RegisterModel: ObservableObject {
    @Published var products: [Product] = []
    @Published var sales: [Sale] = []
    @Published var stock: [String: Int64] = [:]
    @Published var session: DrawerSession?
    @Published var sessionSummary: DrawerSummary?
    @Published var lastClosed: DrawerSession?
    @Published var error: String?
    @Published var ready = false
    @Published var sync: CloudSyncController?
    @Published private(set) var environment: AppEnvironment
    private var sceneActive = false
    private var store: SQLiteStore?
    private(set) var images: ProductImages?
    var deviceID: String { store?.deviceID ?? "" }
    /// Exactly one product on sale: the register switches to the single-product screen.
    var singleProduct: Product? {
        let onSale = products.filter(\.active)
        return onSale.count == 1 ? onSale[0] : nil
    }
    init() {
        environment = AppEnvironment.stored(UserDefaults.standard.string(forKey: AppEnvironment.defaultsKey))
        open()
    }
    /// Opens the current environment's own DB, photo folder and sync controller.
    private func open() {
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let store = try SQLiteStore(path: directory.appendingPathComponent(environment.databaseFile).path)
            self.store = store
            // Photos are optional: a failure here never blocks the register.
            images = try? ProductImages(directory: directory.appendingPathComponent(environment.imageFolder, isDirectory: true))
            if let images, let keep = try? store.imageHashesInUse() { images.cleanup(keep: keep) }
            let controller = CloudSyncController(store: store, images: images, environment: environment)
            controller.didChange = { [weak self] in self?.refresh() }
            controller.onSwitchEnvironment = { [weak self] in self?.switchEnvironment(to: $0) }
            sync = controller
            try reload(); ready = true
            controller.active = sceneActive
        } catch { self.error = "保存データを開けません。アプリを削除せず確認してください。\n\(error.localizedDescription)" }
    }
    func setActive(_ active: Bool) { sceneActive = active; sync?.active = active }
    /// Stops the current controller's timers, drops screen state and reopens with the other environment.
    func switchEnvironment(to target: AppEnvironment) {
        guard target != environment else { return }
        guard sync?.isSyncing != true else { error = "同期中は切り替えできません。少し待ってからやり直してください"; return }
        sync?.shutdown(); sync = nil; store = nil; images = nil; ready = false
        products = []; sales = []; stock = [:]; session = nil; sessionSummary = nil; lastClosed = nil; error = nil
        environment = target
        UserDefaults.standard.set(target.rawValue, forKey: AppEnvironment.defaultsKey)
        open()
    }
    func reload() throws {
        guard let store else { throw POSFailure.invalid("データベースが利用できません") }
        products = try store.products(); sales = try store.sales(); stock = try store.displayedStock()
        session = try store.currentSession(); lastClosed = try store.lastClosedSession()
        sessionSummary = session.map { DrawerMath.summary(floatTotal: $0.floatTotal, sales: sales, deviceID: store.deviceID, openedAt: $0.openedAt, closedAt: nil) }
        try sync?.refreshCount()
    }
    /// `newImage`: a photo picked in the editor (stored by `storePhoto`), registered for upload with the product.
    func save(_ product: Product, newImage: String? = nil) throws {
        let store = try database()
        if let newImage { try store.registerImage(newImage) }
        try store.saveProduct(product); try reload(); sync?.requestAutoSync()
    }
    func storePhoto(_ jpeg: Data) throws -> String {
        guard let images else { throw POSFailure.invalid("写真を保存できません") }
        return try images.save(jpeg)
    }
    func adjustStock(_ productID: String, kind: String, quantity: Int64) throws {
        try database().addStockEvent(productID: productID, kind: kind, quantity: quantity); try reload(); sync?.requestAutoSync()
    }
    func openDrawer(_ counts: [String: Int]) throws { _ = try database().openSession(float: counts); try reload(); sync?.requestAutoSync() }
    func closeDrawer(_ id: String, counted: [String: Int]) throws { _ = try database().closeSession(id: id, counted: counted); try reload(); sync?.requestAutoSync() }
    func checkout(id: String, lines: [Line], received: Int64, customer: Customer?) throws -> Sale {
        let sale = try database().checkout(id: id, lines: lines, received: received, customer: customer)
        sync?.requestAutoSync()
        return sale
    }
    func cancel(_ id: String, reason: String) throws { try database().cancel(id: id, reason: reason); try reload(); sync?.requestAutoSync() }
    func refresh() { do { try reload() } catch { self.error = error.localizedDescription } }
    private func database() throws -> SQLiteStore {
        guard let store else { throw POSFailure.invalid("保存データを開けません") }; return store
    }
}

func jstTime(_ value: String) -> String {
    let parser = ISO8601DateFormatter()
    guard let date = parser.date(from: value) ?? { parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return parser.date(from: value) }() else { return value }
    let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.timeZone = TimeZone(identifier: "Asia/Tokyo"); f.dateFormat = "yyyy/MM/dd HH:mm:ss 'JST'"
    return f.string(from: date)
}

struct RootView: View {
    @StateObject private var model = RegisterModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Group {
            if model.ready {
                TabView {
                    Group {
                        RegisterTab(model: model).tabItem { Label("レジ", systemImage: "cart") }
                        ProductsView(model: model).tabItem { Label("商品", systemImage: "square.grid.2x2") }
                        HistoryView(model: model).tabItem { Label("履歴", systemImage: "clock") }
                        DrawerView(model: model).tabItem { Label("締め", systemImage: "banknote") }
                    }
                    .toolbarBackground(Color.tofuCard, for: .tabBar)
                    .toolbarBackground(.visible, for: .tabBar)
                }
                // A new identity per environment discards carts, sheets and other screen state.
                .id(model.environment)
            } else {
                VStack(spacing: 20) {
                    Text("データを開けません").font(.title); Text(model.error ?? "起動に失敗しました")
                    if model.environment == .test { Button("本番環境に戻す") { model.switchEnvironment(to: .production) } }
                }
                    .padding().frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.tofuBackground)
            }
        }
        .environment(\.isTestEnvironment, model.environment == .test)
        .onAppear { model.setActive(scenePhase == .active); MacWindow.configure() }
        .onChange(of: scenePhase) { phase in model.setActive(phase == .active) }
        .alert("確認してください", isPresented: Binding(get: { model.ready && model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("閉じる", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

struct RegisterView: View {
    @ObservedObject var model: RegisterModel
    @State private var cart: [Line] = []
    @State private var received = ""
    @State private var commandID = UUID().uuidString
    @State private var receipt: Sale?
    @State private var confirming = false
    @State private var age: CustomerAge?
    @State private var gender: CustomerGender?
    @State private var group: CustomerGroup?
    @State private var customerPage = 0
    @State private var scrollToTop = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isTestEnvironment) private var isTest
    @FocusState private var receivedFocused: Bool
    private var total: Int64? { try? Money.total(cart) }
    private var cash: Int64? { Money.parse(received) }
    private var canCheckout: Bool {
        guard let total, let cash else { return false }
        return cash >= total
    }
    /// Remaining stock after the cart; nil while the stock has not been fetched (sold without a stock label).
    private func remaining(_ product: Product) -> Int64? {
        guard let stock = model.stock[product.id] else { return nil }
        return stock - Int64(cart.first(where: { $0.productID == product.id })?.quantity ?? 0)
    }
    /// Stop-at-zero products cap the cart quantity at the displayed stock (never below what is already in the cart).
    private func maxQuantity(_ line: Line) -> Int {
        guard let product = model.products.first(where: { $0.id == line.productID }), product.stopAtZero,
              let stock = model.stock[product.id] else { return 999 }
        return max(line.quantity, Int(min(999, max(0, stock))))
    }
    @Environment(\.horizontalSizeClass) private var sizeClass
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Group {
                if WideLayout.isWide(sizeClass) {
                    // iPad/Mac: product grid on the left, cart and payment on the right.
                    HStack(spacing: 0) {
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                                ForEach(model.products.filter(\.active)) { productTile($0) }
                            }.padding(16)
                            if !model.products.contains(where: \.active) { Text("「商品」タブで商品を登録してください").padding() }
                        }
                        Divider()
                        List { Group { checkoutSections(proxy) }.tofuRows() }
                            .frame(width: 420)
                    }
                } else {
                    List {
                        Group {
                            productSection
                            checkoutSections(proxy)
                        }.tofuRows()
                    }
                }
                }
                // After a purchase, back to the top (products on iPhone, the cart column on iPad/Mac).
                .onChange(of: scrollToTop) { _ in
                    let target = WideLayout.isWide(sizeClass) ? "cartTop" : "top"
                    if reduceMotion { proxy.scrollTo(target, anchor: .top) } else { withAnimation { proxy.scrollTo(target, anchor: .top) } }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("TOS")
            .tofuSurface(fullWidth: true)
            .syncToolbar(model)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完了") { receivedFocused = false }
                }
            }
            .onDisappear { receivedFocused = false }
            .confirmationDialog("¥\(Yen.format(total ?? 0)) の会計を確定しますか？", isPresented: $confirming, titleVisibility: .visible) {
                Button("確定する") { checkout() }
                Button("戻る", role: .cancel) {}
            } message: { Text(confirmMessage) }
            .sheet(item: $receipt) { sale in
                VStack(spacing: 24) {
                    if isTest { Text("テスト環境").font(.headline).foregroundColor(.red) }
                    if let ticket = sale.ticketNo { Text("整理番号 \(ticket)").font(.system(size: 56, weight: .bold, design: .rounded)) }
                    Text("会計を保存しました").font(.title)
                    Text("合計 ¥\(Yen.format(sale.total))").font(.title2)
                    Text("預り金 ¥\(Yen.format(sale.received))")
                    if sale.customerAge != nil || sale.customerGender != nil || sale.customerGroup != nil {
                        Text("客層: \(Customer.text(age: sale.customerAge, gender: sale.customerGender, group: sale.customerGroup))").foregroundColor(.tofuMuted)
                    }
                    Text("お釣り ¥\(Yen.format(sale.change))").font(.largeTitle.bold())
                    Button { receipt = nil } label: { Text("次のお客様").foregroundColor(.tofuOnAccent) }.buttonStyle(.borderedProminent)
                }.padding().interactiveDismissDisabled()
            }
        }
    }
    @ViewBuilder private var productSection: some View {
        Section("商品を選択") {
            let visible = model.products.filter(\.active)
            if visible.isEmpty { Text("「商品」タブで商品を登録してください") }
            ForEach(visible) { product in
                let left = remaining(product)
                Button { add(product) } label: {
                    HStack {
                        ProductPhoto(images: model.images, hash: product.imageHash, size: 36, corner: 8)
                        Text(product.name); Spacer()
                        if let left {
                            if StockMath.soldOut(product, displayed: left) {
                                Text("売り切れ").font(.caption).foregroundColor(.red)
                            } else {
                                Text(product.stopAtZero ? "残り\(left)" : StockMath.label(left)).font(.caption).foregroundColor(left > 0 ? .secondary : .red)
                            }
                        }
                        Text("¥\(Yen.format(product.price))")
                    }.frame(minHeight: 48)
                }.disabled(StockMath.soldOut(product, displayed: left))
            }
        }.id("top")
    }
    @ViewBuilder private func checkoutSections(_ proxy: ScrollViewProxy) -> some View {
        Section("カート") {
            ForEach(cart) { line in
                VStack(alignment: .leading) {
                    Text("\(line.name)　¥\(Yen.format(line.price))")
                    Stepper("数量 \(line.quantity)", value: Binding(get: { line.quantity }, set: { setQuantity(line.id, $0) }), in: 0...maxQuantity(line))
                }.frame(minHeight: 56)
            }
            if cart.isEmpty { Text("商品を選ぶとここに表示されます") }
            Text("合計　¥\(Yen.format(total ?? 0))").font(.title2.bold())
        }.id("cartTop")
        Section("客層（任意）") {
            CustomerPager(age: $age, gender: $gender, group: $group, page: $customerPage) {
                if reduceMotion { proxy.scrollTo("cash", anchor: .center) } else { withAnimation { proxy.scrollTo("cash", anchor: .center) } }
            }
        }
        Section("預り金") {
            TextField("預り金（円）", text: $received).id("cash")
                .keyboardType(.numberPad)
                .focused($receivedFocused)
                // Hardware keyboards (iPad/Mac): Return opens the confirmation; the iPhone number pad has no Return.
                .onSubmit { if canCheckout { receivedFocused = false; confirming = true } }
            HStack {
                Button("ちょうど") { setReceived(total ?? 0) }.disabled(cart.isEmpty)
                Button("1,000円") { setReceived(1000) }
                Button("5,000円") { setReceived(5000) }
                Button("10,000円") { setReceived(10000) }
            }.buttonStyle(.bordered)
            HStack {
                Button("+100") { addReceived(100) }
                Button("+500") { addReceived(500) }
                Button("+1,000") { addReceived(1000) }
                Button("クリア") { receivedFocused = false; received = "" }
            }.buttonStyle(.bordered)
            if let total, let cash, cash >= total {
                Text("お釣り　¥\(Yen.format(cash - total))").font(.title2.bold())
            }
            Button("購入") {
                receivedFocused = false
                confirming = true
            }
                .frame(minHeight: 56)
                .disabled(!canCheckout)
        }
        Section { Text("会計は端末内に保存し、通信を待ちません。CSVは分析用で、完全な復元用バックアップではありません。").font(.footnote) }
    }
    private func productTile(_ product: Product) -> some View {
        let left = remaining(product)
        let soldOut = StockMath.soldOut(product, displayed: left)
        return Button { add(product) } label: {
            VStack(spacing: 6) {
                ProductPhoto(images: model.images, hash: product.imageHash, size: 72, corner: 12)
                Text(product.name).font(.headline).lineLimit(2).multilineTextAlignment(.center)
                Text("¥\(Yen.format(product.price))")
                if let left {
                    Text(soldOut ? "売り切れ" : (product.stopAtZero ? "残り\(left)" : StockMath.label(left))).font(.caption)
                        .foregroundColor(soldOut || left <= 0 ? .red : .secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 150).padding(8)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.tofuCard))
            .opacity(soldOut ? 0.5 : 1)
        }
        .buttonStyle(.plain).disabled(soldOut)
    }
    private var confirmMessage: String {
        guard let total, let cash, cash >= total else { return "" }
        return "預り金 ¥\(Yen.format(cash))　お釣り ¥\(Yen.format(cash - total))\n客層: \(Customer.text(age: age?.rawValue, gender: gender?.rawValue, group: group?.rawValue))"
    }
    private func setReceived(_ value: Int64) { receivedFocused = false; received = String(min(max(0, value), Money.maximum)) }
    private func addReceived(_ value: Int64) { setReceived((cash ?? 0) + value) }
    private func add(_ product: Product) {
        receivedFocused = false
        if let index = cart.firstIndex(where: { $0.productID == product.id }) {
            guard cart[index].quantity < 999 else { return }; cart[index].quantity += 1
        } else { cart.append(Line(productID: product.id, name: product.name, price: product.price, quantity: 1)) }
        received = ""
    }
    private func setQuantity(_ id: String, _ quantity: Int) {
        receivedFocused = false
        guard let index = cart.firstIndex(where: { $0.id == id }) else { return }
        if quantity == 0 { cart.remove(at: index) } else { cart[index].quantity = quantity }
        received = ""
    }
    private func checkout() {
        receivedFocused = false
        do {
            guard let cash = Money.parse(received) else { throw POSFailure.invalid("預り金を確認してください") }
            let sale = try model.checkout(id: commandID, lines: cart, received: cash, customer: Customer(age: age, gender: gender, group: group))
            cart = []; received = ""; commandID = UUID().uuidString; receipt = sale
            self.age = nil; self.gender = nil; group = nil; customerPage = 0; scrollToTop += 1
            model.refresh()
        } catch { model.error = error.localizedDescription }
    }
}

struct ProductsView: View {
    @ObservedObject var model: RegisterModel
    @State private var editing: Product?
    @State private var showing = false
    var body: some View {
        NavigationStack {
            List(model.products) { product in
                Group {
                    Button { editing = product; showing = true } label: {
                        HStack {
                            ProductPhoto(images: model.images, hash: product.imageHash, size: 40, corner: 8)
                            VStack(alignment: .leading) {
                                Text(product.name)
                                if !product.active { Text("販売停止").font(.caption).foregroundColor(.red) }
                            }
                            Spacer()
                            if let stock = model.stock[product.id] {
                                Text(StockMath.label(stock)).font(.caption).foregroundColor(stock > 0 ? .secondary : .red)
                            }
                            Text("¥\(Yen.format(product.price))")
                        }.frame(minHeight: 48)
                    }
                }.tofuRows()
            }.navigationTitle("商品")
                .tofuSurface()
                .syncToolbar(model)
                .toolbar { ToolbarItem(placement: .primaryAction) { Button("追加") { editing = nil; showing = true } } }
                .sheet(isPresented: $showing) { ProductEditor(model: model, product: editing) }
        }
    }
}

struct ProductEditor: View {
    @ObservedObject var model: RegisterModel
    let product: Product?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var price = ""
    @State private var active = true
    @State private var stopAtZero = false
    @State private var quantity = ""
    @State private var failure: String?
    @State private var notice: String?
    @State private var imageHash: String?
    @State private var pickerItem: PhotosPickerItem?
    @State private var processing = false
    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section("写真") {
                        HStack(spacing: 12) {
                            ProductPhoto(images: model.images, hash: imageHash, size: 72, corner: 12)
                            if processing { TofuLoading() }
                        }
                        PhotosPicker(selection: $pickerItem, matching: .images) { Text("写真を選ぶ") }.disabled(processing)
                        if imageHash != nil { Button("写真を外す", role: .destructive) { imageHash = nil } }
                        Text("長辺800pxに縮小して保存し、位置情報などは含めません。保存すると他の端末にも配ります。").font(.footnote)
                    }
                    Section {
                        TextField("商品名", text: $name)
                        TextField("価格（円）", text: $price).keyboardType(.numberPad)
                        Toggle("販売中", isOn: $active)
                        Toggle("在庫0で販売を止める", isOn: $stopAtZero)
                        if let failure { Text(failure).foregroundStyle(.red) }
                        Text("価格変更前の会計とカートの単価は変わりません。保存すると他の端末にも自動で反映します。").font(.footnote)
                    }
                    if let product {
                        Section("在庫") {
                            Text(model.stock[product.id].map(StockMath.label) ?? "在庫は通信後に表示します")
                            TextField("数量", text: $quantity).keyboardType(.numberPad)
                            Button("在庫を数えて設定") { adjust(product, kind: "set") }
                            Button("入荷を追加") { adjust(product, kind: "add") }
                            if let notice { Text(notice).font(.footnote) }
                            Text("在庫はクラウドで集計します。通信後に他の端末の販売分も反映されます。").font(.footnote)
                        }
                    }
                }.tofuRows()
            }.navigationTitle(product == nil ? "商品追加" : "商品編集")
                .tofuSurface()
                .scrollDismissesKeyboard(.interactively)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("戻る") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
                }
                .onAppear {
                    name = product?.name ?? ""; price = product.map { String($0.price) } ?? ""
                    active = product?.active ?? true; stopAtZero = product?.stopAtZero ?? false; imageHash = product?.imageHash
                }
                .onChange(of: pickerItem) { item in
                    guard let item else { return }
                    processing = true
                    Task { await loadPhoto(item) }
                }
        }
    }
    private func save() {
        do {
            guard let value = Money.parse(price) else { throw POSFailure.invalid("価格は0〜1,000,000,000円の整数で入力してください") }
            try model.save(Product(id: product?.id ?? UUID().uuidString, name: name, price: value, active: active, stopAtZero: stopAtZero, imageHash: imageHash),
                           newImage: imageHash != product?.imageHash ? imageHash : nil); dismiss()
        } catch { failure = error.localizedDescription }
    }
    private func loadPhoto(_ item: PhotosPickerItem) async {
        defer { processing = false; pickerItem = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw POSFailure.invalid("写真を読み込めません") }
            let jpeg = try await Task.detached(priority: .userInitiated) { try PhotoProcessing.jpeg(from: data) }.value
            imageHash = try model.storePhoto(jpeg); failure = nil
        } catch { failure = "写真を使えません。\(error.localizedDescription)" }
    }
    private func adjust(_ product: Product, kind: String) {
        do {
            guard let value = Money.parse(quantity), value <= 1_000_000, kind == "set" || value > 0 else { throw POSFailure.invalid("数量は0〜1,000,000の整数で入力してください") }
            try model.adjustStock(product.id, kind: kind, quantity: value)
            notice = kind == "set" ? "在庫を\(value)に設定しました" : "\(value)個の入荷を記録しました"; quantity = ""; failure = nil
        } catch { failure = error.localizedDescription }
    }
}

struct DenominationEditor: View {
    @Binding var counts: [String: Int]
    var body: some View {
        ForEach(Cash.denominations, id: \.self) { denomination in
            let key = String(denomination)
            HStack {
                Text(Cash.label(denomination))
                Spacer()
                // Zero shows as empty (placeholder "0") so deleting it does not echo a "0" back in front of the typed digits.
                TextField("0", text: Binding(get: { (counts[key] ?? 0) == 0 ? "" : String(counts[key] ?? 0) },
                                             set: { counts[key] = min(9999, Int($0.filter { $0.isASCII && $0.isNumber }) ?? 0) }))
                    .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 64)
                Stepper("枚数", value: Binding(get: { counts[key] ?? 0 }, set: { counts[key] = $0 }), in: 0...9999).labelsHidden()
            }
        }
        Text("合計 ¥\(Yen.format((try? Cash.total(counts)) ?? 0))").font(.headline)
    }
}

struct DrawerView: View {
    @ObservedObject var model: RegisterModel
    @State private var counts: [String: Int] = [:]
    @State private var closing: DrawerSession?
    var body: some View {
        NavigationStack {
            Form {
                Group {
                    if let session = model.session {
                        let summary = model.sessionSummary
                        Section("営業中") {
                            LabeledContent("開始", value: jstTime(session.openedAt))
                            LabeledContent("釣銭準備金", value: "¥\(Yen.format(session.floatTotal))")
                            LabeledContent("売上", value: "¥\(Yen.format(summary?.salesTotal ?? 0))（\(summary?.orderCount ?? 0)件）")
                            LabeledContent("取消・返金", value: "¥\(Yen.format(summary?.cancelTotal ?? 0))")
                            LabeledContent("現金在高（理論値）", value: "¥\(Yen.format(summary?.expected ?? session.floatTotal))").font(.headline)
                            Button("レジ締め") { closing = session }
                        }
                        Section("客層別の件数") {
                            ForEach(CustomerAge.allCases) { age in
                                HStack {
                                    Text(age.label)
                                    Spacer()
                                    Text(CustomerGender.allCases.map { "\($0.label)\(summary?.segments["\(age.rawValue)/\($0.rawValue)"] ?? 0)" }.joined(separator: "　")).font(.footnote)
                                }
                            }
                            HStack {
                                Text("集団")
                                Spacer()
                                Text(CustomerGroup.allCases.map { "\($0.label)\(summary?.groups[$0.rawValue] ?? 0)" }.joined(separator: "　")).font(.footnote)
                                    .lineLimit(1).minimumScaleFactor(0.7)
                            }
                        }
                    } else {
                        Section("レジ開け（釣銭準備金の枚数）") {
                            DenominationEditor(counts: $counts)
                            Button("レジを開ける") {
                                do { try model.openDrawer(counts); counts = [:] } catch { model.error = error.localizedDescription }
                            }
                        }
                    }
                    if let last = model.lastClosed, let counted = last.countedTotal, let expected = last.expectedTotal {
                        Section("前回のレジ締め") {
                            LabeledContent("期間", value: "\(jstTime(last.openedAt))〜\(last.closedAt.map(jstTime) ?? "")")
                            LabeledContent("理論値", value: "¥\(Yen.format(expected))")
                            LabeledContent("実際の合計", value: "¥\(Yen.format(counted))")
                            LabeledContent("差額", value: difference(counted - expected)).foregroundColor(counted == expected ? .primary : .red)
                        }
                    }
                    Section { Text("レジを開けなくても会計できます。その会計はどの締めにも入りません。理論値は準備金＋この端末で期間中に作成した会計−期間中にこの端末で記録した取消です。").font(.footnote) }
                }.tofuRows()
            }.navigationTitle("締め")
                .tofuSurface()
                .syncToolbar(model)
                .scrollDismissesKeyboard(.interactively)
                .sheet(item: $closing) { DrawerCloseView(model: model, session: $0) }
        }
    }
}

func difference(_ value: Int64) -> String { value == 0 ? "¥0" : (value > 0 ? "+¥\(Yen.format(value))" : "-¥\(Yen.format(-value))") }

struct DrawerCloseView: View {
    @ObservedObject var model: RegisterModel
    let session: DrawerSession
    @Environment(\.dismiss) private var dismiss
    @State private var counts: [String: Int] = [:]
    @State private var confirming = false
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section("実査（金種ごとの枚数）") { DenominationEditor(counts: $counts) }
                    let expected = model.sessionSummary?.expected ?? session.floatTotal
                    let counted = (try? Cash.total(counts)) ?? 0
                    Section("差額") {
                        LabeledContent("実際の合計", value: "¥\(Yen.format(counted))")
                        LabeledContent("理論値", value: "¥\(Yen.format(expected))")
                        LabeledContent("差額", value: difference(counted - expected)).foregroundColor(counted == expected ? .primary : .red)
                        if let failure { Text(failure).foregroundStyle(.red) }
                        Button("締めを確定") { confirming = true }
                    }
                }.tofuRows()
            }.navigationTitle("レジ締め")
                .tofuSurface()
                .scrollDismissesKeyboard(.interactively)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("戻る") { dismiss() } } }
                .alert("レジを締めますか？", isPresented: $confirming) {
                    Button("締める", role: .destructive) {
                        do { try model.closeDrawer(session.id, counted: counts); dismiss() } catch { failure = error.localizedDescription }
                    }
                    Button("戻る", role: .cancel) {}
                } message: { Text("実査の枚数・理論値・差額を記録します。確定後は変更できません。") }
        }
    }
}

struct HistoryView: View {
    @ObservedObject var model: RegisterModel
    @State private var cancelling: Sale?
    @State private var exporting = false
    @State private var document = CSVDocument(text: "")
    var body: some View {
        NavigationStack {
            List {
                Group {
                    Section("全期間の売上") {
                        Text("¥\(model.sales.filter { $0.cancelledAt == nil }.reduce(Int64(0)) { $0 + $1.total })").font(.largeTitle.bold())
                        Text("会計 \(model.sales.filter { $0.cancelledAt == nil }.count)件 ／ 取消 \(model.sales.filter { $0.cancelledAt != nil }.count)件")
                    }
                    ForEach(model.sales) { sale in
                        Section {
                            HStack {
                                Text(jstTime(sale.createdAt) + (sale.deviceID != nil && sale.deviceID != model.deviceID ? "　他の端末" : "")).font(.caption)
                                Spacer()
                                if let ticket = sale.ticketNo { Text("整理番号 \(ticket)").font(.headline) }
                            }
                            if sale.customerAge != nil || sale.customerGender != nil || sale.customerGroup != nil {
                                Text("客層: \(Customer.text(age: sale.customerAge, gender: sale.customerGender, group: sale.customerGroup))").font(.caption)
                            }
                            Text("¥\(sale.total)　\(sale.cancelledAt == nil ? "会計済み" : "取消済み")").font(.headline)
                            ForEach(sale.lines) { line in Text("\(line.name) × \(line.quantity)　¥\(line.price * Int64(line.quantity))") }
                            Text("預り ¥\(sale.received) ／ 釣銭 ¥\(sale.change)")
                            if let reason = sale.cancellationReason { Text("取消理由: \(reason)") }
                            if sale.cancelledAt == nil { Button("全額取消・返金記録", role: .destructive) { cancelling = sale } }
                        }
                    }
                }.tofuRows()
            }.navigationTitle("履歴・売上")
                .tofuSurface()
                .syncToolbar(model)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { document = CSVDocument(text: SalesCSV.make(model.sales, ticket: true)); exporting = true } label: { Image(systemName: "square.and.arrow.up") }
                            .disabled(model.sales.isEmpty).accessibilityLabel("全件をCSVに書き出す")
                    }
                }
                .sheet(item: $cancelling) { CancellationView(model: model, sale: $0) }
                .fileExporter(isPresented: $exporting, document: document, contentType: .commaSeparatedText, defaultFilename: "tofu-pos-sales") { result in
                    if case .failure(let error) = result { model.error = error.localizedDescription }
                }
        }
    }
}

struct CancellationView: View {
    @ObservedObject var model: RegisterModel
    let sale: Sale
    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""
    @State private var refunded = false
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Text("全額 ¥\(sale.total) を返金してから記録してください。元の会計は履歴に残ります。")
                    TextField("取消理由", text: $reason)
                    Toggle(sale.total == 0 ? "0円会計の取消を確認した" : "全額返金を完了した", isOn: $refunded)
                    if let failure { Text(failure).foregroundStyle(.red) }
                    Button("取消を記録", role: .destructive) {
                        do { try model.cancel(sale.id, reason: reason); dismiss() }
                        catch { failure = error.localizedDescription }
                    }.disabled(!refunded || reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.tofuRows()
            }.navigationTitle("全額取消")
                .tofuSurface()
                .toolbar { Button("戻る") { dismiss() } }
        }
    }
}

struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws { text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}
