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
        check(CrossKeepalivePolicy.alignedNearest(base.addingTimeInterval(14 * 60), anchor: base) == base,
              "nearest grid rounds below half down")
        check(CrossKeepalivePolicy.alignedNearest(base.addingTimeInterval(16 * 60), anchor: base) == base.addingTimeInterval(1800),
              "nearest grid rounds above half up")
        check(CrossKeepalivePolicy.alignedNearest(base.addingTimeInterval(15 * 60), anchor: base) == base,
              "nearest grid ties go to the earlier point")
        check(CrossKeepalivePolicy.alignedNearest(base.addingTimeInterval(16 * 60), anchor: base.addingTimeInterval(-1)) == base.addingTimeInterval(1800),
              "nearest grid ignores minus-one-second anchor jitter")
        check(CrossKeepalivePolicy.alignedNearest(base.addingTimeInterval(14 * 60), anchor: base.addingTimeInterval(1)) == base,
              "nearest grid ignores plus-one-second anchor jitter")

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

    func testCenteredCrossKeepalivePolicy() {
        let center = CrossKeepalivePolicy.centerMinutes * 60
        let other = base
        check(CrossKeepalivePolicy.centeredDeferredUntil(
            now: base, otherStart: other) == base.addingTimeInterval(center),
            "Codex centered mode defers to the exact 150-minute target")
        check(CrossKeepalivePolicy.centeredDeferredUntil(
            now: base.addingTimeInterval(center), otherStart: other) == nil,
            "centered mode does not defer once the target is reached")
        check(CrossKeepalivePolicy.centeredDeferredUntil(
            now: base.addingTimeInterval(center + 1), otherStart: other) == nil,
            "centered mode does not defer when already past the target")
        check(CrossKeepalivePolicy.centeredDeferredUntil(
            now: base, otherStart: nil) == nil,
            "centered mode does not deadlock on an unknown counterpart")
        check(CrossKeepalivePolicy.centeredDeferredUntil(
            now: base, otherStart: base.addingTimeInterval(1)) == nil,
            "centered mode ignores a future counterpart")

        // Claude's target is 16 minutes after the grid point, so it waits for the nearer
        // later grid point; 14 minutes is nearer the current point, which is already due.
        let aboveHalfStart = base.addingTimeInterval(-134 * 60)
        check(CrossKeepalivePolicy.centeredDeferredUntil(
            now: base, otherStart: aboveHalfStart, gridAnchor: base) == base.addingTimeInterval(1800),
            "Claude centered mode rounds an above-half target to the nearer later grid")
        let belowHalfStart = base.addingTimeInterval(-136 * 60)
        check(CrossKeepalivePolicy.centeredDeferredUntil(
            now: base, otherStart: belowHalfStart, gridAnchor: base) == nil,
            "Claude centered mode fires immediately when the nearer earlier grid has passed")

        func floorToGrid(_ time: Date) -> Date {
            var rem = (time.timeIntervalSince1970 - base.timeIntervalSince1970)
                .truncatingRemainder(dividingBy: CrossKeepalivePolicy.grid)
            if rem < 0 { rem += CrossKeepalivePolicy.grid }
            return time.addingTimeInterval(-rem)
        }

        // Once one or both sides have had the one necessary wait, later renewals should
        // never wait again. Codex's four-second polling lag is included in its observed now.
        for initialGapMinutes in [10.0, 60.0, 137.0, 200.0, 280.0] {
            var claudeStart = base
            var codexStart = base.addingTimeInterval(initialGapMinutes * 60)
            var waits = [0, 0] // Claude, Codex

            for cycle in 0..<8 {
                let claudeDue = claudeStart.addingTimeInterval(CrossKeepalivePolicy.window)
                let codexDue = codexStart.addingTimeInterval(CrossKeepalivePolicy.window)
                let claude = claudeDue <= codexDue
                let due = claude ? claudeDue : codexDue
                let now = due.addingTimeInterval(claude ? 0 : 4)
                let otherStart = claude ? codexStart : claudeStart
                let waitUntil = CrossKeepalivePolicy.centeredDeferredUntil(
                    now: now,
                    otherStart: otherStart,
                    gridAnchor: claude ? due : nil)
                let sent = waitUntil ?? now
                let side = claude ? 0 : 1
                if waitUntil != nil { waits[side] += 1 }

                if claude {
                    claudeStart = floorToGrid(sent)
                } else {
                    codexStart = sent
                }

                let gap = abs(claudeStart.timeIntervalSince(codexStart))
                if cycle >= 3 {
                    check(waitUntil == nil,
                          "centered gap \(Int(initialGapMinutes))m has no waits after convergence, cycle \(cycle)")
                    check(gap >= 135 * 60 && gap <= 165 * 60,
                          "centered gap \(Int(initialGapMinutes))m converges within ±15 minutes of 150")
                }
            }

            check(waits[0] <= 1,
                  "centered gap \(Int(initialGapMinutes))m waits at most once on Claude")
            check(waits[1] <= 1,
                  "centered gap \(Int(initialGapMinutes))m waits at most once on Codex")
        }
    }
}
