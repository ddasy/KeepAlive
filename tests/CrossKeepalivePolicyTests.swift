import Foundation

extension TestSuite {
    func testCrossKeepalivePolicy() {
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

    }
}
