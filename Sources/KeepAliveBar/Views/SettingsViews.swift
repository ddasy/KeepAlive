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

// 首页仅显示快捷操作和错误；保活记录与一般状态放在设置中。
struct ControlSections: View {
    @EnvironmentObject var s: Store
    var settingsExpanded: Bool
    var openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FeatureControls(hidden: false)

            HStack(spacing: 8) {
                Button(s.paused ? "恢复" : "暂停") { s.togglePause() }
                Button("刷新") { s.refreshNow() }.disabled(s.paused)
                Button("设置", action: openSettings)
                .accessibilityLabel(settingsExpanded ? "收起设置" : "展开设置")
                .accessibilityValue(settingsExpanded ? "已展开" : "已收起")
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
            }

            if s.lastFireFailed, !s.lastFireResult.isEmpty {
                Text(s.lastFireResult).font(.caption2).foregroundStyle(.red)
            }
            if s.codexLastFireFailed, !s.codexLastFireResult.isEmpty {
                Text(s.codexLastFireResult).font(.caption2).foregroundStyle(.red)
            }
            if let e = s.lastError {
                Text(e).font(.caption2).foregroundStyle(.red)
            }
        }
    }
}

struct FeatureControls: View {
    @EnvironmentObject var s: Store
    var hidden: Bool

    private func includes(_ control: MenuControl) -> Bool {
        s.menuControls(hidden: hidden).contains(control)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if includes(.claude) || includes(.codex) || includes(.cross) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("保活")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                    HStack(spacing: 8) {
                        if includes(.claude) {
                            KeepAliveToggleCard(title: "Claude", mark: "C", isOn: $s.claudeAutoEnabled)
                        }
                        if includes(.codex) {
                            KeepAliveToggleCard(title: "Codex", mark: ">_", isOn: $s.codexAutoEnabled)
                        }
                    }
                    if includes(.cross) {
                        HStack(spacing: 10) {
                            Text("交叉保活").font(.caption)
                            Spacer(minLength: 0)
                            Menu {
                                Button {
                                    s.crossCentered = true
                                } label: {
                                    if s.crossCentered {
                                        Label("居中", systemImage: "checkmark")
                                    } else {
                                        Text("居中")
                                    }
                                }
                                Divider()
                                ForEach(Array(stride(from: 30, through: 145, by: 5)), id: \.self) { minutes in
                                    Button {
                                        s.crossCentered = false
                                        s.crossIntervalMinutes = Double(minutes)
                                    } label: {
                                        if !s.crossCentered && Int(s.crossIntervalMinutes) == minutes {
                                            Label("\(minutes) 分钟", systemImage: "checkmark")
                                        } else {
                                            Text("\(minutes) 分钟")
                                        }
                                    }
                                }
                            } label: {
                                Text(s.crossCentered ? "居中" : "间隔＞\(Int(s.crossIntervalMinutes)) 分钟")
                                    .font(.caption)
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .accessibilityLabel("交叉保活间隔")
                            .accessibilityValue(s.crossCentered ? "居中，约 2 小时 30 分钟" : "大于 \(Int(s.crossIntervalMinutes)) 分钟")
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
                    }
                }

            }
            if [.login, .query, .sort, .countdown].contains(where: includes) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("应用")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                    VStack(spacing: 0) {
                        if includes(.login) {
                            SettingsToggleRow(
                                title: "开机自启",
                                isOn: Binding(
                                    get: { s.launchAtLogin },
                                    set: { s.setLaunchAtLogin($0) }
                                ))
                        }
                        if includes(.query) { SettingsToggleRow(title: "自动查询", isOn: $s.autoQueryOnOpen) }
                        if includes(.sort) {
                            SettingsToggleRow(title: "自动排序", isOn: $s.automaticSorting)
                                .help("优先显示 5 小时内较早到期的 AI；用满后切换到仍有额度的 AI。关闭后恢复手动顺序。")
                        }
                        if includes(.countdown) { SettingsToggleRow(title: "隐藏倒计时", isOn: $s.hideCountdown) }
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

            }
        }
    }
}

struct AppSettingsView: View {
    @EnvironmentObject var s: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !s.menuControls(hidden: true).isEmpty {
                Text("已隐藏的控件").font(.headline)
                FeatureControls(hidden: true)
                Divider()
            }
            Text("控件显示").font(.headline)
            Text("勾选后在上方显示；取消勾选则移入已隐藏的控件，不会关闭功能。")
                .font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(MenuControl.allCases) { control in
                    SettingsToggleRow(
                        title: control.title,
                        isOn: Binding(
                            get: { s.showsMenuControl(control) },
                            set: { s.setMenuControl(control, visible: $0) }))
                        .accessibilityLabel(control.title + "在首页显示")
                        .accessibilityValue(s.showsMenuControl(control) ? "已显示" : "已隐藏")
                }
            }
            Divider()
            if !s.crossKeepaliveEnabled {
                KeepaliveActivitySection()
                Divider()
            }
            Text("菜单栏进度条").font(.headline)
            Text("颜色深度越高，颜色越浓；0% 为透明。")
                .font(.caption).foregroundStyle(.secondary)
            opacitySlider("填充色", value: $s.menuBarFillOpacity)
            opacitySlider("底色", value: $s.menuBarTrackOpacity)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(s.menuBarTrackOpacity))
                Capsule().fill(Color.green.opacity(s.menuBarFillOpacity)).frame(width: 140)
            }
            .frame(height: 4)
            .accessibilityLabel("进度条颜色预览，已用约一半")
            Button("恢复默认深度") {
                s.menuBarFillOpacity = 1
                s.menuBarTrackOpacity = 0.22
            }
        }
    }

    private func opacitySlider(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .monospacedDigit().foregroundStyle(.secondary)
            }.font(.caption)
            Slider(value: value, in: 0...1, step: 0.01)
                .accessibilityLabel(title + "颜色深度")
        }
    }
}

struct KeepaliveActivitySection: View {
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
        VStack(alignment: .leading, spacing: 8) {
            if let text = blockedText {
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
            if s.busyFiring {
                Text("保活中…").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(s.displayedCodexFirst ? [true, false] : [false, true], id: \.self) { codex in
                let title = codex ? "Codex" : "Claude"
                let lastFire = codex ? s.codexLastFire : s.lastFire
                let result = codex ? s.codexLastFireResult : s.lastFireResult
                if let lastFire {
                    Text("上次 \(title) 保活：\(localMDHM(lastFire))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if !result.isEmpty {
                    Text(result).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if s.lastFire == nil && s.codexLastFire == nil
                && s.lastFireResult.isEmpty && s.codexLastFireResult.isEmpty
            {
                Text("暂无保活记录").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// 开启交叉保活后，时间摘要始终留在用量下方，不受快捷开关是否隐藏影响。
struct CrossKeepaliveTimingView: View {
    @EnvironmentObject var s: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("交叉保活", systemImage: "clock.arrow.2.circlepath")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 4)
                Text(s.crossCentered ? "居中 ≈2h30m" : "间隔＞\(Int(s.crossIntervalMinutes)) 分钟")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(s.crossStatus)
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            Divider()
            KeepaliveActivitySection()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.055)))
    }
}
