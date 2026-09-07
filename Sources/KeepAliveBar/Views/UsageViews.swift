import SwiftUI

// MARK: - 弹窗界面
// 弹窗被拆成两块，方便悬停快照直接复用上半部分：
//   · UsageSections —— Claude / Codex 用量；主弹窗可排序，悬停快照只展示。
//   · ControlSections —— 开关、按钮、上次保活结果等“操作与诊断”。
// 主弹窗 = UsageSections + ControlSections；悬停快照 = UsageSections（见 SnapshotView）。
// 两者共用同一份渲染代码，改一处两边同步，绝不会出现“快照和弹窗对不上”。
struct UsageSections: View {
    @EnvironmentObject var s: Store
    var allowsReordering = false
    @State private var selectedCodex: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(s.displayedCodexFirst ? [true, false] : [false, true], id: \.self) { codex in
                if codex != s.displayedCodexFirst { Divider() }
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader(codex: codex)
                    if codex {
                        codexRow("5 小时", s.codexPrimaryUsed, s.codexPrimaryReset, withDate: false, closed: s.codexWindowClosed)
                        codexRow("周限", s.codexWeeklyUsed, s.codexWeeklyReset, withDate: true)
                    } else {
                        usageRow("5小时", s.fivePct, s.fiveReset)
                        usageRow("周限", s.sevenPct, s.sevenReset, weekly: true)
                        if s.opusPct != nil { usageRow("周 · Opus", s.opusPct, s.opusReset, weekly: true) }
                        if s.sonnetPct != nil { usageRow("周 · Sonnet", s.sonnetPct, s.sonnetReset, weekly: true) }
                    }
                }
            }
        }
        .onDisappear { selectedCodex = nil }
    }

    private func sectionHeader(codex: Bool) -> some View {
        let title = codex ? "Codex" : "Claude"
        let isFirst = codex == s.displayedCodexFirst
        return HStack(spacing: 6) {
            if allowsReordering && !s.automaticSorting {
                Button {
                    selectedCodex = selectedCodex == codex ? nil : codex
                } label: {
                    HStack {
                        Text(title).font(.headline)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("点击调整 \(title) 的位置")
                .accessibilityLabel("\(title)，调整顺序")
                if selectedCodex == codex {
                    moveButton(title: title, up: true, enabled: !isFirst)
                    moveButton(title: title, up: false, enabled: isFirst)
                }
            } else {
                Text(title).font(.headline)
                Spacer()
            }
        }
    }

    private func moveButton(title: String, up: Bool, enabled: Bool) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) { s.codexFirst.toggle() }
        } label: {
            Image(systemName: up ? "chevron.up" : "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help("将 \(title)\(up ? "上移" : "下移")")
        .accessibilityLabel("将 \(title)\(up ? "上移" : "下移")")
    }

    @ViewBuilder
    func usageRow(_ title: String, _ pct: Double?, _ reset: Date?, weekly: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline).bold()
                Spacer()
                Text(pct == nil ? "—" : "\(Int(pct!.rounded()))%")
                    .font(.subheadline).foregroundStyle(sevColor(pct))
            }
            UsageBar(value: (pct ?? 0) / 100, color: sevColor(pct))
            Text(weekly ? weeklyResetInfo(reset, s.now) : resetInfo(reset, s.now))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // Codex 行：已用百分比 + 重置时间（withDate=true 时带日期，如 7月8日 04:59）。
    // 口径与上面 Claude 的 usageRow 保持一致：数字＝已用，进度条＝已用比例。
    @ViewBuilder
    func codexRow(_ title: String, _ used: Double?, _ reset: Date?, withDate: Bool,
                  closed: Bool = false) -> some View {
        let rolledOff = reset.map { $0 <= s.now } ?? false
        let usedNow = rolledOff ? 0 : (used ?? 0)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline).bold()
                Spacer()
                Text(used == nil ? "—" : "\(Int(usedNow.rounded()))%")
                    .font(.subheadline).foregroundStyle(sevColor(usedNow))
            }
            UsageBar(value: usedNow / 100, color: sevColor(usedNow))
            if closed {
                // wham/usage 说得很明确：当前没有活动窗口（reset_at 还在随时间滚动）
                Text("当前无活动窗口，下次保活将开启新窗口").font(.caption2).foregroundStyle(.secondary)
            } else if rolledOff {
                Text("已重置（快照过期，无实时数据）").font(.caption2).foregroundStyle(.secondary)
            } else if let r = reset {
                Text(withDate ? weeklyResetInfo(r, s.now) : resetInfo(r, s.now))
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("暂无快照").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
