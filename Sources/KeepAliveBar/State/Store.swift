import Foundation
import Combine
import ServiceManagement

@MainActor
final class Store: ObservableObject {
    // 同一模块中的按职责扩展共用此状态；所有变更受 MainActor 隔离。
    // 运行标记为 internal 是 Swift 跨文件扩展访问所需，界面只使用发布状态和操作方法。
    // 单例：SwiftUI 场景与 AppDelegate（悬停快照）共用同一份状态
    static let shared = Store()
    let preferences: UserDefaults
    let monitoringEnabled: Bool

    @Published var fivePct: Double?
    @Published var fiveReset: Date?       // 接口原始 five_hour.resets_at（窗口过期后可能为 null → nil）
    // windowEnd：我们信任并倒计时的“当前 5h 窗口结束时刻”。只要服务端返回未来的 five_hour.resets_at
    // 就更新它；窗口过期后接口把 resets_at 变 null/过去，它保持粘滞（仍指向旧窗口末尾），
    // 于是能可靠判定“已关闭”并续窗——不依赖 is_active（实测活动期间它也是 false，不可信）。
    @Published var windowEnd: Date? {
        didSet {
            if let end = windowEnd {
                preferences.set(end.timeIntervalSince1970, forKey: "windowEnd")
            } else {
                preferences.removeObject(forKey: "windowEnd")
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
    @Published var codexPrimaryReset: Date? {
        didSet {
            // nil（空闲）不能抹掉上次已确认的周期，否则重启后会丢失交叉依据。
            if let end = codexPrimaryReset, end > Date() {
                codexCrossWindowEnd = end
                preferences.set(end.timeIntervalSince1970, forKey: "codexCrossWindowEnd")
            }
        }
    }
    var codexCrossWindowEnd: Date?
    @Published var codexWeeklyUsed: Double?
    @Published var codexWeeklyReset: Date?
    @Published var codexSnapshotAt: Date?
    // 服务端明确"当前没有活动 5h 窗口"。只由 wham/usage 置位（本地 rollout 日志区分不出
    // "窗口关着"和"没记录"，那条路走时间兜底）。为 true 时该立刻开火，而不是等 codexPrimaryReset。
    @Published var codexWindowClosed = false
    @Published var codexLastFire: Date?
    @Published var codexLastFireFailed = false
    @Published var codexLastFireResult: String = ""
    @Published var claudeLoginExpiresAt: Date?
    var lastLoginExpiryCheck: Date?
    var checkingLoginExpiry = false
    @Published var lastError: String?
    @Published var lastFire: Date?
    @Published var lastFireFailed = false
    @Published var lastFireResult: String = ""
    @Published var busyFiring = false
    @Published var now: Date = Date()
    // 保活开关拆成两路：Claude / Codex 各自独立，互不影响（旧版单一 autoEnabled 键在 init 里迁移）
    @Published var claudeAutoEnabled: Bool {
        didSet { preferences.set(claudeAutoEnabled, forKey: "claudeAutoEnabled") }
    }
    @Published var codexAutoEnabled: Bool {
        didSet { preferences.set(codexAutoEnabled, forKey: "codexAutoEnabled") }
    }
    @Published var crossKeepaliveEnabled: Bool {
        didSet { preferences.set(crossKeepaliveEnabled, forKey: "crossKeepaliveEnabled") }
    }
    @Published var crossIntervalMinutes: Double {
        didSet { preferences.set(CrossKeepalivePolicy.minutes(crossIntervalMinutes), forKey: "crossIntervalMinutes") }
    }
    @Published var launchAtLogin: Bool = false
    @Published var paused: Bool {                                 // 暂停：停止 GET 与续窗
        didSet { preferences.set(paused, forKey: "paused") }
    }
    @Published var autoQueryOnOpen: Bool {                        // 打开菜单栏弹窗时是否自动查询一次用量
        didSet { preferences.set(autoQueryOnOpen, forKey: "autoQueryOnOpen") }
    }
    @Published var hideCountdown: Bool {                          // 隐藏倒计时：菜单栏只留图标
        didSet { preferences.set(hideCountdown, forKey: "hideCountdown") }
    }
    @Published var visibleMenuControls: [String] {
        didSet { preferences.set(visibleMenuControls, forKey: "visibleMenuControls") }
    }
    func showsMenuControl(_ control: MenuControl) -> Bool {
        visibleMenuControls.contains(control.rawValue)
    }
    // 两个区域使用同一份配置分组，并保持原始控件顺序。
    func menuControls(hidden: Bool) -> [MenuControl] {
        MenuControl.allCases.filter { showsMenuControl($0) != hidden }
    }

    func setMenuControl(_ control: MenuControl, visible: Bool) {
        visibleMenuControls.removeAll { $0 == control.rawValue }
        if visible { visibleMenuControls.append(control.rawValue) }
    }

    @Published var menuBarFillOpacity: Double {
        didSet { preferences.set(menuBarFillOpacity, forKey: "menuBarFillOpacity") }
    }
    @Published var menuBarTrackOpacity: Double {
        didSet { preferences.set(menuBarTrackOpacity, forKey: "menuBarTrackOpacity") }
    }

    static func normalizedOpacity(_ value: Double, fallback: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : fallback
    }

    @Published var popupOpen = false                              // 主弹窗是否正开着（悬停快照据此避让，见 HoverSnapshot）
    @Published var codexFirst: Bool {
        didSet { preferences.set(codexFirst, forKey: "codexFirst") }
    }
    @Published var automaticSorting: Bool {
        didSet { preferences.set(automaticSorting, forKey: "automaticSorting") }
    }
    let bufferSec: TimeInterval = 90        // 真实重置时刻之后再等这么久才发（确保旧窗口确已关闭）
    let retryIntervalSec: TimeInterval = 180 // 两次“尝试”最小间隔：失败/未续窗时按此退避重试（3 分钟）
    let refreshRetryIntervalSec: TimeInterval = 180 // 用量查询失败/缺少窗口时间时的退避基数（3 分钟起，指数增长）
    let refreshRetryMaxIntervalSec: TimeInterval = 1800 // 退避上限 30 分钟
    let tokenRefreshBufferSec: TimeInterval = 300 // token 剩余寿命少于 5 分钟就提前换，别卡在边界上发请求
    let codexBufferSec: TimeInterval = 90
    let codexRetryIntervalSec: TimeInterval = 180
    let codexFallbackSec: TimeInterval = 18000 // 没有 reset 快照时，连续 5 小时后首次激活
    let codexMinRefireSec: TimeInterval = 17400 // 成功后至少 4h50m 不重复发送
    var lastAttempt: Date?          // 上次尝试时间（成功/失败都记）
    var codexLastAttempt: Date?
    var codexNoSnapshotSince: Date?
    var weeklyBlockLoggedAt: Date?  // Codex 周限拦截日志的节流时刻（每小时最多一条）
    var claudeWeeklyRecheckAt: Date? // Claude 周限满时的下次联网复查时刻（稀疏复查，不再 3 分钟一轮）
    var lastCrossRefresh: Date?
    var crossRefreshing = false
    var lastCrossWaitLog: [String: Date] = [:]
    var lastCodexPoll: Date?
    var codexUsageSourceLoggedAt: Date?   // "退回 rollout" 提示的节流时刻（每小时最多一条）
    var codexActing = false
    var refreshRetryTask: Task<Void, Never>?
    var refreshRetryFailures = 0     // 连续失败次数 → scheduleRefreshRetry 的指数退避指数（成功即清零）
    var busyRefreshingToken = false  // token 刷新单飞：只防自己并发，不防 CLI（见 refreshOAuthToken 注释）
    let keychainService = "Claude Code-credentials"
    let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    // ---- 直连保活 ----------------------------------------------------------
    // 保活只需要"一条计费到订阅的推理请求"。CLI 会额外背上工具定义、系统提示词、全局
    // CLAUDE.md/AGENTS.md、skills 清单——对"开窗"毫无贡献，却占了 99.9% 的 token。
    // 实测（2026-09-06，同机同账号）：
    //   claude -p 'Reply OK' --model haiku    → 22,698 in / 51 out
    //   直连 POST /v1/messages                →      8 in /  1 out
    //   codex exec 'Reply OK'                 → 13,871 in / 16 out
    //   直连 POST .../codex/responses         →     14 in / 16 out
    // Codex 侧已实证：一条 30 token 的裸 HTTP 请求确实开出完整的新 5 小时窗口。
    // **没有自动降级**：直连失败或"发了但没开出窗口"时会明确报错并按原节奏重试，
    // 好让问题第一时间暴露，而不是被 CLI 补发掩盖成"一切正常"。
    // 想整体退回 CLI 写法：UserDefaults 里把 directFire 设为 false（无 UI 开关，调试用）。
    let claudeAPIURL = URL(string: "https://api.anthropic.com/v1/messages")!
    let claudeAPIModel = "claude-haiku-4-5-20251001"   // CLI 收别名(haiku)，HTTP 要完整 id
    let codexResponsesURL = URL(string: "https://chatgpt.com/backend-api/codex/responses")!
    let codexUsageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    var directFireEnabled: Bool {
        (preferences.object(forKey: "directFire") as? Bool) ?? true
    }

    private var tickTimer: Timer?
    var acting = false   // 正在处理“窗口关闭”（联网确认+续窗），防重入

    var home: String { NSHomeDirectory() }
    var supportDir: String { "\(NSHomeDirectory())/Library/Application Support/KeepAliveBar" }

    // 每次保活使用一个全新的系统临时目录。命令结束后由调用方立即删除，避免留下
    // 任何项目文件、CLAUDE.md、git 元数据或历史保活目录可被下一次命令读取。
    func makeTemporaryKeepaliveDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeepAliveBar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    init(preferences: UserDefaults = .standard, monitoring: Bool = true) {
        self.preferences = preferences
        self.monitoringEnabled = monitoring
        self.codexFirst = preferences.bool(forKey: "codexFirst")
        self.automaticSorting = preferences.bool(forKey: "automaticSorting")
        // 迁移：旧版只有一个 autoEnabled，拆分后它作为两路开关的默认值（都没写过新键时）
        let legacyAuto = (preferences.object(forKey: "autoEnabled") as? Bool) ?? true
        self.claudeAutoEnabled = (preferences.object(forKey: "claudeAutoEnabled") as? Bool) ?? legacyAuto
        self.codexAutoEnabled = (preferences.object(forKey: "codexAutoEnabled") as? Bool) ?? legacyAuto
        self.crossKeepaliveEnabled = preferences.bool(forKey: "crossKeepaliveEnabled")
        self.crossIntervalMinutes = CrossKeepalivePolicy.minutes(
            (preferences.object(forKey: "crossIntervalMinutes") as? Double) ?? 120)
        if let t = preferences.object(forKey: "codexCrossWindowEnd") as? Double {
            self.codexCrossWindowEnd = Date(timeIntervalSince1970: t)
        }
        self.paused = preferences.bool(forKey: "paused")   // 默认 false
        self.autoQueryOnOpen = (preferences.object(forKey: "autoQueryOnOpen") as? Bool) ?? true
        // 缺少配置才恢复原始的全部显示布局；已保存的空数组代表全部隐藏。
        self.visibleMenuControls = preferences.stringArray(forKey: "visibleMenuControls")
            ?? MenuControl.allCases.map(\.rawValue)
        self.menuBarFillOpacity = Self.normalizedOpacity(
            (preferences.object(forKey: "menuBarFillOpacity") as? Double) ?? 1, fallback: 1)
        self.menuBarTrackOpacity = Self.normalizedOpacity(
            (preferences.object(forKey: "menuBarTrackOpacity") as? Double) ?? 0.22, fallback: 0.22)
        self.hideCountdown = preferences.bool(forKey: "hideCountdown")   // 默认 false（显示倒计时）
        if let t = preferences.object(forKey: "windowEnd") as? Double {
            self.windowEnd = Date(timeIntervalSince1970: t)
        }
        if let t = preferences.object(forKey: "lastFire") as? Double {
            self.lastFire = Date(timeIntervalSince1970: t)
        }
        if let t = preferences.object(forKey: "codexLastFire") as? Double {
            self.codexLastFire = Date(timeIntervalSince1970: t)
        }
        if let t = preferences.object(forKey: "codexLastAttempt") as? Double {
            self.codexLastAttempt = Date(timeIntervalSince1970: t)
        }
        if let t = preferences.object(forKey: "codexNoSnapshotSince") as? Double {
            self.codexNoSnapshotSince = Date(timeIntervalSince1970: t)
        }
        guard monitoring else { return } // 测试仅恢复状态，不启动网络、定时器或授权预热
        refreshLoginExpiryIfNeeded()
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

}
