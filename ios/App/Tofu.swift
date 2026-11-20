import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// 2026「Are you Tofu?」palette (Assets.xcassets color sets, light/dark).
extension Color {
    static let tofuBackground = Color("TofuBackground")
    static let tofuCard = Color("TofuCard")
    static let tofuText = Color("TofuText")
    static let tofuOnAccent = Color("TofuOnAccent")
    static let tofuSoft = Color("TofuSoft")
    static let tofuSoftText = Color("TofuSoftText")
    static let tofuMuted = Color("TofuMuted")
    static let tofuTop = Color("TofuTop")
}

private struct TestEnvironmentKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// True while the app runs against the test environment; every top bar then turns orange.
    var isTestEnvironment: Bool {
        get { self[TestEnvironmentKey.self] }
        set { self[TestEnvironmentKey.self] = newValue }
    }
}

/// Navigation bar color: paper normally, orange in the test environment.
struct TofuBar: ViewModifier {
    @Environment(\.isTestEnvironment) private var test
    func body(content: Content) -> some View {
        content
            .toolbarBackground(test ? Color.orange.opacity(0.45) : Color.tofuBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            // Inline titles keep the top compact; toolbar items (sync, test badge, export) stay.
            .navigationBarTitleDisplayMode(.inline)
    }
}

struct TestBadge: View {
    @Environment(\.isTestEnvironment) private var test
    var body: some View {
        if test {
            Text("テスト").font(.caption.bold()).foregroundColor(.white)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.red))
                .accessibilityLabel("テスト環境")
        }
    }
}

/// iPad (regular width) and Mac use the wide layouts; iPhone never does, even a Max in landscape.
struct WideLayout {
    @MainActor static func isWide(_ sizeClass: UserInterfaceSizeClass?) -> Bool {
        #if canImport(UIKit)
        return sizeClass == .regular && UIDevice.current.userInterfaceIdiom != .phone
        #else
        return false
        #endif
    }
    static let readableWidth: CGFloat = 640
}

private struct OptionalReadableWidth: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.modifier(ReadableWidth()) } else { content }
    }
}

/// Centers content at a readable width on iPad/Mac; no change on iPhone.
struct ReadableWidth: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass
    func body(content: Content) -> some View {
        if WideLayout.isWide(sizeClass) {
            content.frame(maxWidth: WideLayout.readableWidth).frame(maxWidth: .infinity)
        } else {
            content
        }
    }
}

extension View {
    /// Paper background behind lists/forms; rows use the card color via `tofuRows()`. `fullWidth` skips the
    /// iPad/Mac readable-width centering (the two-column register).
    func tofuSurface(fullWidth: Bool = false) -> some View {
        scrollContentBackground(.hidden)
            .modifier(OptionalReadableWidth(enabled: !fullWidth))
            .background(Color.tofuBackground)
            .modifier(TofuBar())
    }
    func readableWidth() -> some View { modifier(ReadableWidth()) }
    func tofuRows() -> some View { listRowBackground(Color.tofuCard) }
    /// Sync status icon at the top right of every main screen, plus the test badge at the top left.
    func syncToolbar(_ model: RegisterModel) -> some View {
        toolbar {
            ToolbarItem(placement: .navigationBarLeading) { TestBadge() }
            ToolbarItem(placement: .primaryAction) {
                if let sync = model.sync { SyncStatusButton(controller: sync) }
            }
        }
    }
}

/// Same outline as shared/branding/tofu-mark.svg: a rounded hexagon (white top) with the #FFE8A9 side
/// face clipped to it. Paths are the SVG's source coordinates, fitted to the body's bounds.
struct TofuShape: Shape {
    enum Part { case body, side }
    let part: Part
    private static let body = "M 708.996094 1351.054688 C 708.042969 1350.503906 706.484375 1350.503906 705.535156 1351.054688 L 679.222656 1366.246094 C 678.269531 1366.796875 677.492188 1368.144531 677.492188 1369.246094 L 677.492188 1399.625 C 677.492188 1400.726562 678.269531 1402.074219 679.222656 1402.625 L 705.535156 1417.816406 C 706.484375 1418.363281 708.042969 1418.363281 708.996094 1417.816406 L 735.308594 1402.625 C 736.257812 1402.074219 737.039062 1400.726562 737.039062 1399.625 L 737.039062 1369.246094 C 737.039062 1368.144531 736.257812 1366.796875 735.308594 1366.246094 Z"
    private static let side = "M 739.023438 1368.261719 C 738.046875 1367.699219 736.453125 1367.699219 735.476562 1368.261719 L 708.546875 1383.808594 C 707.574219 1384.371094 706.773438 1385.753906 706.773438 1386.878906 L 706.773438 1417.976562 C 706.773438 1419.101562 707.574219 1420.480469 708.546875 1421.042969 L 735.476562 1436.59375 C 736.453125 1437.15625 738.046875 1437.15625 739.023438 1436.59375 L 765.953125 1421.042969 C 766.925781 1420.480469 767.722656 1419.101562 767.722656 1417.976562 L 767.722656 1386.878906 C 767.722656 1385.753906 766.925781 1384.371094 765.953125 1383.808594 Z"
    private static func parse(_ data: String) -> Path {
        var path = Path()
        var tokens = data.split(separator: " ").map(String.init)[...]
        func point() -> CGPoint {
            let x = Double(tokens.popFirst() ?? "0") ?? 0, y = Double(tokens.popFirst() ?? "0") ?? 0
            return CGPoint(x: x, y: y)
        }
        while let command = tokens.popFirst() {
            switch command {
            case "M": path.move(to: point())
            case "L": path.addLine(to: point())
            case "C": let c1 = point(), c2 = point(); path.addCurve(to: point(), control1: c1, control2: c2)
            default: path.closeSubpath()
            }
        }
        return path
    }
    private static let bodyPath = parse(body)
    private static let sidePath = parse(side)
    func path(in rect: CGRect) -> Path {
        let bounds = Self.bodyPath.boundingRect
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        let transform = CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -bounds.midX, y: -bounds.midY)
        return (part == .body ? Self.bodyPath : Self.sidePath).applying(transform)
    }
}

struct TofuMark: View {
    var body: some View {
        ZStack {
            TofuShape(part: .body).fill(Color.white)
            TofuShape(part: .side).fill(Color.tofuTop).clipShape(TofuShape(part: .body))
            TofuShape(part: .body).stroke(Color.tofuMuted.opacity(0.6), lineWidth: 1)
        }.aspectRatio(59.5 / 67.3, contentMode: .fit)
    }
}

/// Loading indicator: the tofu squashes (scale Y 1.0↔0.85, 0.8s cycle); static with Reduce Motion.
struct TofuLoading: View {
    var size: CGFloat = 28
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var squash = false
    var body: some View {
        TofuMark()
            .frame(width: size, height: size)
            .scaleEffect(x: 1, y: squash ? 0.85 : 1, anchor: .bottom)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true)) { squash = true }
            }
            .accessibilityLabel("読み込み中")
    }
}

struct SyncStatusButton: View {
    @ObservedObject var controller: CloudSyncController
    @State private var showing = false
    private var warning: Bool {
        controller.failed || controller.held > 0 || controller.conflicts > 0 || controller.rejectedImages > 0
            || controller.rejected.products + controller.rejected.stock + controller.rejected.sessions > 0
    }
    var body: some View {
        Button { showing = true } label: {
            if controller.isSyncing {
                TofuLoading(size: 22)
            } else if !controller.configured {
                Image(systemName: "icloud.slash")
            } else if warning {
                IconImage(icon: .asset("IconSyncError")).foregroundColor(.red)
            } else if controller.pending > 0 {
                IconImage(icon: .asset("IconSyncPending"))
                    .overlay(alignment: .topTrailing) {
                        Text(controller.pending > 99 ? "99+" : "\(controller.pending)")
                            .font(.caption2.bold()).foregroundColor(.tofuOnAccent)
                            .padding(.horizontal, 4).background(Capsule().fill(Color.accentColor)).offset(x: 10, y: -8)
                    }
            } else {
                IconImage(icon: .asset("IconSyncDone"))
            }
        }
        .accessibilityLabel(controller.pending > 0 ? "未同期 \(controller.pending)件" : "同期済み")
        .sheet(isPresented: $showing) { SyncSheet(controller: controller) }
    }
}

struct SyncSheet: View {
    @ObservedObject var controller: CloudSyncController
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Group {
                    if controller.environment == .test {
                        Section { Label("テスト環境", systemImage: "exclamationmark.triangle.fill").foregroundColor(.red) }
                    }
                    Section {
                        HStack {
                            Text(controller.pending == 0 ? "同期済み" : "未同期 \(controller.pending)件").font(.title3.bold())
                            Spacer()
                            if controller.isSyncing { TofuLoading() }
                        }
                        LabeledContent("最終送信", value: controller.lastSyncAt.map(jstTime) ?? "まだありません")
                        LabeledContent("最終取り込み", value: controller.lastFeedAt.map(jstTime) ?? "まだありません")
                        Text(controller.message).font(.callout)
                    }
                    if controller.held + controller.conflicts + controller.rejectedImages + controller.rejected.products + controller.rejected.stock + controller.rejected.sessions > 0 {
                        Section("保留") {
                            if controller.held > 0 { Text("サイズ超過の会計 \(controller.held)件") }
                            if controller.conflicts > 0 { Text("競合した会計 \(controller.conflicts)件") }
                            if controller.rejected.products > 0 { Text("送信できなかった商品 \(controller.rejected.products)件") }
                            if controller.rejected.stock > 0 { Text("送信できなかった在庫 \(controller.rejected.stock)件") }
                            if controller.rejected.sessions > 0 { Text("送信できなかったレジ記録 \(controller.rejected.sessions)件") }
                            if controller.rejectedImages > 0 { Text("送信できなかった写真 \(controller.rejectedImages)件") }
                        }.foregroundColor(.red)
                    }
                    Section {
                        HStack {
                            if controller.isSyncing { TofuLoading().frame(minWidth: 44, minHeight: 44) }
                            else { IconButton("今すぐ送信", .asset("IconSyncPending")) { Task { await controller.run() } }.disabled(!controller.configured) }
                            Spacer()
                            NavigationLink { CloudSyncView(controller: controller) } label: { IconImage(icon: .asset("IconSettings")).foregroundColor(.tofuMuted) }
                                .frame(minWidth: 44, minHeight: 44).fixedSize()
                                .accessibilityLabel("詳細設定").help("詳細設定")
                        }
                    }
                }.tofuRows()
            }
            .tofuSurface()
            .navigationTitle("同期")
            .toolbar { ToolbarItem(placement: .cancellationAction) { IconButton("閉じる", .symbol("xmark")) { dismiss() } } }
        }
    }
}

#if canImport(UIKit)
private let photoCache = NSCache<NSString, UIImage>()
#endif

/// Product photo (rounded) or the tofu mark when there is none or the file is not fetched yet.
struct ProductPhoto: View {
    let images: ProductImages?
    let hash: String?
    var size: CGFloat = 40
    var corner: CGFloat = 8
    var body: some View {
        if let image = loaded() {
            image.resizable().scaledToFill().frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: corner))
        } else {
            TofuMark().frame(width: size, height: size)
        }
    }
    private func loaded() -> Image? {
        #if canImport(UIKit)
        guard let images, let hash, images.exists(hash) else { return nil }
        if let cached = photoCache.object(forKey: hash as NSString) { return Image(uiImage: cached) }
        guard let data = images.data(hash), let image = UIImage(data: data) else { return nil }
        photoCache.setObject(image, forKey: hash as NSString)
        return Image(uiImage: image)
        #else
        return nil
        #endif
    }
}

/// Re-encodes a picked photo: orientation applied, long edge ≤ 800px, JPEG quality 0.8. Drawing into a new
/// bitmap drops the original EXIF/GPS metadata.
enum PhotoProcessing {
    static func jpeg(from data: Data) throws -> Data {
        #if canImport(UIKit)
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { throw POSFailure.invalid("画像を読み込めません") }
        let fitted = ProductImages.fitted(width: Int(image.size.width * image.scale), height: Int(image.size.height * image.scale))
        let size = CGSize(width: fitted.width, height: fitted.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        for quality in [0.8, 0.6, 0.4] as [CGFloat] {
            if let jpeg = rendered.jpegData(compressionQuality: quality), jpeg.count <= ProductImages.maxBytes { return jpeg }
        }
        throw POSFailure.invalid("写真が大きすぎます")
        #else
        throw POSFailure.invalid("この環境では写真を扱えません")
        #endif
    }
}

/// Mac Catalyst: a minimum window size so the wide layouts always fit.
enum MacWindow {
    @MainActor static func configure() {
        #if targetEnvironment(macCatalyst)
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.sizeRestrictions?.minimumSize = CGSize(width: 900, height: 640)
        }
        #endif
    }
}

/// Icon-only button: shop icon from Assets.xcassets (template SVG) or an SF Symbol, ≥44pt target,
/// VoiceOver label, pointer hover name (.help) and the name in the long-press menu.
struct IconButton: View {
    enum Icon { case asset(String), symbol(String) }
    let label: String
    let icon: Icon
    var role: ButtonRole?
    let action: () -> Void
    init(_ label: String, _ icon: Icon, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.label = label; self.icon = icon; self.role = role; self.action = action
    }
    var body: some View {
        Button(role: role, action: action) {
            // Only destructive buttons force a color, so callers can tint the others (e.g. the toast's undo).
            if role == .destructive {
                IconImage(icon: icon).foregroundColor(.red).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            } else {
                IconImage(icon: icon).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
        }
            .buttonStyle(.borderless)  // several icon buttons can share one list row
            .accessibilityLabel(label)
            .help(label)
            .contextMenu { Button(role: role, action: action) { Text(label) } }
    }
}

struct IconImage: View {
    let icon: IconButton.Icon
    var size: CGFloat = 24
    var body: some View {
        switch icon {
        case .asset(let name): Image(name).renderingMode(.template).resizable().scaledToFit().frame(width: size, height: size)
        case .symbol(let name): Image(systemName: name).font(.system(size: size * 0.8, weight: .semibold))
        }
    }
}
