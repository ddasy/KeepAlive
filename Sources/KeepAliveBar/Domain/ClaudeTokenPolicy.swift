import Foundation

// 谁来换 Claude access token。
// refresh token 每用一次就轮换，同一张只能由一个进程拿去换；两边同时换会撞出 400，
// 随后 CLI 把钥匙串里的凭据清空，所有 claude 都得重新登录（2026-09/10 日志里 6 次掉线都是这么来的）。
// 规则：
//   - 有 claude 进程在跑（含闲置会话）：它们会在过期前约 5 分钟自己换（进程间有锁、换前重读钥匙串），
//     App 只读钥匙串、不换；token 用到过期前 usableMargin 为止，之后等 CLI 换好再发请求。
//   - 没有任何 claude 进程：没人会换，App 提前 selfRefreshLead 自己走 CLI 的刷新入口。
enum ClaudeTokenAction: Equatable {
    case use            // token 可用，直接发请求
    case waitForCLI     // 将过期/已过期，但有 claude 在跑：等它换，App 不换也不发请求
    case refreshSelf    // 将过期/已过期且没有 claude 在跑：App 自己换
    case loginRequired  // 钥匙串里已没有 refresh token（被 CLI 判死清空），只能重新登录
}

enum ClaudeTokenPolicy {
    static let selfRefreshLead: TimeInterval = 300
    static let usableMargin: TimeInterval = 30

    // 剩余寿命充足（或未知）时不需要关心是谁来换，也就不必去查进程。
    static func comfortablyValid(expiresAt: Date?, now: Date) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt.timeIntervalSince(now) >= selfRefreshLead
    }

    // 还能拿来发请求吗。expiresAt 未知时照用，交给 401 分支兜底。
    static func usable(expiresAt: Date?, now: Date) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt.timeIntervalSince(now) > usableMargin
    }

    static func action(expiresAt: Date?, now: Date, cliRunning: Bool, hasRefreshToken: Bool) -> ClaudeTokenAction {
        if comfortablyValid(expiresAt: expiresAt, now: now) { return .use }
        if cliRunning, usable(expiresAt: expiresAt, now: now) { return .use }
        if !hasRefreshToken { return usable(expiresAt: expiresAt, now: now) ? .use : .loginRequired }
        return cliRunning ? .waitForCLI : .refreshSelf
    }
}
