import Foundation

// MARK: - 用量接口数据结构（对应 GET https://api.anthropic.com/api/oauth/usage）
struct UsageResponse: Decodable {
    struct Bucket: Decodable { let utilization: Double?; let resets_at: String? }
    // limits[] 里 kind=="session" 的条目带 is_active。⚠️实测（2026-07-03）：活动窗口期间它也是 false，
    // 不能当“是否有活动窗口”用；仅解析出来记日志诊断。判定活动窗口用 five_hour.resets_at 是否在未来。
    struct Limit: Decodable { let kind: String?; let is_active: Bool?; let resets_at: String?; let percent: Double? }
    let five_hour: Bucket?
    let seven_day: Bucket?
    let seven_day_opus: Bucket?
    let seven_day_sonnet: Bucket?
    let limits: [Limit]?
}

// Codex 用量（来自 ~/.codex 会话日志里最后一条 rate_limits 快照，本地读取，无需联网）
struct CodexRollout: Decodable {
    struct Payload: Decodable {
        struct RL: Decodable {
            // ⚠️ primary/secondary 槽位并非固定对应 5h/周——要看 window_minutes 判定：
            // window_minutes≈300 → 5 小时窗口；≈10080 → 7 天(周)窗口。空闲（仅 Reply OK 保活）的快照往往
            // 只带一个“周”窗口且放在 primary、secondary 缺失、5h 窗口整段消失。切勿按槽位当 5h/周。
            struct Bucket: Decodable { let used_percent: Double?; let resets_at: Double?; let window_minutes: Double? }
            let primary: Bucket?
            let secondary: Bucket?
            let plan_type: String?
        }
        let rate_limits: RL?
    }
    let timestamp: String?
    let payload: Payload?
}

// Codex 实时用量（GET https://chatgpt.com/backend-api/wham/usage）——Codex 版的 /api/oauth/usage。
// 服务端真值、免费、不需要 codex 跑过，取代"扫 rollout 日志找最后一条 rate_limits"那套启发式。
struct CodexWhamUsage: Decodable {
    struct RateLimit: Decodable {
        struct Window: Decodable {
            let used_percent: Double?
            let limit_window_seconds: Double?
            let reset_after_seconds: Double?
            let reset_at: Double?
        }
        let primary_window: Window?     // 5 小时窗口
        let secondary_window: Window?   // 周窗口
    }
    let plan_type: String?
    let rate_limit: RateLimit?
}

func parseISO(_ s: String?) -> Date? {
    guard let s = s else { return nil }
    // 去掉微秒小数部分（ISO8601DateFormatter 对 6 位小数会失败）
    let cleaned = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: cleaned)
}
