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

/// Optional segment chips (age 4, gender 3); tapping the selected chip clears it.
struct CustomerChips: View {
    @Binding var age: CustomerAge?
    @Binding var gender: CustomerGender?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) { ForEach(CustomerAge.allCases) { a in chip(a.label, on: age == a) { age = age == a ? nil : a } } }
            HStack(spacing: 6) { ForEach(CustomerGender.allCases) { g in chip(g.label, on: gender == g) { gender = gender == g ? nil : g } } }
        }
    }
    private func chip(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.subheadline.weight(on ? .bold : .regular))
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundColor(on ? .tofuOnAccent : .primary)
                .background(RoundedRectangle(cornerRadius: 18).fill(on ? Color.accentColor : Color.tofuSoft.opacity(0.5)))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct SingleProductView: View {
    @ObservedObject var model: RegisterModel
    let product: Product
    private enum CashChoice { case exact, preset(Int64), manual }
    @State private var quantity = 1
    @State private var choice = CashChoice.exact
    @State private var manualText = ""
    @State private var age: CustomerAge?
    @State private var gender: CustomerGender?
    @State private var commandID = UUID().uuidString
    @State private var saving = false
    @State private var toast: Sale?
    @State private var toastTask: Task<Void, Never>?
    @FocusState private var manualFocused: Bool
    private let toastDark = Color(red: 0x2E / 255, green: 0x20 / 255, blue: 0x18 / 255)

    private var displayed: Int64? { model.stock[product.id] }
    private var limit: Int { QuickSale.maxQuantity(product, displayed: displayed) }
    private var soldOut: Bool { StockMath.soldOut(product, displayed: displayed) }
    private var total: Int64? { try? Money.total([line]) }
    private var line: Line { Line(productID: product.id, name: product.name, price: product.price, quantity: quantity) }
    private var received: Int64? {
        switch choice {
        case .exact: return total
        case .preset(let value): return value
        case .manual: return Money.parse(manualText)
        }
    }
    private var change: Int64? {
        guard let total, let received, received >= total else { return nil }
        return received - total
    }
    private var canConfirm: Bool { !saving && !soldOut && quantity >= 1 && change != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    productCard
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) { Text("客層").font(.headline); Text("任意").font(.caption).foregroundColor(.tofuMuted) }
                        CustomerChips(age: $age, gender: $gender)
                        Text("受け取った額").font(.headline).padding(.top, 6)
                        moneyGrid
                        if case .manual = choice {
                            TextField("預り金（円）", text: $manualText)
                                .keyboardType(.numberPad).focused($manualFocused)
                                .padding(10).background(RoundedRectangle(cornerRadius: 10).stroke(Color.tofuMuted.opacity(0.5)))
                        }
                    }.card()
                    changeBox
                    Button { confirm() } label: {
                        Text("確定して次へ").font(.title3.bold()).foregroundColor(.tofuOnAccent).frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canConfirm)
                    Text("会計は端末内に保存し、通信を待ちません。").font(.footnote).foregroundColor(.tofuMuted)
                }
                .padding(16)
                .padding(.bottom, toast == nil ? 0 : 72)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.tofuBackground)
            .toolbarBackground(Color.tofuBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationTitle("レジ")
            .syncToolbar(model)
            .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完了") { manualFocused = false } } }
            .overlay(alignment: .bottom) { if let toast { toastView(toast) } }
            .onChange(of: quantity) { _ in choice = .exact; manualText = "" }
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
            moneyButton("ちょうど", selected: { if case .exact = choice { return true }; return false }(), enabled: true) { choice = .exact }
            ForEach(QuickSale.presets, id: \.self) { value in
                moneyButton(Yen.format(value), selected: { if case .preset(let v) = choice { return v == value }; return false }(),
                            enabled: value >= (total ?? 0)) { choice = .preset(value) }
            }
            moneyButton("手入力", selected: { if case .manual = choice { return true }; return false }(), enabled: true) {
                choice = .manual; manualFocused = true
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
                Text(change.map { "¥\(Yen.format($0))" } ?? "不足").font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
            }
            .foregroundColor(toastDark)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.tofuTop))
            HStack {
                Text(change.map(QuickSale.changeNote) ?? "預り金が合計に足りません").foregroundColor(change == nil ? .red : .tofuMuted)
                Spacer()
                Text("預り ¥\(Yen.format(received ?? 0))").foregroundColor(.tofuMuted)
            }.font(.footnote).padding(.horizontal, 4)
        }
    }

    private func toastView(_ sale: Sale) -> some View {
        HStack(spacing: 12) {
            Text(QuickSale.savedText(sale)).font(.subheadline).foregroundColor(.white).fixedSize(horizontal: false, vertical: true)
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
            let customer = age == nil && gender == nil ? nil : Customer(age: age, gender: gender)
            let sale = try model.checkout(id: commandID, lines: [line], received: received, customer: customer)
            commandID = UUID().uuidString
            quantity = 1; choice = .exact; manualText = ""; age = nil; gender = nil
            model.refresh()
            show(sale)
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
