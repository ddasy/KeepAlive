import Foundation

extension Store {
    // Codex 没有公开 usage 查询接口：有本地 reset 就按 reset 续窗；没有时间时，
    // 首次观察开始计时，连续 5 小时后发送一次 Reply OK 激活，随后等待新的 rollout 快照。
    func maybeActCodex() {
        guard codexAutoEnabled, !paused, !busyFiring, !acting, !codexActing, !crossRefreshing else { return }
        // 周限剩余 0 → 本周不再触发 5h 保活，等越过周重置时刻自动恢复
        if codexWeeklyBlocked {
            if weeklyBlockLoggedAt == nil || Date().timeIntervalSince(weeklyBlockLoggedAt!) >= 3600 {
                weeklyBlockLoggedAt = Date()   // 这行每小时最多记一条，别把日志刷满
                log("CODEX skip: 周限剩余 0（重置 \(fmt(codexWeeklyReset))）→ 暂不保活")
            }
            return
        }
        let current = Date()
        if !codexWindowClosed, let reset = codexPrimaryReset, reset.timeIntervalSince(current) > codexBufferSec {
            codexNoSnapshotSince = nil
            preferences.removeObject(forKey: "codexNoSnapshotSince")
            return
        }

        var ready = false
        if codexWindowClosed {
            // 服务端明确当前没有活动 5h 窗口 → 立刻开火，不必再走"连续 5 小时"的时间兜底
            codexNoSnapshotSince = nil
            preferences.removeObject(forKey: "codexNoSnapshotSince")
            ready = true
        } else if let reset = codexPrimaryReset {
            ready = current.timeIntervalSince(reset) >= codexBufferSec
        } else {
            if codexNoSnapshotSince == nil {
                codexNoSnapshotSince = current
                preferences.set(current.timeIntervalSince1970, forKey: "codexNoSnapshotSince")
                log("CODEX no reset snapshot — 开始 5 小时激活计时")
            }
            ready = current.timeIntervalSince(codexNoSnapshotSince!) >= codexFallbackSec
        }
        guard ready, !crossYieldsPriority(claude: false), crossAllowsFire(claude: false) else { return }
        if let attempt = codexLastAttempt, current.timeIntervalSince(attempt) < codexRetryIntervalSec { return }
        if let fire = codexLastFire, current.timeIntervalSince(fire) < codexMinRefireSec { return }
        Task { await fireCodex() }
    }

    func fireCodex() async {
        guard codexAutoEnabled, !paused, !codexActing, !acting, !busyFiring else { return }
        codexActing = true
        defer { codexActing = false }
        if crossActive {
            // 锁先于 await，避免 Claude/Codex 两个 Task 同时发出请求。
            await refresh()
            if !codexWindowClosed, let end = codexPrimaryReset, end > Date() { return }
        }
        guard codexAutoEnabled, !paused, !codexWeeklyBlocked, !crossYieldsPriority(claude: false),
              crossAllowsFire(claude: false) else { return }
        let attempt = Date()
        codexLastAttempt = attempt
        preferences.set(attempt.timeIntervalSince1970, forKey: "codexLastAttempt")
        if directFireEnabled { _ = await fireCodexDirect() } else { await fireCodexCLI() }
    }

    // 直连一条最小推理请求开窗（实测 14 in / 16 out，CLI 是 13,871 / 16）。
    // 请求体与 codex CLI 发的完全同构，只是 tools=[]、instructions 换成一句话。
    // 与 Claude 侧一样**不做自动降级**（见 fireDirect 注释）。注意 codex 的 token 由 CLI 维护，
    // 过期后直连会 401；因为不再自动回落 CLI，也就不会顺手把 auth.json 刷新好 —— 401 会持续
    // 刷日志直到你自己跑一次 codex 或重新登录。这是刻意的：宁可吵，也不要"看起来正常"。
    func fireCodexDirect() async -> Bool {
        guard let auth = codexAuth() else {
            codexLastFireFailed = true
            codexLastFireResult = "Codex 保活失败：~/.codex/auth.json 无可用登录态"
            log("CODEX FIRE direct 失败：~/.codex/auth.json 无可用登录态 —— 窗口未续")
            return false
        }
        var req = URLRequest(url: codexResponsesURL)
        req.httpMethod = "POST"
        req.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
        req.setValue(auth.account, forHTTPHeaderField: "chatgpt-account-id")
        req.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        req.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        req.setValue(UUID().uuidString, forHTTPHeaderField: "session_id")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("text/event-stream", forHTTPHeaderField: "accept")
        req.timeoutInterval = 60
        let body: [String: Any] = [
            "model": "gpt-5.6-luna",
            "instructions": "Reply OK.",
            "input": [["type": "message", "role": "user",
                       "content": [["type": "input_text", "text": "hi"]]]],
            "tools": [], "tool_choice": "auto", "parallel_tool_calls": false,
            "reasoning": ["effort": "low", "summary": "auto"],
            "store": false, "stream": true, "include": []
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else {
                let b = (String(data: data, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let mins = Int(codexRetryIntervalSec / 60)
                codexLastFireFailed = true
                codexLastFireResult = "Codex 保活失败：直连 HTTP \(code)，约 \(mins) 分钟后重试"
                log("CODEX FIRE direct HTTP \(code) —— 窗口未续（401 多半是登录态过期，跑一次 codex 或重新登录）: \(String(b.prefix(160)))")
                return false
            }
        } catch {
            let ns = error as NSError
            let mins = Int(codexRetryIntervalSec / 60)
            codexLastFireFailed = true
            codexLastFireResult = "Codex 保活失败：\(error.localizedDescription)，约 \(mins) 分钟后重试"
            log("CODEX FIRE direct failed: \(ns.domain)#\(ns.code) \(error.localizedDescription) —— 窗口未续")
            return false
        }
        // 自证同样轮询等待。第一次 sleep 还兼作"让 reset_after 明显偏离窗口总长"，好判定锚定
        //（见 readCodexUsageRemote 注释）。wham/usage 实测比 Claude 的 usage 快得多，但仍留重试余量。
        var reset: Date?
        for wait in [8, 15, 30] as [UInt64] {
            try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
            if await readCodexUsageRemote(), !codexWindowClosed, let r = codexPrimaryReset { reset = r; break }
        }
        guard let reset else {
            codexLastFireFailed = true
            codexLastFireResult = "⚠️ Codex 直连 HTTP 200 但 53s 内未见新窗口 —— 直连开窗可能已失效"
            log("CODEX FIRE direct HTTP 200 但 53s 内未见新窗口（closed=\(codexWindowClosed)）—— 直连开窗可能已失效，需要人工判断；临时退回：defaults write com.iu.keepalivebar directFire -bool false")
            return false
        }
        let stamp = Date()
        codexLastFire = stamp
        preferences.set(stamp.timeIntervalSince1970, forKey: "codexLastFire")
        codexLastFireFailed = false
        codexLastFireResult = "Codex 激活成功（直连，~30 tokens）：新窗口 \(fmt(reset)) 重置"
        log("CODEX FIRED direct -> 新窗口 reset=\(fmt(reset))")
        return true
    }

    func fireCodexCLI() async {
        log("CODEX FIRE start: codex exec 'Reply OK' --model gpt-5.6-luna --effort low")
        let temporaryDirectory: URL
        do {
            temporaryDirectory = try makeTemporaryKeepaliveDirectory()
        } catch {
            codexLastFireFailed = true
            codexLastFireResult = "Codex 保活失败：无法创建临时目录（\(error.localizedDescription)）"
            log("CODEX FAILED: 无法创建临时目录：\(error.localizedDescription)")
            return
        }
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let temporaryPath = temporaryDirectory.path

        let env = baseEnv()
        let command = keepaliveCodexUsesEnv ? "/usr/bin/env" : keepaliveCodexBin
        var args = keepaliveCodexUsesEnv ? ["codex"] : []
        args += [
            "--ask-for-approval", "never",
            "exec", "--model", "gpt-5.6-luna",
            "-c", "model_reasoning_effort=low",
            // 强制直连 HTTP(responses)、跳过 websocket。codex 默认先连 wss://chatgpt.com/.../responses，
            // 网络不稳时这一步常 403/超时后才降级 HTTP，白等一截、还不确定。内置 openai provider 不可覆盖，
            // 故另起一个自定义 provider：requires_openai_auth=true 复用 ChatGPT 订阅登录态（不走 API key 计费），
            // supports_websockets=false 关掉 websocket → 直连 HTTP，确定性更好。
            // 注：base_url 硬编码为 ChatGPT codex 后端；若官方改址，此处需同步（fire 会失败并重试、日志可见）。
            "-c", "model_provider=chatgpt-httponly",
            "-c", "model_providers.chatgpt-httponly.name=chatgpt-httponly",
            "-c", "model_providers.chatgpt-httponly.base_url=https://chatgpt.com/backend-api/codex",
            "-c", "model_providers.chatgpt-httponly.wire_api=responses",
            "-c", "model_providers.chatgpt-httponly.requires_openai_auth=true",
            "-c", "model_providers.chatgpt-httponly.supports_websockets=false",
            "--cd", temporaryPath,
            "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules",
            "--sandbox", "read-only", "Reply OK"
        ]
        var cleanEnv = env
        cleanEnv.removeValue(forKey: "OPENAI_API_KEY")
        cleanEnv.removeValue(forKey: "OPENAI_BASE_URL")
        let r = await Task.detached {
            Shell.runDisclaimed(command, args, env: cleanEnv)
        }.value
        let trimmed = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.code == 0 {
            let stamp = Date()
            codexLastFire = stamp
            preferences.set(stamp.timeIntervalSince1970, forKey: "codexLastFire")
            codexLastFireFailed = false
            codexLastFireResult = "Codex 激活成功：\(String(trimmed.prefix(60)))"
            log("CODEX FIRED -> \(String(trimmed.prefix(120)))")
        } else {
            let mins = Int(codexRetryIntervalSec / 60)
            codexLastFireFailed = true
            codexLastFireResult = "Codex 激活失败 (rc=\(r.code))，约 \(mins) 分钟后重试：\(String(trimmed.prefix(80)))"
            log("CODEX FAILED rc=\(r.code) (retry in \(mins)m): \(String(trimmed.prefix(180)))")
        }
        Task { try? await Task.sleep(nanoseconds: 3_000_000_000); await readCodexUsage() }
    }
}
