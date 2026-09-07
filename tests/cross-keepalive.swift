import Foundation

@main
struct CrossKeepaliveTests {
    @MainActor static func main() {
        let defaults = UserDefaults.standard // runner substitutes an isolated suite
        defaults.removePersistentDomain(forName: "com.iu.keepalivebar.cross-tests")
        defer { defaults.removePersistentDomain(forName: "com.iu.keepalivebar.cross-tests") }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var checks = 0
        func check(_ condition: Bool, _ label: String) {
            precondition(condition, label)
            checks += 1
        }
        func delay(_ elapsed: Double) -> Date? {
            CrossKeepalivePolicy.deferredUntil(now: base.addingTimeInterval(elapsed), otherStart: base, minutes: 120)
        }
        check(delay(3600) == base.addingTimeInterval(7201), "13:00 Claude → 14:00 Codex waits until after 15:00")
        check(delay(7200) != nil, "equal threshold still waits")
        check(delay(7201) == nil, "strict threshold releases")
        check(delay(10800) == nil, "sufficient gap fires normally")
        check(CrossKeepalivePolicy.deferredUntil(now: base, otherStart: nil, minutes: 120) == nil, "unknown counterpart does not deadlock")
        check(CrossKeepalivePolicy.deferredUntil(now: base, otherStart: base.addingTimeInterval(1), minutes: 120) == nil, "future start ignored")
        check(CrossKeepalivePolicy.minutes(.nan) == 120, "invalid setting defaults")
        check(CrossKeepalivePolicy.minutes(200) == 145, "unsustainable threshold clamped")
        check(CrossKeepalivePolicy.minutes(-1) == 30, "lower bound")
        check(CrossKeepalivePolicy.claudeFirst(claudeEnd: base, codexEnd: base.addingTimeInterval(1)), "earlier Claude wins")
        check(!CrossKeepalivePolicy.claudeFirst(claudeEnd: base, codexEnd: base.addingTimeInterval(-1)), "earlier Codex wins")
        check(CrossKeepalivePolicy.claudeFirst(claudeEnd: base, codexEnd: base), "tie is deterministic")

        do {
        let s = Store(monitoring: false)
        let soon = base.addingTimeInterval(3600)
        let later = base.addingTimeInterval(7200)
        func order(_ cEnd: Date?, _ cUsed: Double?, _ xEnd: Date?, _ xUsed: Double?, current: Bool = false) -> Bool {
            AutomaticOrder.codexFirst(current: current, now: base,
                claudeEnd: cEnd, claudeUsed: cUsed, codexEnd: xEnd, codexUsed: xUsed)
        }
        check(order(later, 20, soon, 40), "earlier Codex deadline wins")
        check(!order(soon, 20, later, 40, current: true), "earlier Claude deadline wins")
        check(order(soon, 100, later, 40), "available Codex overrides exhausted earlier Claude")
        check(!order(later, 20, soon, 100, current: true), "available Claude overrides exhausted earlier Codex")
        check(order(soon, 100, nil, 0), "idle available Codex replaces exhausted Claude")
        check(order(soon, 100, later, 100, current: true), "both exhausted preserve order")
        check(order(soon, 20, soon, 40, current: true), "equal deadlines preserve order")
        check(!order(nil, nil, nil, nil), "missing data preserves order")
        check(!order(base.addingTimeInterval(18000), 20, base.addingTimeInterval(18001), 40, current: true), "five-hour eligibility boundary")
        check(order(later, 100, base.addingTimeInterval(-1), 100), "expired Codex exhaustion no longer blocks switching")
        check(!s.automaticSorting, "automatic sorting defaults off")
        s.now = base
        s.fiveReset = later
        s.fivePct = 10
        s.codexPrimaryReset = soon
        s.codexPrimaryUsed = 30
        s.automaticSorting = true
        check(s.displayedCodexFirst, "store applies automatic order")
        check(Store(monitoring: false).automaticSorting, "automatic sorting preference persists")
        s.codexPrimaryUsed = 100
        check(!s.displayedCodexFirst, "usage update immediately changes displayed order")
        s.automaticSorting = false
        check(!s.displayedCodexFirst, "disabling automatic sorting restores manual order")
        s.paused = false
        s.hideCountdown = false
        s.crossKeepaliveEnabled = false
        s.windowEnd = later
        s.codexPrimaryReset = base.addingTimeInterval(21 * 60)
        s.codexPrimaryUsed = 30
        s.automaticSorting = true
        check(s.menuTitle == "21m", "automatic Codex promotion shows its 21-minute countdown")
        s.codexPrimaryUsed = 100
        check(s.menuTitle == "2h00m", "exhausted Codex switches countdown back to Claude")
        s.automaticSorting = false
        s.codexFirst = true
        check(s.menuTitle == "21m", "manual Codex promotion also switches countdown")
        s.codexPrimaryReset = nil
        check(s.menuTitle == "–", "missing Codex window does not display Claude countdown")
        s.codexWindowClosed = true
        check(s.menuTitle == "now", "closed Codex window shows now")
        s.hideCountdown = true
        check(s.menuTitle.isEmpty, "hidden countdown remains hidden with Codex first")
        s.paused = true
        check(s.menuTitle == "⏸", "pause indicator remains visible")
        }
        defaults.removePersistentDomain(forName: "com.iu.keepalivebar.cross-tests")
        let s = Store(monitoring: false)
        check(!s.codexFirst, "fresh install keeps Claude first")
        s.codexFirst = true
        check(Store(monitoring: false).codexFirst, "Codex-first order survives restart")
        s.codexFirst = false
        check(!Store(monitoring: false).codexFirst, "Claude-first order survives restart")
        s.paused = false
        s.claudeAutoEnabled = true
        s.codexAutoEnabled = true
        s.crossKeepaliveEnabled = true
        s.crossIntervalMinutes = 120
        let current = Date()
        s.windowEnd = current.addingTimeInterval(4 * 3600) // Claude started one hour ago
        s.codexWindowClosed = true
        check(s.crossWaitUntil(claude: false) != nil, "Codex defers against Claude server window")
        check(s.crossWaitUntil(claude: true) == nil, "first side has no counterpart anchor")
        s.windowEnd = current.addingTimeInterval(2 * 3600)
        check(s.crossWaitUntil(claude: false) == nil, "three-hour gap allowed")
        s.windowEnd = current.addingTimeInterval(4.5 * 3600)
        check(s.crossWaitUntil(claude: false)! > current.addingTimeInterval(5300), "manual new window recalculates deadline")
        s.crossIntervalMinutes = 30
        check(s.crossWaitUntil(claude: false)! < current.addingTimeInterval(2), "threshold change recalculates deadline")
        s.crossIntervalMinutes = 120
        s.codexAutoEnabled = false
        check(s.crossWaitUntil(claude: false) == nil, "one side disabled restores independent mode")
        s.codexAutoEnabled = true
        s.paused = true
        check(s.crossWaitUntil(claude: false) == nil, "pause disables cross scheduling")
        s.paused = false
        s.crossKeepaliveEnabled = false
        check(s.crossWaitUntil(claude: false) == nil, "feature off preserves old behavior")
        s.crossKeepaliveEnabled = true
        s.codexPrimaryReset = current.addingTimeInterval(4 * 3600)
        s.codexPrimaryReset = nil
        check(s.crossWaitUntil(claude: true) != nil, "closed/unknown snapshot retains confirmed anchor")
        let restored = Store(monitoring: false)
        check(restored.crossKeepaliveEnabled && restored.crossIntervalMinutes == 120, "settings persist")
        check(restored.crossWaitUntil(claude: true) != nil, "Codex anchor survives restart")
        check(restored.crossWaitUntil(claude: false) != nil, "Claude anchor survives restart")
        let statusStore = Store(monitoring: false)
        statusStore.paused = false
        statusStore.claudeAutoEnabled = true
        statusStore.codexAutoEnabled = true
        statusStore.crossKeepaliveEnabled = true
        statusStore.windowEnd = current.addingTimeInterval(4 * 3600)
        statusStore.codexPrimaryReset = current.addingTimeInterval(3 * 3600)
        check(statusStore.crossStatus == "当前实际间隔：1h 0m", "status shows actual window-start gap")
        s.windowEnd = current.addingTimeInterval(-7200)
        s.codexPrimaryReset = current.addingTimeInterval(100)
        s.codexPrimaryReset = current.addingTimeInterval(-3600)
        s.codexWindowClosed = true
        check(!s.crossYieldsPriority(claude: true), "overdue earlier Claude has priority")
        check(s.crossYieldsPriority(claude: false), "overdue later Codex yields")
        s.codexPrimaryReset = current.addingTimeInterval(-10800)
        check(s.crossYieldsPriority(claude: true), "overdue earlier Codex has priority")
        check(!s.crossYieldsPriority(claude: false), "earlier Codex proceeds")
        s.codexPrimaryReset = current.addingTimeInterval(-3600)
        s.sevenPct = 100
        s.sevenReset = current.addingTimeInterval(86400)
        check(!s.crossYieldsPriority(claude: false), "weekly-blocked counterpart cannot starve Codex")
        s.sevenPct = 0
        s.lastFire = current // newly successful CLI fire, server snapshot not yet updated
        check(s.crossWaitUntil(claude: false) != nil, "new successful fire supersedes obsolete window")
        // 模拟八次续窗，验证延后不会让每轮互相推迟或挤回同一时间。
        var ends = [base, base.addingTimeInterval(3600)]
        var starts = ends.map { $0.addingTimeInterval(-18000) }
        var previous: Date?
        for _ in 0..<8 {
            let side = ends[0] <= ends[1] ? 0 : 1
            let due = ends[side]
            let sent = CrossKeepalivePolicy.deferredUntil(now: due, otherStart: starts[1-side], minutes: 120) ?? due
            if let previous { check(sent.timeIntervalSince(previous) > 7200, "successive renewals stay separated") }
            check(sent.timeIntervalSince(due) <= 3601, "no accumulating delay across cycles")
            starts[side] = sent
            ends[side] = sent.addingTimeInterval(18000)
            previous = sent
        }
        print("PASS: \(checks) cross-keepalive checks (no network or inference requests)")
    }
}
