import Foundation

extension Store {
    // 读取 Keychain 凭据。返回 accessToken + 过期时刻(ms) + 失败诊断串（供日志精确定位）。
    // ⚠️ 绝不记录 token 本身；仅在失败时把 security 的退出码与错误输出（截断）带回来——
    //   security 成功时 out 是明文 token，只有 rc!=0 时 out 才是报错文本（item not found / auth denied 等）。
    // refreshToken / scopes 也读出来：本机没有 claude 进程时要拿它们走 CLI 的非交互刷新入口（见 refreshOAuthToken）。
    struct Credential {
        let accessToken: String?; let refreshToken: String?; let scopes: [String]
        let expiresAtMs: Double?; let diag: String
    }
    func readCredential() async -> Credential {
        let env = baseEnv(); let svc = keychainService
        let r = await Task.detached {
            Shell.run("/usr/bin/security", ["find-generic-password", "-s", svc, "-w"], env: env)
        }.value
        guard r.code == 0 else {
            claudeLoginExpiresAt = nil
            let msg = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            return Credential(accessToken: nil, refreshToken: nil, scopes: [], expiresAtMs: nil,
                              diag: "security rc=\(r.code) \(String(msg.prefix(140)))")
        }
        guard let d = r.out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            claudeLoginExpiresAt = nil
            return Credential(accessToken: nil, refreshToken: nil, scopes: [], expiresAtMs: nil,
                              diag: "凭据 JSON 解析失败")
        }
        claudeLoginExpiresAt = LoginExpiry.claudeDeadline(from: obj)
        let o = (obj["claudeAiOauth"] as? [String: Any]) ?? obj
        let tok = o["accessToken"] as? String
        let exp = (o["expiresAt"] as? NSNumber)?.doubleValue
        return Credential(accessToken: tok,
                          refreshToken: o["refreshToken"] as? String,
                          scopes: (o["scopes"] as? [String]) ?? [],
                          expiresAtMs: exp,
                          diag: tok == nil ? "凭据里无 accessToken 字段（API-key 用户？）" : "")
    }

    // Local metadata only: remains available when monitoring is paused or the proxy is offline.
    func refreshLoginExpiryIfNeeded() {
        guard monitoringEnabled, !checkingLoginExpiry,
              lastLoginExpiryCheck.map({ Date().timeIntervalSince($0) >= 300 }) ?? true else { return }
        checkingLoginExpiry = true
        lastLoginExpiryCheck = Date()
        Task { [weak self] in
            guard let self else { return }
            _ = await self.readCredential()
            self.checkingLoginExpiry = false
        }
    }

    // token 过期状态的紧凑串：把剩余寿命算出来，供 401 时对照（过期→大概率就是 401 主因）。
    func tokenExpStr(_ expiresAtMs: Double?) -> String {
        guard let ms = expiresAtMs else { return "未知" }
        let exp = Date(timeIntervalSince1970: ms / 1000)
        let rem = exp.timeIntervalSince(Date())
        return "\(fmt(exp))(\(rem >= 0 ? "剩\(Int(rem / 60))m" : "已过期\(Int(-rem / 60))m"))"
    }

    func expiryDate(_ expiresAtMs: Double?) -> Date? {
        expiresAtMs.map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    // 本机是否有 claude CLI 进程（交互会话哪怕闲置也算：它们会在过期前约 5 分钟自己换 token）。
    // 原生安装的进程名是版本号（如 2.1.289），argv0 才是 claude，所以按 argv0 的文件名判断；
    // 桌面版/IDE 内置的 CLI 同样以 claude 为名。npm 安装形态是 node 跑 cli.js，另按参数匹配。
    // 本 App 的保活副本叫 keepalive-claude，不会把自己的子进程算进去。
    func claudeCLIRunning() async -> Bool {
        let env = baseEnv()
        let script = """
        /bin/ps -axww -o comm= | /usr/bin/awk -F/ '$NF=="claude"{f=1} END{exit !f}' && exit 0
        /bin/ps -axww -o args= | /usr/bin/grep -q '@anthropic-ai/claude-code/cl[i]' && exit 0
        exit 1
        """
        let r = await Task.detached { Shell.run("/bin/bash", ["-c", script], env: env) }.value
        return r.code == 0
    }

    // 取一张可以直接发请求的 token。只读钥匙串；只有本机没有任何 claude 进程时才自己换（见 ClaudeTokenPolicy）。
    // token == nil 时 reason 是给界面的说明，调用方据此提示并稍后重试。
    func usableClaudeToken() async -> (cred: Credential, token: String?, reason: String) {
        var cred = await readCredential()
        var refreshed = false
        while true {
            guard let tok = cred.accessToken else {
                return (cred, nil, "无法读取 Keychain token（\(cred.diag)）")
            }
            let exp = expiryDate(cred.expiresAtMs)
            let now = Date()
            if ClaudeTokenPolicy.comfortablyValid(expiresAt: exp, now: now) { return (cred, tok, "") }
            let cli = await claudeCLIRunning()
            let hasRT = !(cred.refreshToken ?? "").isEmpty && !cred.scopes.isEmpty
            switch ClaudeTokenPolicy.action(expiresAt: exp, now: now, cliRunning: cli, hasRefreshToken: hasRT) {
            case .use:
                return (cred, tok, "")
            case .loginRequired:
                return (cred, nil, "登录已失效，需运行 claude auth login")
            case .waitForCLI:
                log("TOKEN \(tokenExpStr(cred.expiresAtMs))，检测到 claude 进程 → 等待其刷新，App 不换 token、不发请求")
                return (cred, nil, "token 已过期，等待 claude 刷新登录")
            case .refreshSelf:
                if !refreshed, await refreshOAuthToken(cred) {
                    refreshed = true
                    cred = await readCredential()
                    continue
                }
                if ClaudeTokenPolicy.usable(expiresAt: exp, now: Date()) { return (cred, tok, "") }
                if await claudeCLIRunning() { return (cred, nil, "token 已过期，等待 claude 刷新登录") }
                return (cred, nil, "token 已过期且刷新失败，需重新登录 claude")
            }
        }
    }

    // 用钥匙串里的 refreshToken 换一张新的 access token。只在本机没有 claude 进程时调用。
    //
    // 走的是 CLI 官方的非交互刷新入口（CLAUDE_CODE_OAUTH_REFRESH_TOKEN + `claude auth login`）：
    // 内部就是一次 grant_type=refresh_token 交换，**不发任何推理请求、不开 5h 窗口、不耗用量**，
    // 实测 ~2.5s 换到一张满血 8 小时的新 token。
    //
    // 为什么必须借 CLI 而不是 App 自己 POST /v1/oauth/token：
    //   服务端**每次都轮换 refresh token**。App 自己换而不写回钥匙串，CLI 手里那个就作废了。
    //
    // ⚠️ 这个入口直接用环境变量里的 refresh token 去换：不拿 CLI 的进程间锁，也不先重读钥匙串比对。
    //   而交互式 claude 会话即使闲置也会在过期前约 5 分钟后台刷新。两边同时拿同一张 refresh token 去换，
    //   服务端会回 400，随后 CLI 判定 refresh token 已死、清空钥匙串 → 全体掉线（2026-09/10 共 6 次）。
    //   所以：有 claude 进程时绝不走这里；调用前再查一次进程、再读一次钥匙串，把竞态窗口压到最小。
    @discardableResult
    func refreshOAuthToken(_ cred: Credential) async -> Bool {
        if busyRefreshingToken { return false }
        busyRefreshingToken = true
        defer { busyRefreshingToken = false }
        // 发起前最后确认：期间若有 claude 起来，交给它换。
        if await claudeCLIRunning() {
            log("TOKEN refresh 取消：检测到 claude 进程，交给它刷新")
            return false
        }
        // 再读一次钥匙串：refresh token 已被别人换掉就不要再拿旧的去撞。
        let latest = await readCredential()
        if latest.refreshToken != cred.refreshToken {
            log("TOKEN refresh 跳过：钥匙串已被其它进程刷新 → \(tokenExpStr(latest.expiresAtMs))")
            return latest.accessToken != nil
        }
        guard let rt = latest.refreshToken, !rt.isEmpty, !latest.scopes.isEmpty else {
            log("TOKEN refresh 跳过：钥匙串缺 refreshToken 或 scopes（需 claude auth login）")
            return false
        }
        var env = baseEnv()
        env["CLAUDE_CODE_OAUTH_REFRESH_TOKEN"] = rt              // 只进子进程环境，绝不落日志
        env["CLAUDE_CODE_OAUTH_SCOPES"] = latest.scopes.joined(separator: " ")
        env.removeValue(forKey: "ANTHROPIC_API_KEY")             // 走订阅，别被 API key 抢了认证路径
        env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
        let bin = keepaliveClaudeBin
        log("TOKEN refresh start（无 claude 进程；当前 \(tokenExpStr(latest.expiresAtMs))）")
        // 与 fire() 同样用 runDisclaimed：写钥匙串的责任落到子进程，不然本 App 的 ad-hoc 签名会天天弹授权框。
        // stdin 接 /dev/null：CLI 会把 stdin 当补充输入读，不给 EOF 可能永久挂住。
        let cmd = "exec '\(bin)' auth login < /dev/null"
        let r = await Task.detached { Shell.runDisclaimed("/bin/bash", ["-c", cmd], env: env) }.value
        // 防御性脱敏：万一 CLI 把凭据回显进 stdout/stderr，也不能进日志。
        let out = r.out.replacingOccurrences(of: rt, with: "<REDACTED>")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " | ")
        let after = await readCredential()
        if r.code == 0 {
            log("TOKEN refresh ok → \(tokenExpStr(after.expiresAtMs))")
            return true
        }
        // 刷新期间若有别的进程抢先换好，钥匙串里已是一张新的有效 token，按成功继续。
        if after.refreshToken != rt, ClaudeTokenPolicy.usable(expiresAt: expiryDate(after.expiresAtMs), now: Date()) {
            log("TOKEN refresh rc=\(r.code)，但钥匙串已被其它进程刷新 → \(tokenExpStr(after.expiresAtMs))，按成功继续")
            return true
        }
        // CLI 只输出 "Request failed with status code 400"，不带服务端错误体；400 基本就是 refresh token 已失效。
        log("TOKEN refresh failed rc=\(r.code) cliAfter=\(await claudeCLIRunning()): \(String(out.prefix(400)))")
        return false
    }

    // 代理是否开启：api.anthropic.com 需经代理才可达，未开代理时联网动作必失败。
    // 与 keepalive.sh 的 proxy_enabled() 完全同一判断（复用同段 bash，避免两边漂移）：
    //   1) 系统代理：HTTP / HTTPS / SOCKS 任一 Enable : 1
    //   2) 纯 TUN/代理模式：默认路由走 utun 口且该口持有 fake-IP（198.18.0.0/15）
    func proxyEnabled() async -> Bool {
        let env = baseEnv()
        let script = """
        /usr/sbin/scutil --proxy 2>/dev/null | grep -qE '^[[:space:]]*(HTTPEnable|HTTPSEnable|SOCKSEnable)[[:space:]]*:[[:space:]]*1$' && exit 0
        dev=$(/sbin/route -n get default 2>/dev/null | awk '/interface:/{print $2}')
        case "$dev" in utun*) /sbin/ifconfig "$dev" 2>/dev/null | grep -qE 'inet 198\\.(18|19)\\.' && exit 0 ;; esac
        exit 1
        """
        let r = await Task.detached { Shell.run("/bin/bash", ["-c", script], env: env) }.value
        return r.code == 0
    }
}
