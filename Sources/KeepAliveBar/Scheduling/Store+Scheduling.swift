import Foundation

extension Store {
    var crossActive: Bool { crossKeepaliveEnabled && claudeAutoEnabled && codexAutoEnabled && !paused }
    var claudeIsDue: Bool {
        windowEnd.map { Date().timeIntervalSince($0) >= bufferSec } ?? (lastRefresh != nil && fiveReset == nil)
    }
    var codexIsDue: Bool {
        codexWindowClosed || (codexPrimaryReset.map { Date().timeIntervalSince($0) >= codexBufferSec } ?? false)
    }

    func crossWindowStart(claude: Bool) -> Date? {
        // 重置时间减 5h 是服务端周期起点；只在没有真值时用成功发送时间兜底。
        let end = claude ? windowEnd : codexCrossWindowEnd
        let fire = claude ? lastFire : codexLastFire
        if let end, !(fire.map { $0 > end } ?? false) {
            return end.addingTimeInterval(-CrossKeepalivePolicy.window)
        } else {
            return fire
        }
    }

    func crossWaitUntil(claude: Bool) -> Date? {
        guard crossActive else { return nil }
        return CrossKeepalivePolicy.deferredUntil(
            now: Date(),
            otherStart: crossWindowStart(claude: !claude),
            minutes: crossIntervalMinutes)
    }

    func crossAllowsFire(claude: Bool) -> Bool {
        guard let until = crossWaitUntil(claude: claude) else { return true }
        let who = claude ? "Claude" : "Codex"
        if lastCrossWaitLog[who] != until {
            lastCrossWaitLog[who] = until
            log("CROSS \(who) 交叉保活：延后至 \(fmt(until))，间隔须大于 \(Int(crossIntervalMinutes)) 分钟")
        }
        return false
    }

    // 失败重试中的一方不占优先权，避免另一方一直饿死。
    func crossYieldsPriority(claude: Bool) -> Bool {
        guard crossActive, claudeIsDue, codexIsDue else { return false }
        let otherAttempt = claude ? codexLastAttempt : lastAttempt
        if let attempt = otherAttempt, Date().timeIntervalSince(attempt) < retryIntervalSec { return false }
        if claude ? codexWeeklyBlocked : claudeWeeklyBlocked { return false }
        let first = CrossKeepalivePolicy.claudeFirst(claudeEnd: windowEnd, codexEnd: codexPrimaryReset ?? codexCrossWindowEnd)
        return claude != first
    }

    var crossStatus: String {
        if paused { return "已暂停交叉调度" }
        if !claudeAutoEnabled || !codexAutoEnabled { return "同时开启两侧保活后生效" }
        if claudeIsDue, let until = crossWaitUntil(claude: true) {
            return "Claude 交叉等待至 \(localMDHM(until))"
        }
        if codexIsDue, let until = crossWaitUntil(claude: false) {
            return "Codex 交叉等待至 \(localMDHM(until))"
        }
        guard let claudeStart = crossWindowStart(claude: true),
              let codexStart = crossWindowStart(claude: false) else {
            return "当前实际间隔：暂无数据"
        }
        let interval = abs(claudeStart.timeIntervalSince(codexStart))
        return "当前实际间隔：\(Store.dhm(interval))"
    }

    func tick() {
        guard !paused else { return }   // 暂停：不倒计时、不联网、不续窗
        now = Date()   // 本地倒计时（不联网）
        // 交叉模式需周期性读两边真值，识别用户在等待期间自行开启的新窗口。
        if crossActive, !crossRefreshing,
           lastCrossRefresh.map({ now.timeIntervalSince($0) >= 300 }) ?? true {
            crossRefreshing = true
            lastCrossRefresh = now
            Task {
                await refresh()
                crossRefreshing = false
                maybeAct()
                maybeActCodex()
            }
        }
        maybeAct()     // 只有到点了才会去联网确认并续窗
        // Codex 用量默认每 5 分钟查一次。但 Codex 的窗口是从**消息时刻**起算的
        //（Claude 是按半点对齐，03:31 发的消息落进 03:30–08:30，早发晚发不亏），
        // 所以 Codex 这边晚发一秒就真少一秒：实测 04:13:43 重置、5 分钟节奏到 04:17:03 才发现，
        // 这一轮白丢 3 分 23 秒。于是"已知窗口到点 / 服务端说没窗口"时把间隔收紧到 20s，
        // 平均损耗从 ~2.5 分钟降到 ~10 秒。开火成功后 reset 回到未来 → 自动恢复 300s 节奏。
        // 收紧只在真正等着开窗时生效：关掉 Codex 保活、周限已满、或正在开火时都不收紧，
        // 免得在"永远不会开火"的状态里 20s 一次空转（wham/usage 免费，但没必要）。
        let codexDue = codexAutoEnabled && !codexWeeklyBlocked && !codexActing
            && crossWaitUntil(claude: false) == nil
            && ((codexPrimaryReset.map { now >= $0 } ?? false) || codexWindowClosed)
        let codexPollInterval: TimeInterval = codexDue ? 20 : 300
        if lastCodexPoll == nil || now.timeIntervalSince(lastCodexPoll!) >= codexPollInterval {
            lastCodexPoll = now
            Task { [weak self] in
                guard let self else { return }
                await self.readCodexUsage()
                self.maybeActCodex()
            }
        }
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
        guard claudeAutoEnabled, !paused, windowEnd == nil, !busyFiring, !acting, !codexActing else { return }
        guard !crossYieldsPriority(claude: true), crossAllowsFire(claude: true) else { return }
        if claudeWeeklyBlocked {
            log("BOOTSTRAP skip: Claude 周限 \(pctStr(sevenPct)) 已用尽（重置 \(fmt(sevenReset))）")
            return
        }
        let current = Date()
        let mostRecent = [lastAttempt, lastFire].compactMap { $0 }.max()
        if let recent = mostRecent, current.timeIntervalSince(recent) < retryIntervalSec { return }
        log("BOOTSTRAP: usage 查询成功但 windowEnd=nil → 用 Haiku 发送 Reply OK 激活 5 小时窗口")
        Task { await fire() }
    }

    // 纯本地判断：本地倒计时（对 windowEnd）是否已过。到点才触发一次“联网确认 + 续窗”，平时不联网。
    // 用粘滞的 windowEnd 而非原始 fiveReset：即使接口在过期后把 resets_at 变 null / 未来，
    // windowEnd 仍指向旧窗口末尾（已过去）→ 能持续触发续窗与退避重试，不会像旧代码那样卡死。
    func maybeAct() {
        guard claudeAutoEnabled, !paused, !busyFiring, !acting, !codexActing, !crossRefreshing else { return }
        let now = Date()
        // 距上次“尝试”不足 retryIntervalSec 则不动（失败/未续窗时按此退避重试）
        if let la = lastAttempt, now.timeIntervalSince(la) < retryIntervalSec { return }
        guard let end = windowEnd else { return }   // 还没追踪任何活动窗口 → 不动
        // 周限已满：不必每 3 分钟联网撞一次墙，按 claudeWeeklyRecheckAt 稀疏复查（见 handleWindowClosed）
        if claudeWeeklyBlocked, let until = claudeWeeklyRecheckAt, now < until { return }
        if now.timeIntervalSince(end) >= bufferSec { // 本地倒计时已过窗口末尾 → 该确认并续窗
            guard !crossYieldsPriority(claude: true), crossAllowsFire(claude: true) else { return }
            log("maybeAct → handleWindowClosed (windowEnd=\(fmt(end)) 已过 \(Int(now.timeIntervalSince(end)))s)")
            Task { await handleWindowClosed() }
        }
    }

    // 到点了：先联网确认最新状态，再决定是否续窗。
    // refresh() 会在“确有活动窗口（重置在未来）”时把 windowEnd 推到未来——
    // 这只可能是用户自己开了新窗、或我们上次 fire 已成功。此时无需再发。
    // 否则 windowEnd 仍是过去（旧窗口已关且没新窗口）→ 续窗。这样不依赖 is_active，也不会误判活动期。
    func handleWindowClosed() async {
        guard claudeAutoEnabled, !paused, !acting, !busyFiring, !codexActing else { return }
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
}
