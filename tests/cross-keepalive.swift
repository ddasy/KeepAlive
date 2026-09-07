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

        let s = Store(monitoring: false)
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
