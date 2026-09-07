import Foundation

extension Store {
    // 查询失败后不能只依赖 maybeAct()：后者必须先有 windowEnd，正是菜单栏显示“–”时缺少的状态。
    // 始终只保留一个延迟任务；手动刷新或新的刷新开始时会取消旧任务并重新计时。
    func scheduleRefreshRetry(_ reason: String) {
        guard !paused, refreshRetryTask == nil else { return }
        // 指数退避（3m 起、翻倍、封顶 30m）。失败原因基本都是“要等外部条件恢复”（代理没开、被限流、
        // 需要重新登录），固定 3 分钟死循环只会把无效请求堆成限流——旧日志里一次 4 小时的过期期
        // 就这么刷了 80 多条 401/429。成功一次即清零。
        let seconds = min(refreshRetryIntervalSec * pow(2, Double(refreshRetryFailures)),
                          refreshRetryMaxIntervalSec)
        refreshRetryFailures += 1
        log("REFRESH retry scheduled in \(Int(seconds))s: \(reason)")
        refreshRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.refreshRetryTask = nil
            await self.refresh()
        }
    }

    func cancelRefreshRetry() {
        refreshRetryTask?.cancel()
        refreshRetryTask = nil
    }

    func refresh() async {
        cancelRefreshRetry()
        await readCodexUsage()          // Codex：先查远程用量，失败时回退本地快照
        if !crossActive { maybeActCodex() }
        guard !paused else { return }   // 暂停：仅停止 Claude 的 GET 与续窗（不影响上面的 Codex）
        guard await proxyEnabled() else {   // 前置条件：代理未开则跳过用量刷新（Codex 已在上方读完）
            lastError = "Claude：代理未开启，已跳过用量刷新"
            log("REFRESH abort: 代理未开启")
            scheduleRefreshRetry("代理未开启")
            return
        }
        var cred = await readCredential()
        // token 过期就先换一张再发请求：过期后直接发 GET 必得 401，而空闲的 claude 会话不会替我们刷新，
        // 于是过去会一路 401 刷到某个 CLI 恰好起来为止（最长一次刷了 4 小时）。换 token 不耗用量、不开窗。
        if tokenNeedsRefresh(cred.expiresAtMs), await refreshOAuthToken(cred) {
            cred = await readCredential()
        }
        // 循环只为 401 后换 token 重试一次；其余每条路径都以 return 收尾，不会转第二圈。
        var triedTokenRefresh = false
        while true {
            guard let tok = cred.accessToken else {
                lastError = "Claude：无法读取 Keychain token（\(cred.diag)）"
                log("REFRESH abort: 无法读取 Keychain token — \(cred.diag)")
                scheduleRefreshRetry("无法读取 Keychain token")
                return
            }
            // token 仍是过期的（上面换失败，多半 refreshToken 也废了）→ 别再发这一发注定 401 的请求。
            // 这是 401/429 刷屏的止血点：无效凭据一次都不该打出去，429 本来就是这么被限流出来的。
            if tokenNeedsRefresh(cred.expiresAtMs) {
                lastError = "Claude：token 已过期且刷新失败，需重新登录 claude"
                log("REFRESH abort: token \(tokenExpStr(cred.expiresAtMs)) 且刷新失败 → 跳过 GET（需 claude auth login）")
                scheduleRefreshRetry("token 过期且刷新失败")
                return
            }
            let tokExp = tokenExpStr(cred.expiresAtMs)
            var req = URLRequest(url: usageURL)
            req.httpMethod = "GET"
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            req.setValue("claude-code/2.1", forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 20
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                    // 关键诊断：状态码 + token 过期状态 + 服务端错误体（含 authentication_error 等具体类型）。
                    // 401 时这行能一眼分清是「token 已过期」还是「被吊销/无效」，不再只看到红字一闪。
                    let body = (String(data: data, encoding: .utf8) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    // 401 但本地看着 token 没过期 → 多半是被吊销/服务端不认。换一张再试一次（只一次，防循环）。
                    if http.statusCode == 401, !triedTokenRefresh {
                        triedTokenRefresh = true
                        log("REFRESH http 401 tokenExp=\(tokExp)（本地未过期）→ 换新 token 后重试一次")
                        if await refreshOAuthToken(cred) {
                            cred = await readCredential()
                            continue
                        }
                    }
                    lastError = "Claude：usage HTTP \(http.statusCode)"
                    log("REFRESH http \(http.statusCode) tokenExp=\(tokExp) body=\(String(body.prefix(220)))")
                    scheduleRefreshRetry("usage HTTP \(http.statusCode)")
                    return
                }
                refreshRetryFailures = 0   // 拿到 200 → 退避指数清零，下次失败重新从 3 分钟起算
                let u = try JSONDecoder().decode(UsageResponse.self, from: data)
                fivePct = u.five_hour?.utilization;         fiveReset = parseISO(u.five_hour?.resets_at)
                sevenPct = u.seven_day?.utilization;        sevenReset = parseISO(u.seven_day?.resets_at)
                opusPct = u.seven_day_opus?.utilization;    opusReset = parseISO(u.seven_day_opus?.resets_at)
                sonnetPct = u.seven_day_sonnet?.utilization; sonnetReset = parseISO(u.seven_day_sonnet?.resets_at)
                sessionActive = u.limits?.first(where: { $0.kind == "session" })?.is_active   // 仅记日志，不做判断
                lastError = nil
                now = Date()
                lastRefresh = now
                // 只要服务端返回未来 reset，就更新 windowEnd；否则保持粘滞（见属性注释）。
                // 这样窗口过期（接口返回 null / 过去值）时 windowEnd 仍指向旧窗口末尾 → 能判定“已关闭”并续窗。
                // 保活刚开出的新窗口可能 utilization=0%，但 resets_at 已在未来；这仍是有效窗口。
                let hasActiveWindow = fiveReset.map { $0.timeIntervalSince(now) > 0 } ?? false
                if hasActiveWindow { windowEnd = fiveReset }
                // 关键诊断日志：原始 resets_at / 用量 / is_active 全记下——下次窗口过期时这行会揭示接口的真实返回
                log("REFRESH ok five=\(pctStr(fivePct)) rawReset=\(fmt(fiveReset)) tokenExp=\(tokExp) sessionActive=\(boolStr(sessionActive)) → windowEnd=\(fmt(windowEnd)) (active=\(hasActiveWindow))")
                if crossActive { maybeActCodex() }
                if windowEnd == nil, claudeAutoEnabled {
                    // 服务端已明确当前没有活动窗口。立即尝试激活，并持续重查直到拿到新 reset。
                    scheduleRefreshRetry("查询成功但 five_hour.resets_at=nil")
                    maybeBootstrapMissingWindow()
                }
                return
            } catch {
                // 带上 NSError 的 domain#code：区分连接中断(-1005)/超时(-1001)/离线(-1009)/SSL(-1200) 等，
                // 对代理不稳的场景特别有用——localizedDescription 三种都可能是「网络连接已丢失」。
                let ns = error as NSError
                lastError = "Claude：查询失败：\(error.localizedDescription)"
                log("REFRESH failed: \(ns.domain)#\(ns.code) \(error.localizedDescription)")
                scheduleRefreshRetry("\(ns.domain)#\(ns.code)")
                return
            }
        }
    }
}
