import SwiftUI

// 卡片式开关：不再使用系统滑轨。整张卡片/整行都是点击区域，开启时以轻量强调色和勾选标记反馈。
// 仍然只修改传入的 Binding，具体副作用（例如 SMAppService）继续由 Binding 的 setter 负责。
struct ToggleCheckmark: View {
    let isOn: Bool
    var compact = false

    var body: some View {
        ZStack {
            Circle()
                .fill(isOn ? Color.accentColor : Color.primary.opacity(0.055))
            Circle()
                .strokeBorder(isOn ? Color.accentColor : Color.secondary.opacity(0.28), lineWidth: 1)
            if isOn {
                Image(systemName: "checkmark")
                    .font(.system(size: compact ? 8 : 9, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: compact ? 18 : 22, height: compact ? 18 : 22)
    }
}

struct KeepAliveToggleCard: View {
    let title: String
    let mark: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) { isOn.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Text(mark)
                        .font(.caption2.weight(.semibold).monospaced())
                        .foregroundStyle(isOn ? Color.white : Color.secondary)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isOn ? Color.accentColor : Color.primary.opacity(0.075))
                        )
                    Spacer(minLength: 8)
                    ToggleCheckmark(isOn: isOn)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.caption.weight(.semibold))
                    Text(isOn ? "正在保活" : "已关闭")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isOn ? Color.accentColor.opacity(0.095) : Color.primary.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isOn ? Color.accentColor.opacity(0.38) : Color.secondary.opacity(0.18), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) 保活")
        .accessibilityValue(isOn ? "已开启" : "已关闭")
    }
}

struct SettingsToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) { isOn.toggle() }
        } label: {
            HStack(spacing: 10) {
                Text(title).font(.caption)
                Spacer()
                ToggleCheckmark(isOn: isOn, compact: true)
            }
            .padding(.horizontal, 11)
            .frame(height: 42)
            .background(isOn ? Color.accentColor.opacity(0.055) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "已开启" : "已关闭")
    }
}

// 下半部分：开关、按钮、上次保活结果 —— 只出现在点击弹窗里，悬停快照不含这些
struct ControlSections: View {
    @EnvironmentObject var s: Store

    // 只在“被周限拦下”时给一行说明——否则用户会以为保活坏了。平时不占位。
    var blockedText: String? {
        if s.paused { return "已暂停（点“恢复”继续监控与续窗）" }
        var who: [String] = []
        if s.claudeAutoEnabled, s.claudeWeeklyBlocked { who.append("Claude") }
        if s.codexAutoEnabled, s.codexWeeklyBlocked { who.append("Codex") }
        guard !who.isEmpty else { return nil }
        return "\(who.joined(separator: " / ")) 周限已用尽，暂不保活（周重置后自动恢复）"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let t = blockedText {
                Text(t).font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("保活")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                HStack(spacing: 8) {
                    KeepAliveToggleCard(title: "Claude", mark: "C", isOn: $s.claudeAutoEnabled)
                    KeepAliveToggleCard(title: "Codex", mark: ">_", isOn: $s.codexAutoEnabled)
                }
                HStack(spacing: 10) {
                    Text("交叉保活").font(.caption)
                    Spacer(minLength: 0)
                    Menu {
                        ForEach(Array(stride(from: 30, through: 145, by: 5)), id: \.self) { minutes in
                            Button {
                                s.crossIntervalMinutes = Double(minutes)
                            } label: {
                                if Int(s.crossIntervalMinutes) == minutes {
                                    Label("\(minutes) 分钟", systemImage: "checkmark")
                                } else {
                                    Text("\(minutes) 分钟")
                                }
                            }
                        }
                    } label: {
                        Text("间隔＞\(Int(s.crossIntervalMinutes)) 分钟").font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("交叉保活间隔")
                    .accessibilityValue("大于 \(Int(s.crossIntervalMinutes)) 分钟")
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            s.crossKeepaliveEnabled.toggle()
                        }
                    } label: {
                        ToggleCheckmark(isOn: s.crossKeepaliveEnabled, compact: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("交叉保活")
                    .accessibilityValue(s.crossKeepaliveEnabled ? "已开启" : "已关闭")
                }
                .padding(.horizontal, 11)
                .frame(height: 42)
                .background(s.crossKeepaliveEnabled ? Color.accentColor.opacity(0.055) : Color.clear)
                if s.crossKeepaliveEnabled {
                    Text(s.crossStatus)
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("应用")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                VStack(spacing: 0) {
                    SettingsToggleRow(title: "开机自启", isOn: Binding(
                        get: { s.launchAtLogin },
                        set: { s.setLaunchAtLogin($0) }
                    ))
                    Divider().padding(.leading, 11)
                    SettingsToggleRow(title: "自动查询", isOn: $s.autoQueryOnOpen)
                    Divider().padding(.leading, 11)
                    SettingsToggleRow(title: "自动排序", isOn: $s.automaticSorting)
                        .help("优先显示 5 小时内较早到期的 AI；用满后切换到仍有额度的 AI。关闭后恢复手动顺序。")
                    Divider().padding(.leading, 11)
                    SettingsToggleRow(title: "隐藏倒计时", isOn: $s.hideCountdown)
                }
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.035))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            HStack(spacing: 8) {
                Button(s.paused ? "恢复" : "暂停") { s.togglePause() }
                Button("刷新") { s.refreshNow() }.disabled(s.paused)
                if s.busyFiring {
                    Text("保活中…").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
            }

            if !s.lastFireResult.isEmpty {
                Text(s.lastFireResult).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            if let lf = s.lastFire {
                Text("上次 Claude 保活：\(localMDHM(lf))").font(.caption2).foregroundStyle(.secondary)
            }
            if let lf = s.codexLastFire {
                Text("上次 Codex 保活：\(localMDHM(lf))").font(.caption2).foregroundStyle(.secondary)
            }
            if !s.codexLastFireResult.isEmpty {
                Text(s.codexLastFireResult).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            if let e = s.lastError {
                Text(e).font(.caption2).foregroundStyle(.red).lineLimit(2)
            }
        }
    }
}
