import Foundation

extension TestSuite {
    func testPresentation() {
        let s = Store(preferences: defaults, monitoring: false)
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
        check(Store(preferences: defaults, monitoring: false).automaticSorting, "automatic sorting preference persists")
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
}
