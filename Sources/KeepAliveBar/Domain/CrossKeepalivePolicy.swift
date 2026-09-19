import Foundation

enum CrossKeepalivePolicy {
    static let window: TimeInterval = 5 * 3600
    // Claude 的 5h 窗口起点由服务端向下对齐到半点网格（实测相位随时间变化：:00/:30、:10/:40、:19/:49），
    // 所以"开火时刻"最多比"服务端记的窗口起点"晚 30 分钟。Codex 的窗口起点就是开火那一刻，没有这个偏差。
    static let grid: TimeInterval = 1800
    static let centerMinutes: Double = 150

    static func minutes(_ value: Double) -> Double {
        value.isFinite ? min(145, max(30, value)) : 120
    }

    // 相位由已知的窗口边界反推（边界必在网格上）。观测到的边界带 ±1s 抖动
    //（01:09:59 / 01:10:00），先抹平到整分，否则会对齐到网格点前 1 秒开火，
    // 反被向下取整回上一个网格，白丢 30 分钟。
    private static func gridPhase(anchor: Date) -> TimeInterval {
        (anchor.timeIntervalSince1970 / 60).rounded() * 60
    }

    private static func gridRemainder(_ target: Date, phase: TimeInterval) -> TimeInterval {
        var rem = (target.timeIntervalSince1970 - phase).truncatingRemainder(dividingBy: grid)
        if rem < 0 { rem += grid }
        return rem
    }

    // 把目标时刻向上取整到网格点。
    static func alignedUp(_ target: Date, anchor: Date?) -> Date {
        guard let anchor else { return target }
        let rem = gridRemainder(target, phase: gridPhase(anchor: anchor))
        return rem == 0 ? target : target.addingTimeInterval(grid - rem)
    }

    // 把目标时刻取到最近的网格点；正好半格时取较早的点。
    static func alignedNearest(_ target: Date, anchor: Date?) -> Date {
        guard let anchor else { return target }
        let rem = gridRemainder(target, phase: gridPhase(anchor: anchor))
        let lower = target.addingTimeInterval(-rem)
        return rem <= grid / 2 ? lower : lower.addingTimeInterval(grid)
    }

    // 严格大于阈值：等于阈值时再等 1 秒，由现有 tick 执行。
    // 阈值比的是两侧**窗口起点**的实际差值，不是开火时刻的差值 —— 传入 gridAnchor 的一侧
    // 会把等待目标推到下一个网格点，让服务端最终记下的起点差仍然大于阈值。
    static func deferredUntil(now: Date, otherStart: Date?, minutes: Double, gridAnchor: Date? = nil) -> Date? {
        guard let start = otherStart, start <= now else { return nil }
        let target = start.addingTimeInterval(Self.minutes(minutes) * 60 + 1)
        let deadline = alignedUp(target, anchor: gridAnchor)
        return now < deadline ? deadline : nil
    }

    // 居中模式：目标是对方最新窗口起点之后 150 分钟，不加严格大于的 1 秒。
    // Claude 侧把目标取到最近网格点；若最近点已经过去，立即开火即可，因为此时开火
    // 仍会落入该网格对应的 [G, G + 30m) 区间。Codex 侧没有网格，直接使用目标时刻。
    static func centeredDeferredUntil(now: Date, otherStart: Date?, gridAnchor: Date? = nil) -> Date? {
        guard let start = otherStart, start <= now else { return nil }
        let target = start.addingTimeInterval(centerMinutes * 60)
        let deadline = alignedNearest(target, anchor: gridAnchor)
        return now < deadline ? deadline : nil
    }

    // 睡眠恢复/同时过期时，先到期者优先；同刻或未知时间时 Claude 优先。
    static func claudeFirst(claudeEnd: Date?, codexEnd: Date?) -> Bool {
        guard let c = claudeEnd, let x = codexEnd else { return true }
        return c <= x
    }
}
