import Foundation

enum CrossKeepalivePolicy {
    static let window: TimeInterval = 5 * 3600

    static func minutes(_ value: Double) -> Double {
        value.isFinite ? min(145, max(30, value)) : 120
    }

    // 严格大于阈值：等于阈值时再等 1 秒，由现有 tick 执行。
    static func deferredUntil(now: Date, otherStart: Date?, minutes: Double) -> Date? {
        guard let start = otherStart, start <= now else { return nil }
        let deadline = start.addingTimeInterval(Self.minutes(minutes) * 60 + 1)
        return now < deadline ? deadline : nil
    }

    // 睡眠恢复/同时过期时，先到期者优先；同刻或未知时间时 Claude 优先。
    static func claudeFirst(claudeEnd: Date?, codexEnd: Date?) -> Bool {
        guard let c = claudeEnd, let x = codexEnd else { return true }
        return c <= x
    }
}
