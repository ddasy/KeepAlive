import SwiftUI
import AppKit

// MARK: - 展示辅助
// 用量严重度只在这里定义一次：弹窗/悬停快照的用量条用 color，菜单栏倒计时的填充用 menuBarColor，
// 两处永远同一套阈值（<70% 绿 / <90% 橙 / 其余红）。
enum UsageSeverity {
    case unknown, normal, warning, critical

    static func of(_ pct: Double?) -> UsageSeverity {
        guard let p = pct else { return .unknown }
        if p < 70 { return .normal } else if p < 90 { return .warning } else { return .critical }
    }

    var color: Color {
        switch self {
        case .unknown: return .gray
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }

    var menuBarColor: NSColor {
        switch self {
        case .unknown: return .systemGray
        case .normal: return .systemGreen
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
    }
}

func sevColor(_ pct: Double?) -> Color { UsageSeverity.of(pct).color }
// 所有界面时刻都从 Store 获取时区；不改变底层 Date 或调度时长。
extension Store {
    var displayTimeZone: TimeZone { DisplayTimeZone.resolve(timeZoneSelection) }

    func formattedTime(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = displayTimeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    func localHM(_ date: Date) -> String { formattedTime(date, format: "HH:mm") }
    func localMDHM(_ date: Date) -> String { formattedTime(date, format: "MM-dd HH:mm") }
    func localMonthDayHM(_ date: Date) -> String { formattedTime(date, format: "M月d日 HH:mm") }

    // 成功记录保存 Date，切换时区时即时重绘，不能缓存带旧时区的时间字符串。
    func fireResultText(codex: Bool) -> String {
        let text = codex ? codexLastFireResult : lastFireResult
        let reset = codex ? codexLastFireResultReset : lastFireResultReset
        return reset.map { text + "：新窗口 \(fmt($0)) 重置" } ?? text
    }
}
// 用量条。刻意不用 ProgressView：它在 macOS 上是 NSProgressIndicator 包出来的 AppKit 控件，
// 颜色跟着**窗口的 key/active 状态**走——悬停快照那个面板故意不抢焦点、永远不是 key 窗口，
// 于是 .tint 会被系统灰掉，和点开的弹窗对不上。纯 SwiftUI 图形没有这个包袱，两处渲染完全一致。
struct UsageBar: View {
    let value: Double        // 0…1
    let color: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.14))
                Capsule().fill(color)
                    .frame(width: max(0, min(1, value)) * g.size.width)
            }
        }
        .frame(height: 6)
    }
}

extension Store {
    func resetInfo(_ reset: Date?, _ now: Date) -> String {
        guard let r = reset else { return "重置 —" }
        let rem = r.timeIntervalSince(now)
        return rem >= 0 ? "重置 \(localHM(r))（剩余时间 \(Store.dhm(rem))）"
                        : "重置 \(localHM(r))（已过 \(Store.dhm(-rem))）"
    }

    // 周限专用：重置往往在好几天后，只给 HH:mm 根本看不出是哪天 → 带上月日，例：重置8月5日 13:22（剩余3d 9h 42m）
    func weeklyResetInfo(_ reset: Date?, _ now: Date) -> String {
        guard let r = reset else { return "重置 —" }
        let rem = r.timeIntervalSince(now)
        return rem >= 0 ? "重置\(localMonthDayHM(r))（剩余\(Store.dhm(rem))）"
                        : "重置\(localMonthDayHM(r))（已过\(Store.dhm(-rem))）"
    }

}
