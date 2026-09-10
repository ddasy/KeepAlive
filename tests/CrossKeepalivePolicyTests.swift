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

        // base 正好落在半点网格上（1_800_000_000 = 1_000_000 × 1800），可直接当相位锚点。
        check(CrossKeepalivePolicy.alignedUp(base, anchor: base) == base, "grid point stays put")
        check(CrossKeepalivePolicy.alignedUp(base.addingTimeInterval(1), anchor: base) == base.addingTimeInterval(1800),
              "mid-grid target snaps up")
        check(CrossKeepalivePolicy.alignedUp(base.addingTimeInterval(1), anchor: base.addingTimeInterval(-1)) == base.addingTimeInterval(1800),
              "±1s boundary jitter does not shift the grid")
        check(CrossKeepalivePolicy.alignedUp(base.addingTimeInterval(-1799), anchor: base) == base,
              "target below the anchor still rounds up")
        check(CrossKeepalivePolicy.alignedUp(base, anchor: nil) == base, "no anchor leaves the target untouched")

        // 回归 09-10 实测：Codex 18:19:34 起窗，Claude 延后到 20:19:35 开火，
        // 服务端却把窗口起点向下取整到 20:10:00 → 实际间隔恒为 1h50m，永远够不到 2h。
        let codexStart = base.addingTimeInterval(-575)          // 比网格点早 9m35s
        let deadline = CrossKeepalivePolicy.deferredUntil(
            now: codexStart.addingTimeInterval(1), otherStart: codexStart, minutes: 120, gridAnchor: base)!
        check(deadline == base.addingTimeInterval(7200), "Claude wait target snaps up to its window grid")
        check(deadline.timeIntervalSince(codexStart) > 7200, "aligned start difference clears the threshold")
        check(deadline.timeIntervalSince(codexStart.addingTimeInterval(7201)) < 1800, "alignment costs at most one grid")

        // 模拟八轮续窗，Claude 侧按服务端规则把开火时刻向下取整到网格，
        // 断言两侧**窗口起点**的实际差值始终大于阈值（旧实现在这里会稳定停在 6626s）。
        func floorToGrid(_ t: Date) -> Date {
            var rem = (t.timeIntervalSince1970 - base.timeIntervalSince1970).truncatingRemainder(dividingBy: 1800)
            if rem < 0 { rem += 1800 }
            return t.addingTimeInterval(-rem)
        }
        // 种子即 09-10 现场的定格状态：Claude 起点在网格上，Codex 起点比它早 6626s（1h50m26s）。
        var claudeStart = base
        var codexRunning = base.addingTimeInterval(-6626)
        for cycle in 0..<8 {
            let claudeEnd = claudeStart.addingTimeInterval(18000)
            let codexEnd = codexRunning.addingTimeInterval(18000)
            if claudeEnd <= codexEnd {
                let sent = CrossKeepalivePolicy.deferredUntil(
                    now: claudeEnd, otherStart: codexRunning, minutes: 120, gridAnchor: claudeEnd) ?? claudeEnd
                claudeStart = floorToGrid(sent)
            } else {
                codexRunning = CrossKeepalivePolicy.deferredUntil(
                    now: codexEnd, otherStart: claudeStart, minutes: 120) ?? codexEnd
            }
            check(abs(claudeStart.timeIntervalSince(codexRunning)) > 7200,
                  "cycle \(cycle): actual window-start gap stays above the threshold")
        }
    }
}
