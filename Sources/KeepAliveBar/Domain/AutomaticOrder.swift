import Foundation

enum AutomaticOrder {
    static func codexFirst(current: Bool, now: Date,
                           claudeEnd: Date?, claudeUsed: Double?,
                           codexEnd: Date?, codexUsed: Double?) -> Bool {
        func usage(_ used: Double?, _ end: Date?) -> Double? {
            guard let used, used.isFinite, used >= 0 else { return nil }
            // 过期快照中的 100% 不再代表当前窗口已用尽。
            return end.map { $0 <= now } == true ? 0 : used
        }
        let c = usage(claudeUsed, claudeEnd), x = usage(codexUsed, codexEnd)
        if let c, let x {
            if c >= 100 && x < 100 { return true }
            if x >= 100 && c < 100 { return false }
            if c >= 100 && x >= 100 { return current }
        }
        func deadline(_ end: Date?) -> Date? {
            guard let end, end > now, end.timeIntervalSince(now) <= 5 * 3600 else { return nil }
            return end
        }
        switch (deadline(claudeEnd), deadline(codexEnd)) {
        case let (c?, x?): return c == x ? current : x < c
        case (_?, nil): return false
        case (nil, _?): return true
        case (nil, nil): return current
        }
    }
}
