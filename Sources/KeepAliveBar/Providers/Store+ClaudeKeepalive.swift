import Foundation

extension Store {
    func fire() async {
        guard claudeAutoEnabled, !paused, !busyFiring, !codexActing,
              !crossYieldsPriority(claude: true), crossAllowsFire(claude: true) else { return }
        busyFiring = true
        defer { busyFiring = false }
        lastAttempt = Date()   // 记录尝试时刻（成功/失败都算）→ 失败后按 retryIntervalSec 退避重试
        if directFireEnabled { _ = await fireDirect() } else { await fireCLI() }
    }

    // 直连一条最小推理请求开窗（实测 8 in / 1 out，claude -p 是 22,698 / 51）。
    // 用的就是钥匙串里那张订阅 OAuth token（与查 usage 同一张），因此和 claude -p 一样
    // 计入订阅的 5h/周限额 —— 省掉的只是工具定义、系统提示词和全局 CLAUDE.md。
    //
    // **故意不做自动降级**：直连一旦失效，就让它明明白白地失败、按 retryIntervalSec 每 3 分钟
    // 重试并刷一条日志，而不是被 CLI 悄悄补上导致"看起来一切正常、其实早已回到 22,698 tokens"。
    // 自证是让问题显形的关键一步：即便 HTTP 200，也要回读 usage 确认 five_hour.resets_at
    // 真的落到了未来（= 新窗口已开），没开出来照样算失败。
    // 要手动退回旧写法：UserDefaults 的 directFire 设为 false（显式开关，不是自动降级）。
    func fireDirect() async -> Bool {
        var cred = await readCredential()
        // 与 refresh() 同样的策略：token 快过期先换一张，别发一发注定 401 的请求。
        if tokenNeedsRefresh(cred.expiresAtMs), await refreshOAuthToken(cred) {
            cred = await readCredential()
        }
        guard let tok = cred.accessToken, !tokenNeedsRefresh(cred.expiresAtMs) else {
            lastFireFailed = true
            lastFireResult = "Claude 保活失败：无可用 token（\(cred.diag)），需重新登录 claude"
            log("FIRE direct 失败：无可用 token（\(cred.diag)）—— 窗口未续")
            return false
        }
        var req = URLRequest(url: claudeAPIURL)
        req.httpMethod = "POST"
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("cli", forHTTPHeaderField: "x-app")
        req.setValue("claude-cli/2.1 (external, cli)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 30
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": claudeAPIModel, "max_tokens": 1,
            "messages": [["role": "user", "content": "."]]
        ])
        log("FIRE start: 直连 POST /v1/messages (\(claudeAPIModel), max_tokens=1)")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else {
                let b = (String(data: data, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let mins = Int(retryIntervalSec / 60)
                lastFireFailed = true
                lastFireResult = "Claude 保活失败：直连 HTTP \(code)，约 \(mins) 分钟后重试"
                log("FIRE direct HTTP \(code) tokenExp=\(tokenExpStr(cred.expiresAtMs)) —— 窗口未续: \(String(b.prefix(160)))")
                return false
            }
        } catch {
            let ns = error as NSError
            let mins = Int(retryIntervalSec / 60)
            lastFireFailed = true
            lastFireResult = "Claude 保活失败：\(error.localizedDescription)，约 \(mins) 分钟后重试"
            log("FIRE direct failed: \(ns.domain)#\(ns.code) \(error.localizedDescription) —— 窗口未续")
            return false
        }
        // 自证要轮询等待，不能看一眼就下结论：/api/oauth/usage 对新窗口有传播延迟。
        // 实测 2026-09-07 03:31:36 发出请求，03:31:42（6s）时接口仍是 resets_at=nil，
        // 到 03:32:48（约 70s）才出现新窗口 08:30:00。只等 3 秒会稳定误报失败。
        // refresh() 会重新拉 usage 并据此更新 windowEnd（只在 resets_at 落在未来时才更新）。
        // 轮询期间 busyFiring 仍为 true，tick()/maybeAct() 不会插进来重复开火。
        var end: Date?
        for wait in [5, 10, 20, 30, 60] as [UInt64] {
            try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
            await refresh()
            if let e = windowEnd, e.timeIntervalSinceNow > 0 { end = e; break }
        }
        guard let end else {
            lastFireFailed = true
            lastFireResult = "⚠️ Claude 直连 HTTP 200 但 125s 内未见新窗口 —— 直连开窗可能已失效"
            log("FIRE direct HTTP 200 但 125s 内未见新窗口（windowEnd=\(fmt(windowEnd)) rawReset=\(fmt(fiveReset))）—— 直连开窗可能已失效，需要人工判断；临时退回：defaults write com.iu.keepalivebar directFire -bool false")
            return false
        }
        let stamp = Date()
        lastFire = stamp
        preferences.set(stamp.timeIntervalSince1970, forKey: "lastFire")
        lastFireFailed = false
        lastFireResult = "Claude 保活成功（直连，~8 tokens）：新窗口 \(fmt(end)) 重置"
        log("FIRED direct -> 新窗口 windowEnd=\(fmt(end))")
        return true
    }

    func fireCLI() async {
        log("FIRE start: claude -p 'Reply OK' --model haiku（脱钩：子进程自负钥匙串责任，避免弹授权框）")
        let temporaryDirectory: URL
        do {
            temporaryDirectory = try makeTemporaryKeepaliveDirectory()
        } catch {
            lastFireFailed = true
            lastFireResult = "Claude 保活失败：无法创建临时目录（\(error.localizedDescription)）"
            log("FAILED: 无法创建临时目录：\(error.localizedDescription)")
            return
        }
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let env = baseEnv(); let wd = temporaryDirectory.path; let bin = keepaliveClaudeBin
        // 空目录 + 禁 MCP + 去除 API key（走订阅）+ Haiku
        // 用固定路径副本（keepaliveClaudeBin）而非 PATH 里天天更新的 claude，
        // 让钥匙串授权对象身份稳定，避免每次到期都弹版本号授权框。
        let cmd = "cd '\(wd)' && exec env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN " +
                  "'\(bin)' -p 'Reply OK' --model haiku --strict-mcp-config"
        // 用 runDisclaimed 而非 run：claude 刷新 OAuth token 写钥匙串时不再算到本 App（ad-hoc 签名）头上，
        // 从而不再每次弹“允许访问钥匙串”框（详见 Shell.runDisclaimed 注释）。
        let r = await Task.detached { Shell.runDisclaimed("/bin/bash", ["-c", cmd], env: env) }.value
        let trimmed = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.code == 0 {
            let stamp = Date()
            lastFire = stamp
            preferences.set(stamp.timeIntervalSince1970, forKey: "lastFire")
            lastFireFailed = false
            lastFireResult = "Claude 保活成功：\(String(trimmed.prefix(60)))"
            log("FIRED -> \(String(trimmed.prefix(100)))")
        } else {
            // 失败：不更新 lastFire（窗口仍算未续），lastAttempt 已记 → retryIntervalSec 后自动重试
            let mins = Int(retryIntervalSec / 60)
            lastFireFailed = true
            lastFireResult = "Claude 保活失败 (rc=\(r.code))，约 \(mins) 分钟后自动重试：\(String(trimmed.prefix(80)))"
            log("FAILED rc=\(r.code) (retry in \(mins)m): \(String(trimmed.prefix(160)))")
        }
        Task { try? await Task.sleep(nanoseconds: 3_000_000_000); await refresh() }
    }
}
