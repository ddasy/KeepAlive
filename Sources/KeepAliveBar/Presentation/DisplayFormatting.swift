import SwiftUI

// MARK: - 展示辅助
func sevColor(_ pct: Double?) -> Color {
    guard let p = pct else { return .gray }
    if p < 70 { return .green } else if p < 90 { return .orange } else { return .red }
}
func localHM(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d) }
func localMDHM(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"; return f.string(from: d) }
func localMonthDayHM(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "M月d日 HH:mm"; return f.string(from: d) }
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
