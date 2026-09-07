import Foundation

extension TestSuite {
    func testStoreScheduling() {
        let s = Store(preferences: defaults, monitoring: false)
        check(!s.codexFirst, "fresh install keeps Claude first")
        s.codexFirst = true
        check(Store(preferences: defaults, monitoring: false).codexFirst, "Codex-first order survives restart")
        s.codexFirst = false
        check(!Store(preferences: defaults, monitoring: false).codexFirst, "Claude-first order survives restart")
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
        let restored = Store(preferences: defaults, monitoring: false)
        check(restored.crossKeepaliveEnabled && restored.crossIntervalMinutes == 120, "settings persist")
        check(restored.crossWaitUntil(claude: true) != nil, "Codex anchor survives restart")
        check(restored.crossWaitUntil(claude: false) != nil, "Claude anchor survives restart")
        let statusStore = Store(preferences: defaults, monitoring: false)
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
    }
}
