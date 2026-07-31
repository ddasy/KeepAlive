// KeepAliveBar — Claude Code 5 小时窗口保活 · 菜单栏小插件
// 菜单栏显示 5h 窗口倒计时；点击弹出用量+重置时间；窗口一关自动发保活消息续窗。
// 用 swiftc 编译（见 build-app.sh），非沙盒、菜单栏 Agent（LSUIElement）。

import SwiftUI
import AppKit
import Foundation
import ServiceManagement
import Darwin   // posix_spawn / dlsym（保活脱钩用）

// MARK: - 用量接口数据结构（对应 GET https://api.anthropic.com/api/oauth/usage）
struct UsageResponse: Decodable {
    struct Bucket: Decodable { let utilization: Double?; let resets_at: String? }
    // limits[] 里 kind=="session" 的条目带 is_active。⚠️实测（2026-07-03）：活动窗口期间它也是 false，
    // 不能当“是否有活动窗口”用；仅解析出来记日志诊断。判定活动窗口用 five_hour.resets_at 是否在未来。
    struct Limit: Decodable { let kind: String?; let is_active: Bool?; let resets_at: String?; let percent: Double? }
    let five_hour: Bucket?
    let seven_day: Bucket?
    let seven_day_opus: Bucket?
    let seven_day_sonnet: Bucket?
    let limits: [Limit]?
}

// Codex 用量（来自 ~/.codex 会话日志里最后一条 rate_limits 快照，本地读取，无需联网）
struct CodexRollout: Decodable {
    struct Payload: Decodable {
        struct RL: Decodable {
            // ⚠️ primary/secondary 槽位并非固定对应 5h/周——要看 window_minutes 判定：
            // window_minutes≈300 → 5 小时窗口；≈10080 → 7 天(周)窗口。空闲(仅 hi 保活)的快照往往
            // 只带一个“周”窗口且放在 primary、secondary 缺失、5h 窗口整段消失。切勿按槽位当 5h/周。
            struct Bucket: Decodable { let used_percent: Double?; let resets_at: Double?; let window_minutes: Double? }
            let primary: Bucket?
            let secondary: Bucket?
            let plan_type: String?
        }
        let rate_limits: RL?
    }
    let timestamp: String?
    let payload: Payload?
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

    // 私有 API responsibility_spawnattrs_setdisclaim：让 spawn 出来的子进程“自负 TCC/钥匙串责任”，
    // 不再把访问算到本 App（ad-hoc 临时签名、macOS 认不出稳定身份 → 只给“允许”不给“始终允许”，每次都弹）头上。
    // 用 dlsym 运行时取符号：取不到就退化成普通 spawn（功能不受影响，只是可能仍弹框）。
    private typealias DisclaimFn = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    private static let setDisclaim: DisclaimFn? = {
        guard let sym = dlsym(dlopen(nil, RTLD_LAZY), "responsibility_spawnattrs_setdisclaim") else { return nil }
        return unsafeBitCast(sym, to: DisclaimFn.self)
    }()

    // 与 run 等价，但子进程“脱钩”——钥匙串/TCC 责任落到稳定的系统身份而非本 App。
    // 用于保活的 claude -p：避免因本 App 是 ad-hoc 签名而每次弹“允许访问钥匙串”框。
    static func runDisclaimed(_ launch: String, _ args: [String], env: [String: String]) -> (out: String, code: Int32) {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        _ = setDisclaim?(&attr, 1)                       // 关键：子进程自负钥匙串责任（取不到符号则跳过）

        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }

        var fds = [Int32](repeating: 0, count: 2)
        guard pipe(&fds) == 0 else { return ("pipe() failed", -1) }
        let readFD = fds[0], writeFD = fds[1]
        posix_spawn_file_actions_adddup2(&fa, writeFD, 1)  // 子进程 stdout → 管道
        posix_spawn_file_actions_adddup2(&fa, writeFD, 2)  // 子进程 stderr → 管道
        posix_spawn_file_actions_addclose(&fa, readFD)
        posix_spawn_file_actions_addclose(&fa, writeFD)

        var cArgs: [UnsafeMutablePointer<CChar>?] = ([launch] + args).map { strdup($0) }
        cArgs.append(nil)
        var cEnv: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") }
        cEnv.append(nil)
        defer { for p in cArgs where p != nil { free(p) }; for p in cEnv where p != nil { free(p) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, launch, &fa, &attr, cArgs, cEnv)
        close(writeFD)                                   // 父进程关写端 → 子进程退出后读到 EOF
        if rc != 0 { close(readFD); return ("posix_spawn failed (rc=\(rc))", -1) }

        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(readFD, &buf, buf.count)
            if n > 0 { out.append(buf, count: n) } else { break }   // 0=EOF, <0=错误 → 结束
        }
        close(readFD)

        var status: Int32 = 0
        waitpid(pid, &status, 0)
        let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : -1   // WIFEXITED ? WEXITSTATUS : 异常
        return (String(data: out, encoding: .utf8) ?? "", code)
    }
}

// MARK: - 状态与调度
@MainActor
final class Store: ObservableObject {
    // 单例：SwiftUI 场景与 AppDelegate（悬停快照）共用同一份状态
    static let shared = Store()

    @Published var fivePct: Double?
    @Published var fiveReset: Date?       // 接口原始 five_hour.resets_at（窗口过期后可能为 null → nil）
    // windowEnd：我们信任并倒计时的“当前 5h 窗口结束时刻”。只要服务端返回未来的 five_hour.resets_at
    // 就更新它；窗口过期后接口把 resets_at 变 null/过去，它保持粘滞（仍指向旧窗口末尾），
    // 于是能可靠判定“已关闭”并续窗——不依赖 is_active（实测活动期间它也是 false，不可信）。
    @Published var windowEnd: Date? {
        didSet {
            if let end = windowEnd {
                UserDefaults.standard.set(end.timeIntervalSince1970, forKey: "windowEnd")
            } else {
                UserDefaults.standard.removeObject(forKey: "windowEnd")
            }
        }
    }
    @Published var sessionActive: Bool?   // limits[session].is_active —— 仅记日志用，实测不可靠（活动期间也为 false）
    @Published var lastRefresh: Date?     // 上次成功联网刷新时刻（调试用）
    @Published var sevenPct: Double?
    @Published var sevenReset: Date?
    @Published var opusPct: Double?
    @Published var opusReset: Date?
    @Published var sonnetPct: Double?
    @Published var sonnetReset: Date?
    // Codex 用量（本地日志快照）
    @Published var codexAvailable = false
    @Published var codexPlan: String?
    @Published var codexPrimaryUsed: Double?
    @Published var codexPrimaryReset: Date?
    @Published var codexWeeklyUsed: Double?
    @Published var codexWeeklyReset: Date?
    @Published var codexSnapshotAt: Date?
    @Published var codexLastFire: Date?
    @Published var codexLastFireResult: String = ""
    @Published var lastError: String?
    @Published var lastFire: Date?
    @Published var lastFireResult: String = ""
    @Published var busyFiring = false
    @Published var now: Date = Date()
    // 保活开关拆成两路：Claude / Codex 各自独立，互不影响（旧版单一 autoEnabled 键在 init 里迁移）
    @Published var claudeAutoEnabled: Bool {
        didSet { UserDefaults.standard.set(claudeAutoEnabled, forKey: "claudeAutoEnabled") }
    }
    @Published var codexAutoEnabled: Bool {
        didSet { UserDefaults.standard.set(codexAutoEnabled, forKey: "codexAutoEnabled") }
    }
    @Published var launchAtLogin: Bool = false
    @Published var paused: Bool {                                 // 暂停：停止 GET 与续窗
        didSet { UserDefaults.standard.set(paused, forKey: "paused") }
    }
    @Published var autoQueryOnOpen: Bool {                        // 打开菜单栏弹窗时是否自动查询一次用量
        didSet { UserDefaults.standard.set(autoQueryOnOpen, forKey: "autoQueryOnOpen") }
    }
    @Published var hideCountdown: Bool {                          // 隐藏倒计时：菜单栏只留图标，不显示 Claude 下次重置剩余时间
        didSet { UserDefaults.standard.set(hideCountdown, forKey: "hideCountdown") }
    }
    @Published var popupOpen = false                              // 主弹窗是否正开着（悬停快照据此避让，见 HoverSnapshot）

    let bufferSec: TimeInterval = 90        // 真实重置时刻之后再等这么久才发（确保旧窗口确已关闭）
    let retryIntervalSec: TimeInterval = 180 // 两次“尝试”最小间隔：失败/未续窗时按此退避重试（3 分钟）
    let refreshRetryIntervalSec: TimeInterval = 180 // 用量查询失败/缺少窗口时间时的退避基数（3 分钟起，指数增长）
    let refreshRetryMaxIntervalSec: TimeInterval = 1800 // 退避上限 30 分钟
    let tokenRefreshBufferSec: TimeInterval = 300 // token 剩余寿命少于 5 分钟就提前换，别卡在边界上发请求
    let codexBufferSec: TimeInterval = 90
    let codexRetryIntervalSec: TimeInterval = 180
    let codexFallbackSec: TimeInterval = 18000 // 没有 reset 快照时，连续 5 小时后首次激活
    let codexMinRefireSec: TimeInterval = 17400 // 成功后至少 4h50m 不重复发送
    private var lastAttempt: Date?          // 上次尝试时间（成功/失败都记）
    private var codexLastAttempt: Date?
    private var codexNoSnapshotSince: Date?
    private var weeklyBlockLoggedAt: Date?  // Codex 周限拦截日志的节流时刻（每小时最多一条）
    private var claudeWeeklyRecheckAt: Date? // Claude 周限满时的下次联网复查时刻（稀疏复查，不再 3 分钟一轮）
    private var lastCodexPoll: Date?
    private var codexActing = false
    private var refreshRetryTask: Task<Void, Never>?
    private var refreshRetryFailures = 0     // 连续失败次数 → scheduleRefreshRetry 的指数退避指数（成功即清零）
    private var busyRefreshingToken = false  // token 刷新单飞：只防自己并发，不防 CLI（见 refreshOAuthToken 注释）
    let keychainService = "Claude Code-credentials"
    let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private var tickTimer: Timer?
    private var acting = false   // 正在处理“窗口关闭”（联网确认+续窗），防重入

    var home: String { NSHomeDirectory() }
    var supportDir: String { "\(NSHomeDirectory())/Library/Application Support/KeepAliveBar" }
    var workdir: String { "\(supportDir)/null" }

    init() {
        // 迁移：旧版只有一个 autoEnabled，拆分后它作为两路开关的默认值（都没写过新键时）
        let legacyAuto = (UserDefaults.standard.object(forKey: "autoEnabled") as? Bool) ?? true
        self.claudeAutoEnabled = (UserDefaults.standard.object(forKey: "claudeAutoEnabled") as? Bool) ?? legacyAuto
        self.codexAutoEnabled = (UserDefaults.standard.object(forKey: "codexAutoEnabled") as? Bool) ?? legacyAuto
        self.paused = UserDefaults.standard.bool(forKey: "paused")   // 默认 false
        self.autoQueryOnOpen = (UserDefaults.standard.object(forKey: "autoQueryOnOpen") as? Bool) ?? true
        self.hideCountdown = UserDefaults.standard.bool(forKey: "hideCountdown")   // 默认 false（显示倒计时）
        if let t = UserDefaults.standard.object(forKey: "windowEnd") as? Double {
            self.windowEnd = Date(timeIntervalSince1970: t)
        }
        if let t = UserDefaults.standard.object(forKey: "lastFire") as? Double {
            self.lastFire = Date(timeIntervalSince1970: t)
        }
        if let t = UserDefaults.standard.object(forKey: "codexLastFire") as? Double {
            self.codexLastFire = Date(timeIntervalSince1970: t)
        }
        if let t = UserDefaults.standard.object(forKey: "codexLastAttempt") as? Double {
            self.codexLastAttempt = Date(timeIntervalSince1970: t)
        }
        if let t = UserDefaults.standard.object(forKey: "codexNoSnapshotSince") as? Double {
            self.codexNoSnapshotSince = Date(timeIntervalSince1970: t)
        }
        try? FileManager.default.createDirectory(atPath: workdir, withIntermediateDirectories: true)
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        let needsBootstrap = windowEnd == nil
        log("APP start (claudeAuto=\(claudeAutoEnabled) codexAuto=\(codexAutoEnabled) paused=\(paused) restoredWindowEnd=\(fmt(windowEnd))) — \(needsBootstrap ? "无窗口时间，立即拉取" : "5 分钟后首次拉取")")
        Task {
            // 有持久化时间时延续原来的 5 分钟启动缓冲；没有时间（菜单栏会显示“–”）则立即恢复状态。
            if !needsBootstrap {
                try? await Task.sleep(nanoseconds: 300_000_000_000)
            }
            await refresh()
        }
        // 本地倒计时 + 到点判断；不再定时轮询接口（resets_at 在一个 5h 窗口内固定不变）
        tickTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        warmupIfNeeded()
    }

    // 首次启动“授权预热”：只跑一次（didWarmup 标记）。趁用户在场，主动各 fire 一次 claude / codex，
    // 让本来只有到期执行任务时才冒出来的系统授权框（claude 读/写钥匙串、codex 若碰保护目录的文件访问）
    // 提前弹出来，用户当场点“始终允许”，而不是在某个 5h 边界随机冒出、阻塞续窗。
    //   · claude fire → 读 Keychain「Claude Code-credentials」→ 弹一次“始终允许”（钉在固定路径副本
    //     keepalive-claude 上，身份稳定，点一次长期有效）。这是预热的主要价值。
    //   · codex fire → 确认登录态可用；注意保活的 codex 从 App Support（非保护目录）发起，本就不需要
    //     “访问桌面”授权，所以预热不会（也无法）复现你在 ~/Desktop 里跑 codex 时的 node 授权框——
    //     那个由 `brew pin node`（冻结 node 版本、路径不再漂移）根治，不靠预热。
    // 想重新触发预热：删掉 UserDefaults 的 didWarmup 键即可。
    func warmupIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "didWarmup") else { return }
        UserDefaults.standard.set(true, forKey: "didWarmup")   // 先落标记：即便本次失败也不反复打扰
        log("WARMUP: 首次启动 → 主动各跑一次 claude/codex，触发系统授权（钥匙串/文件访问），请在弹框点“始终允许”")
        Task { [weak self] in
            guard let self else { return }
            if self.claudeAutoEnabled { await self.fire() }        // 触发 claude 读/写钥匙串 → 首次弹“始终允许”
            if self.codexAutoEnabled { await self.fireCodex() }    // 首次跑一次 codex，确认登录态/授权可用
        }
    }

    // 菜单栏标题：仅显示距 5h 窗口重置的剩余时间（图标已是 Clawd，去掉闪电标识）
    // 返回 "" 表示“菜单栏只留图标”（隐藏倒计时）；暂停态仍保留 ⏸——它是运行状态而非刷新时间，
    // 否则关掉保活后菜单栏毫无痕迹，容易忘了自己按过暂停。
    var menuTitle: String {
        if paused { return "⏸" }
        if hideCountdown { return "" }                  // 隐藏倒计时
        guard let end = windowEnd else { return "–" }   // 还没见过任何活动窗口
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

    func tick() {
        guard !paused else { return }   // 暂停：不倒计时、不联网、不续窗
        now = Date()   // 本地倒计时（不联网）
        maybeAct()     // 只有到点了才会去联网确认并续窗
        // Codex 的 reset 来自本地 rollout 快照，每 5 分钟读一次；没有快照时也由这里累计 5 小时。
        if lastCodexPoll == nil || now.timeIntervalSince(lastCodexPoll!) >= 300 {
            lastCodexPoll = now
            Task { [weak self] in
                guard let self else { return }
                await self.readCodexUsage()
                self.maybeActCodex()
            }
        }
    }

    func baseEnv() -> [String: String] {
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        e["HOME"] = home
        return e
    }

    // 保活专用的固定路径 claude 副本：身份（路径/cdhash）永不随每日自动更新变，
    // 于是钥匙串“始终允许”一次点了能长期生效，不再每次到期都弹版本号授权框。
    // 副本用 install-app.sh 复制生成（cp -p 保留 Anthropic Developer ID 签名）。
    // 若副本缺失则退化为 PATH 里的 claude（仍能保活，只是会恢复每次弹框）。
    var keepaliveClaudeBin: String {
        let pinned = "\(home)/.local/share/claude/keepalive-claude"
        return FileManager.default.isExecutableFile(atPath: pinned) ? pinned : "claude"
    }

    var keepaliveCodexBin: String {
        let candidates = [
            "\(home)/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? "/usr/bin/env"
    }

    var keepaliveCodexUsesEnv: Bool { keepaliveCodexBin == "/usr/bin/env" }

    // 读取 Keychain 凭据。返回 accessToken + 过期时刻(ms) + 失败诊断串（供日志精确定位）。
    // ⚠️ 绝不记录 token 本身；仅在失败时把 security 的退出码与错误输出（截断）带回来——
    //   security 成功时 out 是明文 token，只有 rc!=0 时 out 才是报错文本（item not found / auth denied 等）。
    // refreshToken / scopes 也读出来：过期时要拿它们走 CLI 的非交互刷新入口（见 refreshOAuthToken）。
    struct Credential {
        let accessToken: String?; let refreshToken: String?; let scopes: [String]
        let expiresAtMs: Double?; let diag: String
    }
    func readCredential() async -> Credential {
        let env = baseEnv(); let svc = keychainService
        let r = await Task.detached {
            Shell.run("/usr/bin/security", ["find-generic-password", "-s", svc, "-w"], env: env)
        }.value
        guard r.code == 0 else {
            let msg = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            return Credential(accessToken: nil, refreshToken: nil, scopes: [], expiresAtMs: nil,
                              diag: "security rc=\(r.code) \(String(msg.prefix(140)))")
        }
        guard let d = r.out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            return Credential(accessToken: nil, refreshToken: nil, scopes: [], expiresAtMs: nil,
                              diag: "凭据 JSON 解析失败")
        }
        let o = (obj["claudeAiOauth"] as? [String: Any]) ?? obj
        let tok = o["accessToken"] as? String
        let exp = (o["expiresAt"] as? NSNumber)?.doubleValue
        return Credential(accessToken: tok,
                          refreshToken: o["refreshToken"] as? String,
                          scopes: (o["scopes"] as? [String]) ?? [],
                          expiresAtMs: exp,
                          diag: tok == nil ? "凭据里无 accessToken 字段（API-key 用户？）" : "")
    }

    // token 过期状态的紧凑串：把剩余寿命算出来，供 401 时对照（过期→大概率就是 401 主因）。
    func tokenExpStr(_ expiresAtMs: Double?) -> String {
        guard let ms = expiresAtMs else { return "未知" }
        let exp = Date(timeIntervalSince1970: ms / 1000)
        let rem = exp.timeIntervalSince(Date())
        return "\(fmt(exp))(\(rem >= 0 ? "剩\(Int(rem / 60))m" : "已过期\(Int(-rem / 60))m"))"
    }

    // 是否该提前换 token。expiresAt 未知时返回 false —— 不主动刷，交给 401 分支兜底。
    func tokenNeedsRefresh(_ expiresAtMs: Double?) -> Bool {
        guard let ms = expiresAtMs else { return false }
        return Date(timeIntervalSince1970: ms / 1000).timeIntervalSinceNow < tokenRefreshBufferSec
    }

    // 用钥匙串里的 refreshToken 换一张新的 access token。
    //
    // 走的是 CLI 官方的非交互刷新入口（CLAUDE_CODE_OAUTH_REFRESH_TOKEN + `claude auth login`）：
    // 内部就是一次 grant_type=refresh_token 交换，**不发任何推理请求、不开 5h 窗口、不耗用量**，
    // 实测 ~2.5s 换到一张满血 8 小时的新 token。
    //
    // 为什么必须借 CLI 而不是 App 自己 POST /v1/oauth/token：
    //   服务端**每次都轮换 refresh token**（实测两次调用 refreshToken 全变）。App 自己换而不写回钥匙串，
    //   CLI 手里那个就作废了，下次 claude 起来直接要求重新登录。交给 CLI，写回和轮换都是它的事。
    //
    // 为什么不需要跟 CLI 抢锁、也不需要判断“有没有 claude 在跑”：
    //   一是本地交互式会话空闲时根本不刷 token（只在真要发 API 请求时懒刷新，没有后台定时器），
    //     所以“有 claude 窗口开着”对“token 会不会被别人刷”毫无预测力，拿它当闸门只会挡住自己；
    //   二是 CLI 的刷新逻辑本来就按“随时可能有兄弟进程在旁边轮换”写的——它在加锁后、POST 前会重读
    //     钥匙串比对 accessToken，交换失败后也会先重读、发现已被换掉就直接当成功返回，
    //     连清 dead token 那步都有 refreshToken 的 CAS 守卫。竞态是良性的。
    @discardableResult
    func refreshOAuthToken(_ cred: Credential) async -> Bool {
        if busyRefreshingToken { return false }
        busyRefreshingToken = true
        defer { busyRefreshingToken = false }
        guard let rt = cred.refreshToken, !rt.isEmpty, !cred.scopes.isEmpty else {
            log("TOKEN refresh 跳过：钥匙串缺 refreshToken 或 scopes（API-key 用户？）")
            return false
        }
        var env = baseEnv()
        env["CLAUDE_CODE_OAUTH_REFRESH_TOKEN"] = rt              // 只进子进程环境，绝不落日志
        env["CLAUDE_CODE_OAUTH_SCOPES"] = cred.scopes.joined(separator: " ")
        env.removeValue(forKey: "ANTHROPIC_API_KEY")             // 走订阅，别被 API key 抢了认证路径
        env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
        let bin = keepaliveClaudeBin
        log("TOKEN refresh start（当前 \(tokenExpStr(cred.expiresAtMs))）")
        // 与 fire() 同样用 runDisclaimed：写钥匙串的责任落到子进程，不然本 App 的 ad-hoc 签名会天天弹授权框。
        // stdin 接 /dev/null：CLI 会把 stdin 当补充输入读，不给 EOF 可能永久挂住。
        let cmd = "exec '\(bin)' auth login < /dev/null"
        let r = await Task.detached { Shell.runDisclaimed("/bin/bash", ["-c", cmd], env: env) }.value
        // 防御性脱敏：万一 CLI 把凭据回显进 stdout/stderr，也不能进日志。
        let out = r.out.replacingOccurrences(of: rt, with: "<REDACTED>")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let after = await readCredential()
        if r.code == 0 {
            log("TOKEN refresh ok → \(tokenExpStr(after.expiresAtMs))")
            return true
        }
        // 反向竞态：CLI 可能抢在我们前面用同一个 refreshToken 换过了，轮换后我们手里这个已失效 →
        // 我们这次拿到 invalid_grant。但此时钥匙串里其实已经是一张新的有效 token，别误判成失败。
        if !tokenNeedsRefresh(after.expiresAtMs) {
            log("TOKEN refresh rc=\(r.code)，但钥匙串已被其它进程刷新 → \(tokenExpStr(after.expiresAtMs))，按成功继续")
            return true
        }
        log("TOKEN refresh failed rc=\(r.code): \(String(out.prefix(160)))")
        return false
    }

    // 代理是否开启：api.anthropic.com 需经代理才可达，未开代理时联网动作必失败。
    // 与 keepalive.sh 的 proxy_enabled() 完全同一判断（复用同段 bash，避免两边漂移）：
    //   1) 系统代理：HTTP / HTTPS / SOCKS 任一 Enable : 1
    //   2) 纯 TUN/代理模式：默认路由走 utun 口且该口持有 fake-IP（198.18.0.0/15）
    func proxyEnabled() async -> Bool {
        let env = baseEnv()
        let script = """
        /usr/sbin/scutil --proxy 2>/dev/null | grep -qE '^[[:space:]]*(HTTPEnable|HTTPSEnable|SOCKSEnable)[[:space:]]*:[[:space:]]*1$' && exit 0
        dev=$(/sbin/route -n get default 2>/dev/null | awk '/interface:/{print $2}')
        case "$dev" in utun*) /sbin/ifconfig "$dev" 2>/dev/null | grep -qE 'inet 198\\.(18|19)\\.' && exit 0 ;; esac
        exit 1
        """
        let r = await Task.detached { Shell.run("/bin/bash", ["-c", script], env: env) }.value
        return r.code == 0
    }

    // 查询失败后不能只依赖 maybeAct()：后者必须先有 windowEnd，正是菜单栏显示“–”时缺少的状态。
    // 始终只保留一个延迟任务；手动刷新或新的刷新开始时会取消旧任务并重新计时。
    func scheduleRefreshRetry(_ reason: String) {
        guard !paused, refreshRetryTask == nil else { return }
        // 指数退避（3m 起、翻倍、封顶 30m）。失败原因基本都是“要等外部条件恢复”（代理没开、被限流、
        // 需要重新登录），固定 3 分钟死循环只会把无效请求堆成限流——旧日志里一次 4 小时的过期期
        // 就这么刷了 80 多条 401/429。成功一次即清零。
        let seconds = min(refreshRetryIntervalSec * pow(2, Double(refreshRetryFailures)),
                          refreshRetryMaxIntervalSec)
        refreshRetryFailures += 1
        log("REFRESH retry scheduled in \(Int(seconds))s: \(reason)")
        refreshRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.refreshRetryTask = nil
            await self.refresh()
        }
    }

    func cancelRefreshRetry() {
        refreshRetryTask?.cancel()
        refreshRetryTask = nil
    }

    // MARK: 周限闸门
    // 周用量已 100%（Codex 侧即“剩余 0”）时，5h 窗口再怎么续也发不出消息 —— 直接不触发自动保活，
    // 免得每 3 分钟撞一次墙、白白刷错误日志。
    // 恢复条件：越过周重置时刻即解除。此后 Claude 会在下一次 refresh 拿到真实的新周用量，
    // Codex 的 rollout 快照同理（UI 的 rolledOff 判定用的也是这条规则），于是自然继续保活。
    // reset 未知（nil）而用量已满 → 保守拦下，等到拿到 reset 再说。
    nonisolated static func weeklyBlocked(_ pct: Double?, _ reset: Date?, _ now: Date) -> Bool {
        guard let p = pct, p >= 100 else { return false }
        guard let r = reset else { return true }
        return r.timeIntervalSince(now) > 0
    }
    var claudeWeeklyBlocked: Bool { Store.weeklyBlocked(sevenPct, sevenReset, now) }
    var codexWeeklyBlocked: Bool { Store.weeklyBlocked(codexWeeklyUsed, codexWeeklyReset, now) }

    // 接口查询成功但没有活动 5h 窗口、且本地也没有可恢复的 windowEnd：
    // 用一条 Haiku 消息激活窗口。lastAttempt/lastFire 防止接口数据传播延迟造成重复发送。
    func maybeBootstrapMissingWindow() {
        guard claudeAutoEnabled, !paused, windowEnd == nil, !busyFiring, !acting else { return }
        if claudeWeeklyBlocked {
            log("BOOTSTRAP skip: Claude 周限 \(pctStr(sevenPct)) 已用尽（重置 \(fmt(sevenReset))）")
            return
        }
        let current = Date()
        let mostRecent = [lastAttempt, lastFire].compactMap { $0 }.max()
        if let recent = mostRecent, current.timeIntervalSince(recent) < retryIntervalSec { return }
        log("BOOTSTRAP: usage 查询成功但 windowEnd=nil → 用 Haiku 发送 hi 激活 5 小时窗口")
        Task { await fire() }
    }

    func refresh() async {
        cancelRefreshRetry()
        await readCodexUsage()          // Codex：本地读文件，不联网/不耗额度 → 不受暂停影响
        maybeActCodex()
        guard !paused else { return }   // 暂停：仅停止 Claude 的 GET 与续窗（不影响上面的 Codex）
        guard await proxyEnabled() else {   // 前置条件：代理未开则跳过用量刷新（Codex 已在上方读完）
            lastError = "代理未开启，已跳过用量刷新"
            log("REFRESH abort: 代理未开启")
            scheduleRefreshRetry("代理未开启")
            return
        }
        var cred = await readCredential()
        // token 过期就先换一张再发请求：过期后直接发 GET 必得 401，而空闲的 claude 会话不会替我们刷新，
        // 于是过去会一路 401 刷到某个 CLI 恰好起来为止（最长一次刷了 4 小时）。换 token 不耗用量、不开窗。
        if tokenNeedsRefresh(cred.expiresAtMs), await refreshOAuthToken(cred) {
            cred = await readCredential()
        }
        // 循环只为 401 后换 token 重试一次；其余每条路径都以 return 收尾，不会转第二圈。
        var triedTokenRefresh = false
        while true {
            guard let tok = cred.accessToken else {
                lastError = "无法读取 Keychain token（\(cred.diag)）"
                log("REFRESH abort: 无法读取 Keychain token — \(cred.diag)")
                scheduleRefreshRetry("无法读取 Keychain token")
                return
            }
            // token 仍是过期的（上面换失败，多半 refreshToken 也废了）→ 别再发这一发注定 401 的请求。
            // 这是 401/429 刷屏的止血点：无效凭据一次都不该打出去，429 本来就是这么被限流出来的。
            if tokenNeedsRefresh(cred.expiresAtMs) {
                lastError = "token 已过期且刷新失败，需重新登录 claude"
                log("REFRESH abort: token \(tokenExpStr(cred.expiresAtMs)) 且刷新失败 → 跳过 GET（需 claude auth login）")
                scheduleRefreshRetry("token 过期且刷新失败")
                return
            }
            let tokExp = tokenExpStr(cred.expiresAtMs)
            var req = URLRequest(url: usageURL)
            req.httpMethod = "GET"
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            req.setValue("claude-code/2.1", forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 20
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                    // 关键诊断：状态码 + token 过期状态 + 服务端错误体（含 authentication_error 等具体类型）。
                    // 401 时这行能一眼分清是「token 已过期」还是「被吊销/无效」，不再只看到红字一闪。
                    let body = (String(data: data, encoding: .utf8) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    // 401 但本地看着 token 没过期 → 多半是被吊销/服务端不认。换一张再试一次（只一次，防循环）。
                    if http.statusCode == 401, !triedTokenRefresh {
                        triedTokenRefresh = true
                        log("REFRESH http 401 tokenExp=\(tokExp)（本地未过期）→ 换新 token 后重试一次")
                        if await refreshOAuthToken(cred) {
                            cred = await readCredential()
                            continue
                        }
                    }
                    lastError = "usage HTTP \(http.statusCode)"
                    log("REFRESH http \(http.statusCode) tokenExp=\(tokExp) body=\(String(body.prefix(220)))")
                    scheduleRefreshRetry("usage HTTP \(http.statusCode)")
                    return
                }
                refreshRetryFailures = 0   // 拿到 200 → 退避指数清零，下次失败重新从 3 分钟起算
                let u = try JSONDecoder().decode(UsageResponse.self, from: data)
                fivePct = u.five_hour?.utilization;         fiveReset = parseISO(u.five_hour?.resets_at)
                sevenPct = u.seven_day?.utilization;        sevenReset = parseISO(u.seven_day?.resets_at)
                opusPct = u.seven_day_opus?.utilization;    opusReset = parseISO(u.seven_day_opus?.resets_at)
                sonnetPct = u.seven_day_sonnet?.utilization; sonnetReset = parseISO(u.seven_day_sonnet?.resets_at)
                sessionActive = u.limits?.first(where: { $0.kind == "session" })?.is_active   // 仅记日志，不做判断
                lastError = nil
                now = Date()
                lastRefresh = now
                // 只要服务端返回未来 reset，就更新 windowEnd；否则保持粘滞（见属性注释）。
                // 这样窗口过期（接口返回 null / 过去值）时 windowEnd 仍指向旧窗口末尾 → 能判定“已关闭”并续窗。
                // 保活刚开出的新窗口可能 utilization=0%，但 resets_at 已在未来；这仍是有效窗口。
                let hasActiveWindow = fiveReset.map { $0.timeIntervalSince(now) > 0 } ?? false
                if hasActiveWindow { windowEnd = fiveReset }
                // 关键诊断日志：原始 resets_at / 用量 / is_active 全记下——下次窗口过期时这行会揭示接口的真实返回
                log("REFRESH ok five=\(pctStr(fivePct)) rawReset=\(fmt(fiveReset)) tokenExp=\(tokExp) sessionActive=\(boolStr(sessionActive)) → windowEnd=\(fmt(windowEnd)) (active=\(hasActiveWindow))")
                if windowEnd == nil, claudeAutoEnabled {
                    // 服务端已明确当前没有活动窗口。立即尝试激活，并持续重查直到拿到新 reset。
                    scheduleRefreshRetry("查询成功但 five_hour.resets_at=nil")
                    maybeBootstrapMissingWindow()
                }
                return
            } catch {
                // 带上 NSError 的 domain#code：区分连接中断(-1005)/超时(-1001)/离线(-1009)/SSL(-1200) 等，
                // 对代理不稳的场景特别有用——localizedDescription 三种都可能是「网络连接已丢失」。
                let ns = error as NSError
                lastError = "查询失败: \(error.localizedDescription)"
                log("REFRESH failed: \(ns.domain)#\(ns.code) \(error.localizedDescription)")
                scheduleRefreshRetry("\(ns.domain)#\(ns.code)")
                return
            }
        }
    }

    // 读取 Codex 最新用量快照（~/.codex 会话日志里最后一条 rate_limits）——本地读取，不联网、不耗额度
    func readCodexUsage() async {
        let env = baseEnv()
        let cmd = "for f in $(ls -t \"$HOME\"/.codex/sessions/*/*/*/rollout-*.jsonl 2>/dev/null | head -12); do " +
                  "line=$(grep -a rate_limits \"$f\" 2>/dev/null | tail -1); " +
                  "[ -n \"$line\" ] && { printf '%s' \"$line\"; break; }; done"
        let r = await Task.detached { Shell.run("/bin/bash", ["-c", cmd], env: env) }.value
        guard let data = r.out.data(using: .utf8), !data.isEmpty,
              let roll = try? JSONDecoder().decode(CodexRollout.self, from: data),
              let rl = roll.payload?.rate_limits else {
            codexAvailable = false
            return
        }
        codexAvailable = true
        codexPlan = rl.plan_type
        // 按 window_minutes 归类，而不是按 primary/secondary 槽位（见 Bucket 注释）。
        // 5h 窗口：window_minutes ≤ 360；周窗口：≥ 1440。
        let buckets = [rl.primary, rl.secondary].compactMap { $0 }
        let hasWindowInfo = buckets.contains { $0.window_minutes != nil }
        let five: CodexRollout.Payload.RL.Bucket?
        let weekly: CodexRollout.Payload.RL.Bucket?
        if hasWindowInfo {
            five = buckets.first { ($0.window_minutes ?? .infinity) <= 360 }
            weekly = buckets.first { ($0.window_minutes ?? 0) >= 1440 }
        } else {
            // 老格式没有 window_minutes → 回退旧假设（primary=5h / secondary=周）。
            five = rl.primary; weekly = rl.secondary
        }
        // 5h 窗口：优先用快照里真正的 5h 窗口(通常只在有实际用量的会话里出现)；
        // 保活 hi 的快照往往只带“周”窗口、没有 5h 窗口 → 用“上次 fire + 5h”估算 5h 重置，
        // 既给出倒计时、又驱动在 fire 后约 5h 精确续窗，绝不把周 reset 误当 5h reset。
        if let five = five, let ra = five.resets_at {
            codexPrimaryUsed = five.used_percent
            codexPrimaryReset = Date(timeIntervalSince1970: ra)
        } else if let lf = codexLastFire {
            codexPrimaryUsed = nil                                  // 5h 真实用量未知
            codexPrimaryReset = lf.addingTimeInterval(codexFallbackSec)   // ≈ 上次 fire + 5h
        } else {
            codexPrimaryUsed = nil                                  // 从未 fire 过 → 交给时间兜底计时
            codexPrimaryReset = nil
        }
        codexWeeklyUsed = weekly?.used_percent
        codexWeeklyReset = weekly?.resets_at.map { Date(timeIntervalSince1970: $0) }
        codexSnapshotAt = parseISO(roll.timestamp)
    }

    // Codex 没有公开 usage 查询接口：有本地 reset 就按 reset 续窗；没有时间时，
    // 首次观察开始计时，连续 5 小时后发送一次 hi 激活，随后等待新的 rollout 快照。
    func maybeActCodex() {
        guard codexAutoEnabled, !paused, !busyFiring, !acting, !codexActing else { return }
        // 周限剩余 0 → 本周不再触发 5h 保活，等越过周重置时刻自动恢复
        if codexWeeklyBlocked {
            if weeklyBlockLoggedAt == nil || Date().timeIntervalSince(weeklyBlockLoggedAt!) >= 3600 {
                weeklyBlockLoggedAt = Date()   // 这行每小时最多记一条，别把日志刷满
                log("CODEX skip: 周限剩余 0（重置 \(fmt(codexWeeklyReset))）→ 暂不保活")
            }
            return
        }
        let current = Date()
        if let reset = codexPrimaryReset, reset.timeIntervalSince(current) > codexBufferSec {
            codexNoSnapshotSince = nil
            UserDefaults.standard.removeObject(forKey: "codexNoSnapshotSince")
            return
        }

        var ready = false
        if let reset = codexPrimaryReset {
            ready = current.timeIntervalSince(reset) >= codexBufferSec
        } else {
            if codexNoSnapshotSince == nil {
                codexNoSnapshotSince = current
                UserDefaults.standard.set(current.timeIntervalSince1970, forKey: "codexNoSnapshotSince")
                log("CODEX no reset snapshot — 开始 5 小时激活计时")
            }
            ready = current.timeIntervalSince(codexNoSnapshotSince!) >= codexFallbackSec
        }
        guard ready else { return }
        if let attempt = codexLastAttempt, current.timeIntervalSince(attempt) < codexRetryIntervalSec { return }
        if let fire = codexLastFire, current.timeIntervalSince(fire) < codexMinRefireSec { return }
        Task { await fireCodex() }
    }

    func fireCodex() async {
        guard !codexActing else { return }
        codexActing = true
        defer { codexActing = false }
        let attempt = Date()
        codexLastAttempt = attempt
        UserDefaults.standard.set(attempt.timeIntervalSince1970, forKey: "codexLastAttempt")
        log("CODEX FIRE start: codex exec 'hi' --model gpt-5.4-mini --effort low")
        try? FileManager.default.createDirectory(atPath: workdir, withIntermediateDirectories: true)

        let env = baseEnv()
        let command = keepaliveCodexUsesEnv ? "/usr/bin/env" : keepaliveCodexBin
        var args = keepaliveCodexUsesEnv ? ["codex"] : []
        args += [
            "--ask-for-approval", "never",
            "exec", "--model", "gpt-5.4-mini",
            "-c", "model_reasoning_effort=low",
            // 强制直连 HTTP(responses)、跳过 websocket。codex 默认先连 wss://chatgpt.com/.../responses，
            // 网络不稳时这一步常 403/超时后才降级 HTTP，白等一截、还不确定。内置 openai provider 不可覆盖，
            // 故另起一个自定义 provider：requires_openai_auth=true 复用 ChatGPT 订阅登录态（不走 API key 计费），
            // supports_websockets=false 关掉 websocket → 直连 HTTP，确定性更好。
            // 注：base_url 硬编码为 ChatGPT codex 后端；若官方改址，此处需同步（fire 会失败并重试、日志可见）。
            "-c", "model_provider=chatgpt-httponly",
            "-c", "model_providers.chatgpt-httponly.name=chatgpt-httponly",
            "-c", "model_providers.chatgpt-httponly.base_url=https://chatgpt.com/backend-api/codex",
            "-c", "model_providers.chatgpt-httponly.wire_api=responses",
            "-c", "model_providers.chatgpt-httponly.requires_openai_auth=true",
            "-c", "model_providers.chatgpt-httponly.supports_websockets=false",
            "--cd", workdir,
            "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules",
            "--sandbox", "read-only", "hi"
        ]
        var cleanEnv = env
        cleanEnv.removeValue(forKey: "OPENAI_API_KEY")
        cleanEnv.removeValue(forKey: "OPENAI_BASE_URL")
        let r = await Task.detached {
            Shell.runDisclaimed(command, args, env: cleanEnv)
        }.value
        let trimmed = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.code == 0 {
            let stamp = Date()
            codexLastFire = stamp
            UserDefaults.standard.set(stamp.timeIntervalSince1970, forKey: "codexLastFire")
            codexLastFireResult = "Codex 激活成功：\(String(trimmed.prefix(60)))"
            log("CODEX FIRED -> \(String(trimmed.prefix(120)))")
        } else {
            let mins = Int(codexRetryIntervalSec / 60)
            codexLastFireResult = "Codex 激活失败 (rc=\(r.code))，约 \(mins) 分钟后重试：\(String(trimmed.prefix(80)))"
            log("CODEX FAILED rc=\(r.code) (retry in \(mins)m): \(String(trimmed.prefix(180)))")
        }
        Task { try? await Task.sleep(nanoseconds: 3_000_000_000); await readCodexUsage() }
    }

    // 纯本地判断：本地倒计时（对 windowEnd）是否已过。到点才触发一次“联网确认 + 续窗”，平时不联网。
    // 用粘滞的 windowEnd 而非原始 fiveReset：即使接口在过期后把 resets_at 变 null / 未来，
    // windowEnd 仍指向旧窗口末尾（已过去）→ 能持续触发续窗与退避重试，不会像旧代码那样卡死。
    func maybeAct() {
        guard claudeAutoEnabled, !busyFiring, !acting else { return }
        let now = Date()
        // 距上次“尝试”不足 retryIntervalSec 则不动（失败/未续窗时按此退避重试）
        if let la = lastAttempt, now.timeIntervalSince(la) < retryIntervalSec { return }
        guard let end = windowEnd else { return }   // 还没追踪任何活动窗口 → 不动
        // 周限已满：不必每 3 分钟联网撞一次墙，按 claudeWeeklyRecheckAt 稀疏复查（见 handleWindowClosed）
        if claudeWeeklyBlocked, let until = claudeWeeklyRecheckAt, now < until { return }
        if now.timeIntervalSince(end) >= bufferSec { // 本地倒计时已过窗口末尾 → 该确认并续窗
            log("maybeAct → handleWindowClosed (windowEnd=\(fmt(end)) 已过 \(Int(now.timeIntervalSince(end)))s)")
            Task { await handleWindowClosed() }
        }
    }

    // 到点了：先联网确认最新状态，再决定是否续窗。
    // refresh() 会在“确有活动窗口（重置在未来）”时把 windowEnd 推到未来——
    // 这只可能是用户自己开了新窗、或我们上次 fire 已成功。此时无需再发。
    // 否则 windowEnd 仍是过去（旧窗口已关且没新窗口）→ 续窗。这样不依赖 is_active，也不会误判活动期。
    func handleWindowClosed() async {
        guard !acting, !busyFiring else { return }
        acting = true
        defer { acting = false }
        guard await proxyEnabled() else {   // 前置条件：代理未开则跳过本次续窗
            lastAttempt = Date()            // 记一次尝试 → 按 retryIntervalSec 退避，避免 5s 一次刷日志
            log("WINDOW CLOSED but 代理未开启 → 跳过续窗，稍后重试")
            return
        }
        await refresh()   // 到点时联网取最新状态（会按需更新 windowEnd）
        if let end = windowEnd, end.timeIntervalSince(Date()) > bufferSec {
            log("窗口已（重新）激活 windowEnd=\(fmt(end)) util=\(pctStr(fivePct)) → 跳过续窗")
            return                                     // 已有活动新窗口（用户已开 / 上次 fire 已成功）
        }
        // 刚拿到最新周用量：满了就不发（发也发不出去），并把下次复查推远，等周重置时刻附近再来。
        if claudeWeeklyBlocked {
            lastAttempt = Date()
            let capped = min(Date().addingTimeInterval(1800),
                             (sevenReset ?? .distantFuture).addingTimeInterval(60))
            claudeWeeklyRecheckAt = max(capped, Date().addingTimeInterval(180))
            log("WINDOW CLOSED 但 Claude 周限 \(pctStr(sevenPct))（重置 \(fmt(sevenReset))）→ 跳过续窗，\(fmt(claudeWeeklyRecheckAt)) 复查")
            return
        }
        log("WINDOW CLOSED（windowEnd=\(fmt(windowEnd)) 最新 rawReset=\(fmt(fiveReset)) util=\(pctStr(fivePct))）→ fire")
        await fire()                                   // 旧窗口确已关闭且无新窗口 → 续窗
    }

    func fire() async {
        if busyFiring { return }
        busyFiring = true
        defer { busyFiring = false }
        lastAttempt = Date()   // 记录尝试时刻（成功/失败都算）→ 失败后按 retryIntervalSec 退避重试
        log("FIRE start: claude -p 'hi' --model haiku（脱钩：子进程自负钥匙串责任，避免弹授权框）")
        try? FileManager.default.createDirectory(atPath: workdir, withIntermediateDirectories: true)
        let env = baseEnv(); let wd = workdir; let bin = keepaliveClaudeBin
        // 空目录 + 禁 MCP + 去除 API key（走订阅）+ Haiku
        // 用固定路径副本（keepaliveClaudeBin）而非 PATH 里天天更新的 claude，
        // 让钥匙串授权对象身份稳定，避免每次到期都弹版本号授权框。
        let cmd = "cd '\(wd)' && exec env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN " +
                  "'\(bin)' -p 'hi' --model haiku --strict-mcp-config"
        // 用 runDisclaimed 而非 run：claude 刷新 OAuth token 写钥匙串时不再算到本 App（ad-hoc 签名）头上，
        // 从而不再每次弹“允许访问钥匙串”框（详见 Shell.runDisclaimed 注释）。
        let r = await Task.detached { Shell.runDisclaimed("/bin/bash", ["-c", cmd], env: env) }.value
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

    // 手动刷新：清零退避指数，否则退到 30 分钟后用户点“刷新”还得按老节奏等——手动动作应当立刻生效。
    func refreshNow() { refreshRetryFailures = 0; Task { await refresh() } }

    // 暂停 / 恢复：暂停后停止 GET 与续窗；恢复后立即刷新一次
    func togglePause() {
        paused.toggle()
        log(paused ? "PAUSED（停止 GET 与续窗）" : "RESUMED（恢复监控）")
        if paused {
            cancelRefreshRetry()
        } else {
            refreshNow()
        }
    }

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

    // 日志用小工具：时刻 / 百分比 / 可选 Bool 的紧凑字符串
    func fmt(_ d: Date?) -> String {
        guard let d = d else { return "nil" }
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"; return f.string(from: d)
    }
    func pctStr(_ p: Double?) -> String { p.map { "\(Int($0.rounded()))%" } ?? "—" }
    func boolStr(_ b: Bool?) -> String { b.map { $0 ? "true" : "false" } ?? "nil" }

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

// MARK: - 弹窗界面
// 弹窗被拆成两块，方便悬停快照直接复用上半部分：
//   · UsageSections —— Claude / Codex 用量。纯展示，无任何副作用（不查询、不写状态）。
//   · ControlSections —— 开关、按钮、上次保活结果等“操作与诊断”。
// 主弹窗 = UsageSections + ControlSections；悬停快照 = UsageSections（见 SnapshotView）。
// 两者共用同一份渲染代码，改一处两边同步，绝不会出现“快照和弹窗对不上”。
struct UsageSections: View {
    @EnvironmentObject var s: Store

    var maxPct: Double { max(s.fivePct ?? 0, s.sevenPct ?? 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Claude").font(.headline)
                Spacer()
                Circle().fill(s.paused ? .gray : sevColor(maxPct)).frame(width: 9, height: 9)
            }

            usageRow("5 小时会话", s.fivePct, s.fiveReset)
            usageRow("周限", s.sevenPct, s.sevenReset, weekly: true)
            if s.opusPct != nil { usageRow("周 · Opus", s.opusPct, s.opusReset, weekly: true) }
            if s.sonnetPct != nil { usageRow("周 · Sonnet", s.sonnetPct, s.sonnetReset, weekly: true) }

            Divider()
            HStack {
                Text("Codex").font(.headline)
                Spacer()
                if let p = s.codexPlan {
                    Text(p).font(.caption2).foregroundStyle(.secondary)
                }
            }
            codexRow("5 小时", s.codexPrimaryUsed, s.codexPrimaryReset, withDate: false)
            codexRow("周限", s.codexWeeklyUsed, s.codexWeeklyReset, withDate: true)
        }
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

    // Codex 行：剩余百分比 + 重置时间（withDate=true 时带日期，如 7月8日 04:59）
    @ViewBuilder
    func codexRow(_ title: String, _ used: Double?, _ reset: Date?, withDate: Bool) -> some View {
        let rolledOff = reset.map { $0 <= s.now } ?? false
        let usedNow = rolledOff ? 0 : (used ?? 0)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline).bold()
                Spacer()
                Text(used == nil ? "—" : "剩余 \(Int((100 - usedNow).rounded()))%")
                    .font(.subheadline).foregroundStyle(sevColor(usedNow))
            }
            UsageBar(value: usedNow / 100, color: sevColor(usedNow))
            if rolledOff {
                Text("已重置（快照过期，无实时数据）").font(.caption2).foregroundStyle(.secondary)
            } else if let r = reset {
                Text(withDate ? weeklyResetInfo(r, s.now) : "重置 \(localHM(r))")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("暂无快照").font(.caption2).foregroundStyle(.secondary)
            }
        }
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
            HStack {
                Text("Claude 保活").font(.caption)
                Spacer()
                Toggle("", isOn: $s.claudeAutoEnabled).toggleStyle(.switch).labelsHidden()
            }
            HStack {
                Text("Codex 保活").font(.caption)
                Spacer()
                Toggle("", isOn: $s.codexAutoEnabled).toggleStyle(.switch).labelsHidden()
            }
            HStack {
                Text("开机自启").font(.caption)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { s.launchAtLogin },
                    set: { s.setLaunchAtLogin($0) }
                )).toggleStyle(.switch).labelsHidden()
            }
            HStack {
                Text("自动查询").font(.caption)
                Spacer()
                Toggle("", isOn: $s.autoQueryOnOpen).toggleStyle(.switch).labelsHidden()
            }
            HStack {
                Text("隐藏倒计时").font(.caption)
                Spacer()
                Toggle("", isOn: $s.hideCountdown).toggleStyle(.switch).labelsHidden()
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

// 点击菜单栏图标弹出的主界面
struct ContentView: View {
    @EnvironmentObject var s: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            UsageSections()
            Divider()
            ControlSections()
        }
        .padding(14)
        .frame(width: 300)
        .onAppear {
            s.popupOpen = true
            if s.autoQueryOnOpen { s.refreshNow() }   // 打开弹窗时按开关决定是否自动查询用量
        }
        .onDisappear { s.popupOpen = false }
    }
}

// 悬停快照：鼠标在菜单栏图标上停 0.8 秒弹出，**不发任何请求**——只把当前内存里的数据画出来。
// 想要最新数值仍然点开弹窗（受“自动查询”开关控制）。底部一行标明数据新鲜度，避免把旧快照当实时值。
// 卡片的毛玻璃背景由 NSVisualEffectView 提供（见 HoverSnapshot.makePanel），这里只画内容，
// 不加 .background —— SwiftUI 的 .regularMaterial 在 NSHostingView 里是“窗口内混合”，
// 窗口背后是空的，糊出来就是一块不透明色块，和弹窗的观感对不上。
struct SnapshotView: View {
    @EnvironmentObject var s: Store

    var freshness: String {
        if s.paused { return "已暂停 · 快照" }
        guard let r = s.lastRefresh else { return "暂无数据 · 快照" }
        return "数据截至 \(localHM(r)) · 快照"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            UsageSections()
            Text(freshness).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 300)
    }
}

// MARK: - 悬停快照的 AppKit 承载
// MenuBarExtra 不暴露它的 NSStatusItem，所以“图标上悬停”只能自己在 AppKit 侧实现：
//   · 定位状态项按钮：在 NSApp.windows 里找 NSStatusBarButton（状态栏窗口属于本 App）。
//   · 判定悬停：每 0.25s 比一次 NSEvent.mouseLocation 与按钮屏幕矩形。
//     刻意不用全局事件监听——鼠标移动的全局监听在后台 App 上并不可靠，而 mouseLocation
//     是廉价同步调用，0.1s 一次的轮询对 0.8 秒的停留判定绰绰有余。
//   · 展示：无边框、不激活、不吃鼠标事件的浮动面板，钉在图标正下方。
@MainActor
final class HoverSnapshot {
    static let shared = HoverSnapshot()

    private let dwell: TimeInterval = 0.8        // 悬停多久才弹
    private let pollInterval: TimeInterval = 0.1 // 判定粒度：必须远小于 dwell，否则 0.8s 会拖成 1s 才弹

    private var store: Store?
    private var timer: Timer?
    private var panel: NSPanel?
    private var host: NSView?            // 快照内容的 NSHostingView（只用到 fittingSize / 布局）
    private var statusButton: NSStatusBarButton?
    private var hoverSince: Date?
    private var loggedButton = false

    func start(store: Store) {
        guard timer == nil else { return }
        self.store = store
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        guard let store else { return }
        // 主弹窗开着时不抢戏；状态项还没建好（启动瞬间）也直接跳过，下一轮再找
        guard !store.popupOpen, let frame = buttonFrame() else { reset(); return }
        guard frame.insetBy(dx: -1, dy: -1).contains(NSEvent.mouseLocation) else { reset(); return }
        if hoverSince == nil { hoverSince = Date() }
        if Date().timeIntervalSince(hoverSince!) >= dwell { show(under: frame) }
    }

    private func reset() {
        hoverSince = nil
        if panel?.isVisible == true { panel?.orderOut(nil) }
    }

    // 状态项按钮的屏幕矩形。按钮宽度会随标题变化（隐藏倒计时后只剩图标），所以每次都重算。
    private func buttonFrame() -> NSRect? {
        if statusButton?.window == nil { statusButton = HoverSnapshot.findStatusButton() }
        guard let b = statusButton, let w = b.window, b.bounds.width > 0 else { return nil }
        let f = w.convertToScreen(b.convert(b.bounds, to: nil))
        // 启动后头几十毫秒状态项还没被系统摆到菜单栏（frame 在屏幕外，如 {0,-26}），
        // 等它落到某块屏幕上再记这一行——否则日志记的是个没用的临时值。
        if !loggedButton, NSScreen.screens.contains(where: { $0.frame.intersects(f) }) {
            loggedButton = true   // 每次启动记一行：定位依赖 MenuBarExtra 的私有视图层级，将来失效时一眼可见
            store?.log("HOVER: 已定位状态项按钮 frame=\(NSStringFromRect(f))")
        }
        return f
    }

    private static func findStatusButton() -> NSStatusBarButton? {
        for w in NSApp.windows {
            if let b = firstStatusBarButton(w.contentView) { return b }
        }
        return nil
    }

    private static func firstStatusBarButton(_ v: NSView?) -> NSStatusBarButton? {
        guard let v else { return nil }
        if let b = v as? NSStatusBarButton { return b }
        for sub in v.subviews {
            if let b = firstStatusBarButton(sub) { return b }
        }
        return nil
    }

    private func show(under frame: NSRect) {
        if panel == nil { makePanel() }
        guard let panel, let host else { return }
        // 内容高度会随数据变化（Opus/Sonnet 行可能后来才出现），所以每轮都按当前内容重算尺寸与位置
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        if panel.frame.size != size { panel.setContentSize(size) }
        var x = frame.midX - size.width / 2
        if let vf = (statusButton?.window?.screen ?? NSScreen.main)?.visibleFrame {
            x = min(max(x, vf.minX + 8), max(vf.minX + 8, vf.maxX - size.width - 8))
        }
        panel.setFrameOrigin(NSPoint(x: x, y: frame.minY - size.height - 6))
        if !panel.isVisible { panel.orderFrontRegardless() }   // 不激活本 App，不抢焦点
    }

    private func makePanel() {
        guard let store else { return }
        // controlActiveState 强制为 .active：面板刻意不抢焦点，SwiftUI 便会按“非活动窗口”渲染，
        // 进度条的 .tint 会被灰掉。指定活动态后，快照里的进度条颜色与点开弹窗时完全一致。
        let view = NSHostingView(rootView: SnapshotView()
            .environmentObject(store)
            .environment(\.controlActiveState, .active))
        view.translatesAutoresizingMaskIntoConstraints = false

        // 卡片背景用 NSVisualEffectView 的 .behindWindow 混合 —— 这是弹窗那种“透出桌面”的
        // 毛玻璃唯一的来源；SwiftUI 的 Material 在无背景的浮动窗口里只会糊成一块实色。
        let fx = NSVisualEffectView()
        fx.material = .menu                 // 与菜单栏弹窗同款的系统菜单材质
        fx.blendingMode = .behindWindow
        fx.state = .active                  // 本 App 不激活也保持模糊，不随焦点变灰
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 12
        fx.layer?.cornerCurve = .continuous
        fx.layer?.masksToBounds = true
        fx.layer?.borderWidth = 1
        fx.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        fx.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            view.topAnchor.constraint(equalTo: fx.topAnchor),
            view.bottomAnchor.constraint(equalTo: fx.bottomAnchor)
        ])

        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.contentView = fx
        p.isFloatingPanel = true
        p.level = .statusBar                 // 与菜单栏同级：盖住普通窗口，又不越过系统菜单
        p.isOpaque = false
        p.backgroundColor = .clear           // 窗口本身透明，圆角+毛玻璃由上面的 NSVisualEffectView 画
        p.hasShadow = true
        p.ignoresMouseEvents = true          // 纯展示：不吃点击，不影响再点图标
        p.hidesOnDeactivate = false
        p.animationBehavior = .utilityWindow
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel = p
        host = view
    }
}

// AppDelegate 只负责一件事：启动后开始监视菜单栏图标上的悬停
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { HoverSnapshot.shared.start(store: Store.shared) }
    }
}

// MARK: - App 入口（菜单栏）
@main
struct KeepAliveBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = Store.shared

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
                // menuTitle 为空 = 隐藏倒计时：整段 Text 都不放，避免留下一块空白间距
                if !store.menuTitle.isEmpty { Text(store.menuTitle) }
            } else {
                // 没有图标资源时兜底：标题不能为空，否则状态项宽度为 0 就点不到了
                Text(store.menuTitle.isEmpty ? "◷" : store.menuTitle)
            }
        }
        .menuBarExtraStyle(.window)
    }
}
