import SwiftUI

/// Register tab: the single-product screen while exactly one product is on sale, else the cart screen.
struct RegisterTab: View {
    @ObservedObject var model: RegisterModel
    var body: some View {
        if let product = model.singleProduct {
            SingleProductView(model: model, product: product)
        } else {
            RegisterView(model: model)
        }
    }
}

/// Optional segment, one axis per page: 年齢 → 性別 → 集団. Choosing a chip moves to the next axis;
/// choosing 集団 calls `onComplete` so the screen can scroll to the amount/confirm area. Tapping the
/// selected chip only clears it. Reduce Motion switches pages without animation.
struct CustomerPager: View {
    @Binding var age: CustomerAge?
    @Binding var gender: CustomerGender?
    @Binding var group: CustomerGroup?
    @Binding var page: Int
    var onComplete: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let titles = ["年齢", "性別", "集団"]
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { index in
                    Button { move(to: index) } label: {
                        VStack(spacing: 1) {
                            Text(titles[index]).font(.subheadline.weight(page == index ? .bold : .regular))
                            Text(selection(index) ?? "－").font(.caption2).lineLimit(1).minimumScaleFactor(0.7)
                                .foregroundColor(selection(index) == nil ? .tofuMuted : .accentColor)
                        }
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .overlay(alignment: .bottom) { Rectangle().fill(page == index ? Color.accentColor : Color.clear).frame(height: 2) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(titles[index]) \(selection(index) ?? "未選択")")
                }
            }
            TabView(selection: $page) {
                row(CustomerAge.allCases.map { a in (a.label, age == a, { tap(age == a) { age = age == a ? nil : a } }) }).tag(0)
                row(CustomerGender.allCases.map { g in (g.label, gender == g, { tap(gender == g) { gender = gender == g ? nil : g } }) }).tag(1)
                row(CustomerGroup.allCases.map { g in (g.label, group == g, { tap(group == g) { group = group == g ? nil : g } }) }).tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 52)
        }
    }
    private func selection(_ index: Int) -> String? {
        switch index { case 0: return age?.label; case 1: return gender?.label; default: return group?.label }
    }
    private func row(_ chips: [(String, Bool, () -> Void)]) -> some View {
        HStack(spacing: 6) {
            ForEach(chips.indices, id: \.self) { i in
                Button(action: chips[i].2) {
                    // 5 group chips share one row: shrink rather than wrap 「カップル」「グループ」.
                    Text(chips[i].0).font(.subheadline.weight(chips[i].1 ? .bold : .regular))
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .padding(.horizontal, 2)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundColor(chips[i].1 ? .tofuOnAccent : .primary)
                        .background(RoundedRectangle(cornerRadius: 18).fill(chips[i].1 ? Color.accentColor : Color.tofuSoft.opacity(0.5)))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chips[i].1 ? .isSelected : [])
            }
        }.padding(.horizontal, 1)
    }
    /// `wasSelected`: re-tapping clears only; a new choice advances.
    private func tap(_ wasSelected: Bool, _ change: () -> Void) {
        change()
        guard !wasSelected else { return }
        if page < 2 { move(to: page + 1) } else { onComplete() }
    }
    private func move(to index: Int) {
        if reduceMotion { page = index } else { withAnimation(.easeInOut(duration: 0.25)) { page = index } }
    }
}

struct SingleProductView: View {
    @ObservedObject var model: RegisterModel
    let product: Product
    @State private var quantity = 1
    @State private var choice = QuickSale.Choice.none
    @State private var manualText = ""
    @State private var age: CustomerAge?
    @State private var gender: CustomerGender?
    @State private var group: CustomerGroup?
    @State private var customerPage = 0
    @State private var scrollToTop = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var commandID = UUID().uuidString
    @State private var saving = false
    @State private var toast: Sale?
    @State private var toastTask: Task<Void, Never>?
    @FocusState private var manualFocused: Bool
    @Environment(\.isTestEnvironment) private var isTest
    private let toastDark = Color(red: 0x2E / 255, green: 0x20 / 255, blue: 0x18 / 255)

    private var displayed: Int64? { model.stock[product.id] }
    private var limit: Int { QuickSale.maxQuantity(product, displayed: displayed) }
    private var soldOut: Bool { StockMath.soldOut(product, displayed: displayed) }
    private var total: Int64? { try? Money.total([line]) }
    private var line: Line { Line(productID: product.id, name: product.name, price: product.price, quantity: quantity) }
    private var received: Int64? { choice.received(total: total, manual: manualText) }
    private var change: Int64? { QuickSale.change(total: total, choice: choice, manual: manualText) }
    private var canConfirm: Bool { !saving && !soldOut && quantity >= 1 && change != nil }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 12) {
                    productCard.id("top")
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) { Text("客層").font(.headline); Text("任意").font(.caption).foregroundColor(.tofuMuted) }
                        CustomerPager(age: $age, gender: $gender, group: $group, page: $customerPage) {
                            if reduceMotion { proxy.scrollTo("money", anchor: .top) } else { withAnimation { proxy.scrollTo("money", anchor: .top) } }
                        }
                        Text("受け取った額").font(.headline).padding(.top, 6).id("money")
                        moneyGrid
                        if case .manual = choice {
                            TextField("預り金（円）", text: $manualText)
                                .keyboardType(.numberPad).focused($manualFocused)
                                .onSubmit { confirm() }
                                .padding(10).background(RoundedRectangle(cornerRadius: 10).stroke(Color.tofuMuted.opacity(0.5)))
                        }
                    }.card()
                    changeBox
                    Button { confirm() } label: {
                        Text("購入").font(.title3.bold()).foregroundColor(.tofuOnAccent).frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canConfirm)
                    .keyboardShortcut(.defaultAction)  // Return on iPad/Mac hardware keyboards
                }
                .padding(16)
                .padding(.bottom, toast == nil ? 0 : 72)
                .readableWidth()
            }
            .scrollDismissesKeyboard(.interactively)
            // After a purchase, back to the product card and quantity.
            .onChange(of: scrollToTop) { _ in
                if reduceMotion { proxy.scrollTo("top", anchor: .top) } else { withAnimation { proxy.scrollTo("top", anchor: .top) } }
            }
            }
            .background(Color.tofuBackground)
            .modifier(TofuBar())
            .navigationTitle("レジ")
            .syncToolbar(model)
            .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完了") { manualFocused = false } } }
            .overlay(alignment: .bottom) { if let toast { toastView(toast) } }
            .onChange(of: quantity) { _ in choice = .none; manualText = "" }
            .onChange(of: limit) { newLimit in if quantity > max(1, newLimit) { quantity = max(1, newLimit) } }
            .onDisappear { manualFocused = false }
        }
    }

    private var productCard: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                ProductPhoto(images: model.images, hash: product.imageHash, size: 72, corner: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(product.name).font(.title2.bold())
                    Text("¥\(Yen.format(product.price)) / 本").foregroundColor(.tofuMuted)
                    if soldOut {
                        Text("売り切れ").font(.subheadline.bold()).foregroundColor(.red)
                    } else if let displayed {
                        Text(StockMath.label(displayed)).font(.subheadline).foregroundColor(displayed > 0 ? .tofuMuted : .red)
                    }
                }
                Spacer()
            }
            HStack {
                roundButton("minus", enabled: quantity > 1) { quantity -= 1 }
                Spacer()
                VStack(spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(quantity)").font(.system(size: 48, weight: .bold, design: .rounded)).monospacedDigit()
                        Text("本").font(.title3)
                    }
                    Text("合計 ¥\(Yen.format(total ?? 0))").font(.headline).foregroundColor(.tofuMuted)
                }
                Spacer()
                roundButton("plus", enabled: quantity < limit) { quantity += 1 }
            }
        }.card()
    }

    private func roundButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button { manualFocused = false; action() } label: {
            Image(systemName: symbol).font(.title.bold()).frame(width: 64, height: 64)
                .foregroundColor(enabled ? .tofuOnAccent : .tofuMuted)
                .background(Circle().fill(enabled ? Color.accentColor : Color.tofuSoft.opacity(0.5)))
        }
        .buttonStyle(.plain).disabled(!enabled)
        .accessibilityLabel(symbol == "plus" ? "1本増やす" : "1本減らす")
    }

    private var moneyGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            moneyButton("ちょうど", selected: choice == .exact, enabled: true) { choice = choice.toggled(.exact) }
            ForEach(QuickSale.presets, id: \.self) { value in
                moneyButton(Yen.format(value), selected: choice == .preset(value),
                            enabled: value >= (total ?? 0)) { choice = choice.toggled(.preset(value)) }
            }
            moneyButton("手入力", selected: choice == .manual, enabled: true) {
                // Show an empty field and focus it once it exists, which opens the number pad.
                manualText = ""
                choice = choice.toggled(.manual)
                guard choice == .manual else { manualFocused = false; return }
                DispatchQueue.main.async { manualFocused = true }
            }
        }
    }

    private func moneyButton(_ label: String, selected: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button { if label != "手入力" { manualFocused = false }; action() } label: {
            Text(label).font(.headline).frame(maxWidth: .infinity, minHeight: 48)
                .foregroundColor(selected ? .tofuOnAccent : (enabled ? .primary : .tofuMuted.opacity(0.6)))
                .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor : Color.tofuSoft.opacity(enabled ? 0.6 : 0.25)))
        }
        .buttonStyle(.plain).disabled(!enabled)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var changeBox: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("お釣り").font(.headline)
                Spacer()
                Text(change.map { "¥\(Yen.format($0))" } ?? (choice == .none ? "—" : "不足")).font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
            }
            .foregroundColor(toastDark)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.tofuTop))
            HStack {
                if choice == .none { Text("受け取った額を選んでください").foregroundColor(.tofuMuted) }
                else if change == nil { Text("預り金が合計に足りません").foregroundColor(.red) }
                Spacer()
                if let received { Text("預り ¥\(Yen.format(received))").foregroundColor(.tofuMuted) }
            }.font(.footnote).padding(.horizontal, 4)
        }
    }

    private func toastView(_ sale: Sale) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if let ticket = sale.ticketNo {
                    Text("整理番号 \(ticket)").font(.system(size: 34, weight: .bold, design: .rounded)).foregroundColor(.tofuTop)
                }
                Text((isTest ? "テスト・" : "") + QuickSale.savedText(sale)).font(.subheadline).foregroundColor(.white).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button("取消") { undo(sale) }.font(.subheadline.bold()).foregroundColor(.tofuTop)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(toastDark.opacity(0.95)))
        .padding(.horizontal, 16).padding(.bottom, 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func confirm() {
        guard canConfirm, let received else { return }
        manualFocused = false
        // Saving stays on for a moment after the write so a double tap cannot start a second sale.
        saving = true
        do {
            let customer = Customer(age: age, gender: gender, group: group)
            let sale = try model.checkout(id: commandID, lines: [line], received: received, customer: customer)
            commandID = UUID().uuidString
            quantity = 1; choice = .none; manualText = ""; age = nil; gender = nil; group = nil; customerPage = 0
            model.refresh()
            show(sale)
            scrollToTop += 1
        } catch { model.error = error.localizedDescription }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            saving = false
        }
    }
    private func show(_ sale: Sale) {
        toastTask?.cancel()
        withAnimation { toast = sale }
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { toast = nil }
        }
    }
    private func undo(_ sale: Sale) {
        toastTask?.cancel()
        withAnimation { toast = nil }
        do { try model.cancel(sale.id, reason: QuickSale.undoReason) } catch { model.error = error.localizedDescription }
    }
}

private extension View {
    func card() -> some View {
        padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.tofuCard))
    }
}
