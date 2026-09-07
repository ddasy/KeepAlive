import Foundation

extension Store {
    // 读取 Codex 最新用量快照（~/.codex 会话日志里的 rate_limits）——本地读取，不联网、不耗额度
    //
    // ⚠️ 不能简单地取“最后一条 rate_limits”：5h 额度打满的瞬间，Codex 会紧跟着补写一条
    // limit_id="premium"（credits 桶）的记录，它的 primary/secondary 全是 null。这条空记录若被
    // 当成最新快照，会把前一条完好的 100%/23% 数据整个顶掉 —— UI 两行都变成“—”，5h reset 退化成
    // “上次 fire + 5h”（可能远在过去）→ 保活提前开火、每 3 分钟撞一次 429，直到真实重置时刻。
    // 所以这里取多条候选行、丢掉两个桶全空的，再按时间戳分别挑最新的 5h / 周窗口。
    func readCodexUsage() async {
        if directFireEnabled, await readCodexUsageRemote() { return }
        if directFireEnabled {
            // wham/usage 不可达（离线/代理未开/登录态失效）→ 退回扫本地 rollout。
            // 每小时最多记一条，别把日志刷满。
            if codexUsageSourceLoggedAt == nil
                || Date().timeIntervalSince(codexUsageSourceLoggedAt!) >= 3600 {
                codexUsageSourceLoggedAt = Date()
                log("CODEX usage: wham/usage 不可达 → 退回本地 rollout 快照")
            }
        }
        await readCodexUsageRollout()
    }

    // ~/.codex/auth.json 里的 ChatGPT 登录态（codex CLI 自己维护、自己轮换）。这里只读不写：
    // token 过期 → 直连 401 → 回落 CLI，CLI 会顺手把 auth.json 刷新好，下次直连又能用。
    struct CodexAuth { let token: String; let account: String }
    func codexAuth() -> CodexAuth? {
        guard let d = FileManager.default.contents(atPath: "\(home)/.codex/auth.json"),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let t = obj["tokens"] as? [String: Any],
              let tok = t["access_token"] as? String, !tok.isEmpty,
              let acc = t["account_id"] as? String, !acc.isEmpty else { return nil }
        return CodexAuth(token: tok, account: acc)
    }

    // 查 wham/usage 拿实时窗口状态。成功返回 true（调用方就不再去扫 rollout 日志了）。
    //
    // ⚠️ 关键语义：**空闲时 primary_window.reset_at 是滚动的"此刻 + 窗口长度"**，
    //    并不代表有一个已锚定的窗口。实测（2026-09-06 23:13）：窗口刚重置且零用量时，
    //    两次读数 reset_after_seconds 都恰好是 18000；发出一条请求后立刻变成 17991 → 17972，
    //    而 reset_at 的绝对值固定不动 —— 窗口被锚定在了那条请求的时刻。
    //    所以判据是 reset_after_seconds 是否已明显小于窗口总长：
    //      reset_after < limit_window - 5  → 有活动窗口，reset_at 可信
    //      否则                            → 当前无活动窗口（codexWindowClosed=true，该开火）
    //    若把滚动值当成"窗口开着"，保活将永远不触发 —— 这是这里最容易踩的坑。
    func readCodexUsageRemote() async -> Bool {
        guard let auth = codexAuth() else { return false }
        var req = URLRequest(url: codexUsageURL)
        req.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
        req.setValue(auth.account, forHTTPHeaderField: "chatgpt-account-id")
        req.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        req.timeoutInterval = 20
        guard let pair = try? await URLSession.shared.data(for: req),
              (pair.1 as? HTTPURLResponse)?.statusCode == 200,
              let u = try? JSONDecoder().decode(CodexWhamUsage.self, from: pair.0),
              let rl = u.rate_limit else { return false }

        codexAvailable = true
        codexPlan = u.plan_type
        codexSnapshotAt = Date()
        if let p = rl.primary_window, let after = p.reset_after_seconds, let win = p.limit_window_seconds {
            let anchored = after < win - 5
            if codexWindowClosed == anchored {   // 状态翻转才记一条：窗口开/关是稀有事件，值得留痕
                log("CODEX window \(anchored ? "OPEN" : "CLOSED") (via wham/usage, reset_after=\(Int(after))s/\(Int(win))s)")
            }
            codexWindowClosed = !anchored
            codexPrimaryUsed = anchored ? p.used_percent : 0
            codexPrimaryReset = anchored ? p.reset_at.map { Date(timeIntervalSince1970: $0) } : nil
        } else {
            codexWindowClosed = false     // 结构不认识 → 当作未知，别据此开火
            codexPrimaryUsed = nil
            codexPrimaryReset = nil
        }
        codexWeeklyUsed = rl.secondary_window?.used_percent
        codexWeeklyReset = rl.secondary_window?.reset_at.map { Date(timeIntervalSince1970: $0) }
        return true
    }

    func readCodexUsageRollout() async {
        codexWindowClosed = false        // 本地日志区分不出"窗口关着"，一律当未知
        let env = baseEnv()
        // 每个文件取最后 3 条 rate_limits（足以越过尾部的 premium 空记录），最多凑 3 个有产出的文件。
        let cmd = "n=0; for f in $(ls -t \"$HOME\"/.codex/sessions/*/*/*/rollout-*.jsonl 2>/dev/null | head -12); do " +
                  "out=$(grep -a rate_limits \"$f\" 2>/dev/null | tail -3); " +
                  "[ -n \"$out\" ] && { printf '%s\\n' \"$out\"; n=$((n+1)); }; " +
                  "[ $n -ge 3 ] && break; done"
        let r = await Task.detached { Shell.run("/bin/bash", ["-c", cmd], env: env) }.value

        // 候选快照：解码 → 丢掉两个桶全空的（premium 空记录在这里被剔除）→ 按时间戳降序。
        // 降序排序让下面的“取最新”与 shell 的输出顺序解耦，文件/行顺序怎么变都不影响结果。
        struct Snap {
            let at: Date
            let rl: CodexRollout.Payload.RL
            let buckets: [CodexRollout.Payload.RL.Bucket]
        }
        let snaps: [Snap] = r.out.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8), !data.isEmpty,
                  let roll = try? JSONDecoder().decode(CodexRollout.self, from: data),
                  let rl = roll.payload?.rate_limits else { return nil }
            let buckets = [rl.primary, rl.secondary].compactMap { $0 }
            guard !buckets.isEmpty else { return nil }
            return Snap(at: parseISO(roll.timestamp) ?? .distantPast, rl: rl, buckets: buckets)
        }.sorted { $0.at > $1.at }

        guard let newest = snaps.first else {
            codexAvailable = false
            return
        }
        codexAvailable = true
        codexPlan = newest.rl.plan_type
        codexSnapshotAt = newest.at

        // 按 window_minutes 归类，而不是按 primary/secondary 槽位（见 Bucket 注释）。
        // 5h 窗口：window_minutes ≤ 360；周窗口：≥ 1440。两者未必出现在同一条快照里
        // （空闲保活的快照常常只带周窗口），所以各自沿候选列表向前找最新的一条。
        func pick(_ match: (CodexRollout.Payload.RL.Bucket) -> Bool) -> CodexRollout.Payload.RL.Bucket? {
            for s in snaps {
                if let b = s.buckets.first(where: match) { return b }
            }
            return nil
        }
        let nowTS = Date().timeIntervalSince1970
        let hasWindowInfo = snaps.contains { $0.buckets.contains { $0.window_minutes != nil } }
        let five: CodexRollout.Payload.RL.Bucket?
        let weekly: CodexRollout.Payload.RL.Bucket?
        if hasWindowInfo {
            // 5h 只认“还没过期”的窗口：已过期的 5h 桶 used_percent 已无意义，
            // 留给下面的“上次 fire + 5h”估算，免得拿几天前的旧窗口冒充当前状态。
            five = pick { ($0.window_minutes ?? .infinity) <= 360 && ($0.resets_at ?? 0) > nowTS }
            weekly = pick { ($0.window_minutes ?? 0) >= 1440 }
        } else {
            // 老格式没有 window_minutes → 回退旧假设（primary=5h / secondary=周），且只看最新那条。
            five = newest.rl.primary; weekly = newest.rl.secondary
        }
        // 5h 窗口：优先用快照里真正的 5h 窗口(通常只在有实际用量的会话里出现)；
        // 保活 Reply OK 的快照往往只带“周”窗口、没有 5h 窗口 → 用“上次 fire + 5h”估算 5h 重置，
        // 既给出倒计时、又驱动在 fire 后约 5h 精确续窗，绝不把周 reset 误当 5h reset。
        if let five = five, let ra = five.resets_at {
            codexPrimaryUsed = five.used_percent
            codexPrimaryReset = Date(timeIntervalSince1970: ra)
        } else if let lf = codexLastFire {
            codexPrimaryUsed = nil                                  // 5h 真实用量未知
            codexPrimaryReset = lf.addingTimeInterval(codexFallbackSec)   // ≈ 上次 fire + 5h
        } else {
            codexPrimaryUsed = nil                                  // 从未 fire 过 → 交给时间兜底计时
            codexPrimaryReset = nil
        }
        codexWeeklyUsed = weekly?.used_percent
        codexWeeklyReset = weekly?.resets_at.map { Date(timeIntervalSince1970: $0) }
    }
}
