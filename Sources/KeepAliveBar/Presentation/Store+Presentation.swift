import Foundation

extension Store {
    var displayedCodexFirst: Bool {
        guard automaticSorting else { return codexFirst }
        return AutomaticOrder.codexFirst(current: codexFirst, now: now,
            claudeEnd: fiveReset ?? windowEnd, claudeUsed: fivePct,
            codexEnd: codexWindowClosed ? nil : codexPrimaryReset,
            codexUsed: codexWindowClosed ? 0 : codexPrimaryUsed)
    }

    // 菜单栏标题与图标共用 displayedCodexFirst，始终显示置顶 AI 的 5h 窗口。
    // 返回 "" 表示“菜单栏只留图标”（隐藏倒计时）；暂停态仍保留 ⏸——它是运行状态而非刷新时间，
    // 否则关掉保活后菜单栏毫无痕迹，容易忘了自己按过暂停。
    var loginExpiryWarning: Bool {
        LoginExpiry.needsReminder(claudeLoginExpiresAt, now: now)
    }

    var menuTitle: String {
        let title = countdownTitle
        guard loginExpiryWarning else { return title }
        return title.isEmpty ? "⚠︎" : "⚠︎ " + title
    }

    // 菜单栏倒计时的填充比例：必须与弹窗里那张卡片上置顶 AI 的 5h 用量条**逐字一致**——
    // Claude 用 fivePct，Codex 照抄 codexRow 的算法（只有快照过期 reset<=now 才归零；
    // codexWindowClosed 只改卡片上的说明文字，不动百分比）。没有数据返回 nil＝不填充。
    var menuUsagePercent: Double? {
        guard displayedCodexFirst else { return fivePct }
        let rolledOff = codexPrimaryReset.map { $0 <= now } ?? false
        return rolledOff ? 0 : codexPrimaryUsed
    }

    private var countdownTitle: String {
        if paused { return "⏸" }
        if hideCountdown { return "" }
        let codex = displayedCodexFirst
        if let until = crossWaitUntil(claude: !codex), codex ? codexIsDue : claudeIsDue {
            return "↔ " + Store.hhmm(until.timeIntervalSince(now))
        }
        if codex && codexWindowClosed { return "now" }
        guard let end = codex ? codexPrimaryReset : windowEnd else { return "–" }
        let rem = end.timeIntervalSince(now)
        return rem <= 0 ? "now" : Store.hhmm(rem)       // 已过末尾 → "now"（等待续窗）
    }

    nonisolated static func hhmm(_ s: TimeInterval) -> String {
        let t = Int(max(0, s)); let h = t / 3600; let m = (t % 3600) / 60
        return h > 0 ? "\(h)h\(String(format: "%02d", m))m" : "\(m)m"
    }

    // 剩余时间：空格分隔，只从最高非零单位起显示（如 30m / 1h 35m / 1d 5h 55m）
    nonisolated static func dhm(_ s: TimeInterval) -> String {
        let t = Int(max(0, s))
        let d = t / 86400, h = (t % 86400) / 3600, m = (t % 3600) / 60
        if d > 0 { return "\(d)d \(h)h \(m)m" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}
