// KeepAliveBar — Claude Code 5 小时窗口保活 · 菜单栏小插件
// 菜单栏显示 5h 窗口倒计时；点击弹出用量+重置时间；窗口一关自动发保活消息续窗。
// 用 swiftc 编译（见 build-app.sh），非沙盒、菜单栏 Agent（LSUIElement）。

import SwiftUI
import AppKit
import Foundation
import ServiceManagement

// MARK: - 用量接口数据结构（对应 GET https://api.anthropic.com/api/oauth/usage）
struct UsageResponse: Decodable {
    struct Bucket: Decodable { let utilization: Double?; let resets_at: String? }
    let five_hour: Bucket?
    let seven_day: Bucket?
    let seven_day_opus: Bucket?
    let seven_day_sonnet: Bucket?
}

func parseISO(_ s: String?) -> Date? {
    guard let s = s else { return nil }
    // 去掉微秒小数部分（ISO8601DateFormatter 对 6 位小数会失败）
    let cleaned = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: cleaned)
}

// MARK: - 外部命令执行
enum Shell {
    static func run(_ launch: String, _ args: [String], env: [String: String]) -> (out: String, code: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return ("launch error: \(error)", -1) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", p.terminationStatus)
    }
}

// MARK: - 状态与调度
@MainActor
final class Store: ObservableObject {
    @Published var fivePct: Double?
    @Published var fiveReset: Date?
    @Published var sevenPct: Double?
    @Published var sevenReset: Date?
    @Published var opusPct: Double?
    @Published var opusReset: Date?
    @Published var sonnetPct: Double?
    @Published var sonnetReset: Date?
    @Published var lastError: String?
    @Published var lastFire: Date?
    @Published var lastFireResult: String = ""
    @Published var busyFiring = false
    @Published var now: Date = Date()
    @Published var autoEnabled: Bool {
        didSet { UserDefaults.standard.set(autoEnabled, forKey: "autoEnabled") }
    }
    @Published var launchAtLogin: Bool = false

    let bufferSec: TimeInterval = 90        // 真实重置时刻之后再等这么久才发（确保旧窗口确已关闭）
    let retryIntervalSec: TimeInterval = 180 // 两次“尝试”最小间隔：失败/未续窗时按此退避重试（3 分钟）
    private var lastAttempt: Date?          // 上次尝试时间（成功/失败都记）
    let keychainService = "Claude Code-credentials"
    let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private var pollTimer: Timer?
    private var tickTimer: Timer?

    var home: String { NSHomeDirectory() }
    var supportDir: String { "\(NSHomeDirectory())/Library/Application Support/KeepAliveBar" }
    var workdir: String { "\(supportDir)/null" }

    init() {
        self.autoEnabled = (UserDefaults.standard.object(forKey: "autoEnabled") as? Bool) ?? true
        if let t = UserDefaults.standard.object(forKey: "lastFire") as? Double {
            self.lastFire = Date(timeIntervalSince1970: t)
        }
        try? FileManager.default.createDirectory(atPath: workdir, withIntermediateDirectories: true)
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        Task { await refresh() }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    // 菜单栏标题：仅显示距 5h 窗口重置的剩余时间（图标已是 Clawd，去掉闪电标识）
    var menuTitle: String {
        guard let r = fiveReset else { return "–" }
        let rem = r.timeIntervalSince(now)
        return rem <= 0 ? "now" : Store.hhmm(rem)
    }

    nonisolated static func hhmm(_ s: TimeInterval) -> String {
        let t = Int(max(0, s)); let h = t / 3600; let m = (t % 3600) / 60
        return h > 0 ? "\(h)h\(String(format: "%02d", m))m" : "\(m)m"
    }

    func tick() {
        now = Date()
        evaluateFire()
    }

    func baseEnv() -> [String: String] {
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        e["HOME"] = home
        return e
    }

    func token() async -> String? {
        let env = baseEnv(); let svc = keychainService
        let r = await Task.detached {
            Shell.run("/usr/bin/security", ["find-generic-password", "-s", svc, "-w"], env: env)
        }.value
        guard r.code == 0, let d = r.out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        let o = (obj["claudeAiOauth"] as? [String: Any]) ?? obj
        return o["accessToken"] as? String
    }

    func refresh() async {
        guard let tok = await token() else {
            lastError = "无法读取 Keychain token（API-key 用户？或未授权 security 访问）"
            return
        }
        var req = URLRequest(url: usageURL)
        req.httpMethod = "GET"
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("claude-code/2.1", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                lastError = "usage HTTP \(http.statusCode)"; return
            }
            let u = try JSONDecoder().decode(UsageResponse.self, from: data)
            fivePct = u.five_hour?.utilization;         fiveReset = parseISO(u.five_hour?.resets_at)
            sevenPct = u.seven_day?.utilization;        sevenReset = parseISO(u.seven_day?.resets_at)
            opusPct = u.seven_day_opus?.utilization;    opusReset = parseISO(u.seven_day_opus?.resets_at)
            sonnetPct = u.seven_day_sonnet?.utilization; sonnetReset = parseISO(u.seven_day_sonnet?.resets_at)
            lastError = nil
            now = Date()
            evaluateFire()
        } catch {
            lastError = "查询失败: \(error.localizedDescription)"
        }
    }

    // 决策：自动开启 & 窗口已关（越过真实重置时刻）& 未违反防抖 → 发保活
    func evaluateFire() {
        guard autoEnabled, !busyFiring else { return }
        let now = Date()
        // 距上次“尝试”不足 retryIntervalSec 则不动：
        //  · 正常续窗成功后 → resets_at 前移约 5h，下面的窗口判据自然关闸
        //  · 若发了却没成功续窗（失败 / 落进仍有剩余时间的旧窗口）→ resets_at 仍在过去，据此退避重试
        if let la = lastAttempt, now.timeIntervalSince(la) < retryIntervalSec { return }
        guard let r = fiveReset else { return } // 无用量数据不乱发
        // 只有当“真实重置时刻已过”（窗口确已关闭、无剩余时间）才发；窗口还有剩余时间则继续等待
        if now.timeIntervalSince(r) >= bufferSec {
            Task { await fire() }
        }
    }

    func fire() async {
        if busyFiring { return }
        busyFiring = true
        defer { busyFiring = false }
        lastAttempt = Date()   // 记录尝试时刻（成功/失败都算）→ 失败后按 retryIntervalSec 退避重试
        try? FileManager.default.createDirectory(atPath: workdir, withIntermediateDirectories: true)
        let env = baseEnv(); let wd = workdir
        // 空目录 + 禁 MCP + 去除 API key（走订阅）+ Haiku
        let cmd = "cd '\(wd)' && exec env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN " +
                  "claude -p 'hi' --model haiku --strict-mcp-config"
        let r = await Task.detached { Shell.run("/bin/bash", ["-c", cmd], env: env) }.value
        let trimmed = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.code == 0 {
            let stamp = Date()
            lastFire = stamp
            UserDefaults.standard.set(stamp.timeIntervalSince1970, forKey: "lastFire")
            lastFireResult = "保活成功：\(String(trimmed.prefix(60)))"
            log("FIRED -> \(String(trimmed.prefix(100)))")
        } else {
            // 失败：不更新 lastFire（窗口仍算未续），lastAttempt 已记 → retryIntervalSec 后自动重试
            let mins = Int(retryIntervalSec / 60)
            lastFireResult = "保活失败 (rc=\(r.code))，约 \(mins) 分钟后自动重试：\(String(trimmed.prefix(80)))"
            log("FAILED rc=\(r.code) (retry in \(mins)m): \(String(trimmed.prefix(160)))")
        }
        Task { try? await Task.sleep(nanoseconds: 3_000_000_000); await refresh() }
    }

    func refreshNow() { Task { await refresh() } }

    // 开机自启：注册/注销登录项；首次开启时跳转「系统设置▸登录项」让用户确认
    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
            lastError = nil
        } catch {
            lastError = "开机自启设置失败：\(error.localizedDescription)（可在系统设置手动添加）"
        }
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        if on { SMAppService.openSystemSettingsLoginItems() }  // 跳转设置
    }

    func log(_ s: String) {
        try? FileManager.default.createDirectory(atPath: supportDir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(f.string(from: Date()))  \(s)\n"
        let path = "\(supportDir)/keepalive.log"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); if let d = line.data(using: .utf8) { h.write(d) }; try? h.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - 展示辅助
func sevColor(_ pct: Double?) -> Color {
    guard let p = pct else { return .gray }
    if p < 70 { return .green } else if p < 90 { return .orange } else { return .red }
}
func localHM(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d) }
func localMDHM(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"; return f.string(from: d) }
func resetInfo(_ reset: Date?, _ now: Date) -> String {
    guard let r = reset else { return "重置 —" }
    let rem = r.timeIntervalSince(now)
    return rem >= 0 ? "重置 \(localHM(r))（还剩 \(Store.hhmm(rem))）"
                    : "重置 \(localHM(r))（已过 \(Store.hhmm(-rem))）"
}

// MARK: - 弹窗界面
struct ContentView: View {
    @EnvironmentObject var s: Store

    var maxPct: Double { max(s.fivePct ?? 0, s.sevenPct ?? 0) }

    var nextFireText: String {
        if !s.autoEnabled { return "自动保活已关闭" }
        guard let r = s.fiveReset else { return "下次保活：等待用量数据…" }
        let rem = r.timeIntervalSince(s.now)
        return rem > 0 ? "下次保活：约 \(Store.hhmm(rem)) 后（窗口重置时）" : "下次保活：即将执行"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Claude 保活").font(.headline)
                Spacer()
                Circle().fill(sevColor(maxPct)).frame(width: 9, height: 9)
            }

            usageRow("5 小时会话", s.fivePct, s.fiveReset)
            usageRow("周 · 全模型", s.sevenPct, s.sevenReset)
            if s.opusPct != nil { usageRow("周 · Opus", s.opusPct, s.opusReset) }
            if s.sonnetPct != nil { usageRow("周 · Sonnet", s.sonnetPct, s.sonnetReset) }

            Divider()
            Text(nextFireText).font(.caption).foregroundStyle(.secondary)
            Toggle("自动保活（窗口一关就续下一个 5h）", isOn: $s.autoEnabled)
                .toggleStyle(.switch).font(.caption)
            Toggle("开机自启（登录时自动启动）", isOn: Binding(
                get: { s.launchAtLogin },
                set: { s.setLaunchAtLogin($0) }
            )).toggleStyle(.switch).font(.caption)

            HStack(spacing: 8) {
                if s.busyFiring {
                    Text("保活中…").font(.caption2).foregroundStyle(.secondary)
                }
                Button("刷新") { s.refreshNow() }
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
            }

            if !s.lastFireResult.isEmpty {
                Text(s.lastFireResult).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            if let lf = s.lastFire {
                Text("上次保活：\(localMDHM(lf))").font(.caption2).foregroundStyle(.secondary)
            }
            if let e = s.lastError {
                Text(e).font(.caption2).foregroundStyle(.red).lineLimit(2)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    @ViewBuilder
    func usageRow(_ title: String, _ pct: Double?, _ reset: Date?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline).bold()
                Spacer()
                Text(pct == nil ? "—" : "\(Int(pct!.rounded()))%")
                    .font(.subheadline).foregroundStyle(sevColor(pct))
            }
            ProgressView(value: min(max((pct ?? 0) / 100, 0), 1)).tint(sevColor(pct))
            Text(resetInfo(reset, s.now)).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - App 入口（菜单栏）
@main
struct KeepAliveBarApp: App {
    @StateObject private var store = Store()

    // Clawd 像素蟹图标（保留彩色，不做模板染色）
    static let clawd: NSImage? = {
        guard let url = Bundle.main.url(forResource: "clawd", withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        let h: CGFloat = 13
        let ar = img.size.height > 0 ? img.size.width / img.size.height : 1.6
        img.size = NSSize(width: h * ar, height: h)  // 保持宽高比，不压扁
        img.isTemplate = false
        return img
    }()

    var body: some Scene {
        MenuBarExtra {
            ContentView().environmentObject(store)
        } label: {
            if let img = KeepAliveBarApp.clawd {
                Image(nsImage: img)
                Text(store.menuTitle)
            } else {
                Text(store.menuTitle)
            }
        }
        .menuBarExtraStyle(.window)
    }
}
