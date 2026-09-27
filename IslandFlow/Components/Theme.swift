import SwiftUI

/// 間距與圓角。旅客端畫面一律用這組數字，避免每頁各自為政。
enum Space {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

enum Radius {
    static let card: CGFloat = 20
    static let control: CGFloat = 14
}

/// 旅客端主要按鈕：整排、夠高、一眼知道「下一步按這裡」
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, Space.l)
            .background(isEnabled ? Color.brand : Color.secondary.opacity(0.3),
                        in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .foregroundStyle(.white)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, Space.m)
            .background(Color.brand.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .foregroundStyle(Color.brand)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondaryAction: SecondaryButtonStyle { SecondaryButtonStyle() }
}

/// 大字級（輔助使用尺寸）時改直排。標籤和金額刻意不折行，橫排在大字級會把整頁撐出螢幕
struct AdaptiveStack<Content: View>: View {
    var spacing: CGFloat = Space.s
    @ViewBuilder var content: Content
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: spacing) { content }
        } else {
            HStack(spacing: spacing) { content }
        }
    }
}

/// 橫排時才需要的彈性空白；直排時放 Spacer 會多出一大段空白
struct HSpacer: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        if !typeSize.isAccessibilitySize { Spacer(minLength: Space.s) }
    }
}

/// 旅客看的是「坐起來舒不舒服」，不是載客率百分比；百分比只放詳情的展開區與管理端
extension LoadTier {
    var comfortLabel: String {
        switch self {
        case .low: "空位多・較舒適"
        case .mid: "座位普通"
        case .high: "較擁擠"
        }
    }

    var comfortShort: String {
        switch self {
        case .low: "較舒適"
        case .mid: "普通"
        case .high: "較擁擠"
        }
    }
}

struct ComfortChip: View {
    var tier: LoadTier
    var short = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let (fg, bg): (Color, Color) = switch tier {
        case .low: (Color.brand, Color.brand.opacity(0.12))
        case .mid: (Color.secondary, Color.secondary.opacity(0.12))
        case .high: (Color.orange, Color.orange.opacity(0.14))
        }
        // 大字級時完整版「空位多・較舒適」單獨就比卡片寬，改用短版
        Label(short || typeSize.isAccessibilitySize ? tier.comfortShort : tier.comfortLabel, systemImage: tier.symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, Space.s).padding(.vertical, Space.xs)
            .background(bg, in: Capsule())
            .foregroundStyle(fg)
            .lineLimit(1)
            .fixedSize()
    }
}

extension Color {
    static let brand = Color.accentColor
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let canvas = Color(uiColor: .systemGroupedBackground)
    /// sheet 裡的區塊底色。sheet 本身是白底，用 surface 會白上加白看不出區塊
    static let inset = Color(uiColor: .secondarySystemBackground)
    /// 旅綠幣的金色。深色模式下調亮，確保在深底上仍有對比
    static let coin = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark ? UIColor(red: 1.0, green: 0.82, blue: 0.36, alpha: 1)
                                      : UIColor(red: 0.78, green: 0.55, blue: 0.05, alpha: 1)
    })
}

enum Fmt {
    static func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
    static func pct(_ v: Double?) -> String { v.map { pct($0) } ?? "—" }
    static func ntd(_ v: Double) -> String { "NT$" + v.formatted(.number.precision(.fractionLength(0))) }
    static func ntd(_ v: Double?) -> String { v.map { ntd($0) } ?? "—" }
    static func kg(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(1))) + " kg" }
    static func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
    static func dateTime(_ d: Date) -> String { d.formatted(.dateTime.month().day().hour().minute()) }
}

/// 「示範資料」標籤。規格要求所有模擬數字都不能省略這個標示。
struct DemoBadge: View {
    var text = "示範資料"
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.orange.opacity(0.16), in: Capsule())
            .foregroundStyle(Color.orange)
            .accessibilityLabel("標示：\(text)")
    }
}

struct OpenDataBadge: View {
    var text = "開放資料"
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.blue.opacity(0.14), in: Capsule())
            .foregroundStyle(Color.blue)
    }
}

struct CoinLabel: View {
    var amount: Int
    var font: Font = .headline
    var showSign = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "leaf.circle.fill").foregroundStyle(Color.coin)
            Text("\(showSign && amount > 0 ? "+" : "")\(amount)")
                .monospacedDigit()
                .fontWeight(.bold)
            Text("枚").font(.caption).foregroundStyle(.secondary)
        }
        .font(font)
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(amount) 枚旅綠幣")
    }
}

/// 載客率標示：顏色之外一定附圖示與文字，不只靠顏色辨識
struct LoadBadge: View {
    var load: Double
    var tier: LoadTier

    var color: Color {
        switch tier {
        case .low: .green
        case .mid: .orange
        case .high: .red
        }
    }

    var body: some View {
        Label("\(tier.label) \(Fmt.pct(load))", systemImage: tier.symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .accessibilityLabel("預估載客率 \(Fmt.pct(load))，\(tier.label)")
    }
}

struct LoadBar: View {
    var load: Double
    var tier: LoadTier

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule().fill(LoadBadge(load: load, tier: tier).color)
                    .frame(width: max(6, geo.size.width * min(1, load)))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}

struct ErrorBanner: View {
    var message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.subheadline)
            .foregroundStyle(.red)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct CountdownText: View {
    var until: Date
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let left = max(0, Int(until.timeIntervalSince(ctx.date)))
            Text(left > 0 ? String(format: "%d:%02d 後失效", left / 60, left % 60) : "已失效")
                .monospacedDigit()
                .foregroundStyle(left > 30 ? Color.secondary : Color.red)
        }
    }
}
