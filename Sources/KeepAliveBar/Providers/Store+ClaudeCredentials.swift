import Foundation

extension Store {
    // 读取 Keychain 凭据。返回 accessToken + 过期时刻(ms) + 失败诊断串（供日志精确定位）。
    // ⚠️ 绝不记录 token 本身；仅在失败时把 security 的退出码与错误输出（截断）带回来——
    //   security 成功时 out 是明文 token，只有 rc!=0 时 out 才是报错文本（item not found / auth denied 等）。
    // refreshToken / scopes 也读出来：过期时要拿它们走 CLI 的非交互刷新入口（见 refreshOAuthToken）。
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
            let msg = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            return Credential(accessToken: nil, refreshToken: nil, scopes: [], expiresAtMs: nil,
                              diag: "security rc=\(r.code) \(String(msg.prefix(140)))")
        }
        guard let d = r.out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            return Credential(accessToken: nil, refreshToken: nil, scopes: [], expiresAtMs: nil,
                              diag: "凭据 JSON 解析失败")
        }
        let o = (obj["claudeAiOauth"] as? [String: Any]) ?? obj
        let tok = o["accessToken"] as? String
        let exp = (o["expiresAt"] as? NSNumber)?.doubleValue
        return Credential(accessToken: tok,
                          refreshToken: o["refreshToken"] as? String,
                          scopes: (o["scopes"] as? [String]) ?? [],
                          expiresAtMs: exp,
                          diag: tok == nil ? "凭据里无 accessToken 字段（API-key 用户？）" : "")
    }

    // token 过期状态的紧凑串：把剩余寿命算出来，供 401 时对照（过期→大概率就是 401 主因）。
    func tokenExpStr(_ expiresAtMs: Double?) -> String {
        guard let ms = expiresAtMs else { return "未知" }
        let exp = Date(timeIntervalSince1970: ms / 1000)
        let rem = exp.timeIntervalSince(Date())
        return "\(fmt(exp))(\(rem >= 0 ? "剩\(Int(rem / 60))m" : "已过期\(Int(-rem / 60))m"))"
    }

    // 是否该提前换 token。expiresAt 未知时返回 false —— 不主动刷，交给 401 分支兜底。
    func tokenNeedsRefresh(_ expiresAtMs: Double?) -> Bool {
        guard let ms = expiresAtMs else { return false }
        return Date(timeIntervalSince1970: ms / 1000).timeIntervalSinceNow < tokenRefreshBufferSec
    }

    // 用钥匙串里的 refreshToken 换一张新的 access token。
    //
    // 走的是 CLI 官方的非交互刷新入口（CLAUDE_CODE_OAUTH_REFRESH_TOKEN + `claude auth login`）：
    // 内部就是一次 grant_type=refresh_token 交换，**不发任何推理请求、不开 5h 窗口、不耗用量**，
    // 实测 ~2.5s 换到一张满血 8 小时的新 token。
    //
    // 为什么必须借 CLI 而不是 App 自己 POST /v1/oauth/token：
    //   服务端**每次都轮换 refresh token**（实测两次调用 refreshToken 全变）。App 自己换而不写回钥匙串，
    //   CLI 手里那个就作废了，下次 claude 起来直接要求重新登录。交给 CLI，写回和轮换都是它的事。
    //
    // 为什么不需要跟 CLI 抢锁、也不需要判断“有没有 claude 在跑”：
    //   一是本地交互式会话空闲时根本不刷 token（只在真要发 API 请求时懒刷新，没有后台定时器），
    //     所以“有 claude 窗口开着”对“token 会不会被别人刷”毫无预测力，拿它当闸门只会挡住自己；
    //   二是 CLI 的刷新逻辑本来就按“随时可能有兄弟进程在旁边轮换”写的——它在加锁后、POST 前会重读
    //     钥匙串比对 accessToken，交换失败后也会先重读、发现已被换掉就直接当成功返回，
    //     连清 dead token 那步都有 refreshToken 的 CAS 守卫。竞态是良性的。
    @discardableResult
    func refreshOAuthToken(_ cred: Credential) async -> Bool {
        if busyRefreshingToken { return false }
        busyRefreshingToken = true
        defer { busyRefreshingToken = false }
        guard let rt = cred.refreshToken, !rt.isEmpty, !cred.scopes.isEmpty else {
            log("TOKEN refresh 跳过：钥匙串缺 refreshToken 或 scopes（API-key 用户？）")
            return false
        }
        var env = baseEnv()
        env["CLAUDE_CODE_OAUTH_REFRESH_TOKEN"] = rt              // 只进子进程环境，绝不落日志
        env["CLAUDE_CODE_OAUTH_SCOPES"] = cred.scopes.joined(separator: " ")
        env.removeValue(forKey: "ANTHROPIC_API_KEY")             // 走订阅，别被 API key 抢了认证路径
        env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
        let bin = keepaliveClaudeBin
        log("TOKEN refresh start（当前 \(tokenExpStr(cred.expiresAtMs))）")
        // 与 fire() 同样用 runDisclaimed：写钥匙串的责任落到子进程，不然本 App 的 ad-hoc 签名会天天弹授权框。
        // stdin 接 /dev/null：CLI 会把 stdin 当补充输入读，不给 EOF 可能永久挂住。
        let cmd = "exec '\(bin)' auth login < /dev/null"
        let r = await Task.detached { Shell.runDisclaimed("/bin/bash", ["-c", cmd], env: env) }.value
        // 防御性脱敏：万一 CLI 把凭据回显进 stdout/stderr，也不能进日志。
        let out = r.out.replacingOccurrences(of: rt, with: "<REDACTED>")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let after = await readCredential()
        if r.code == 0 {
            log("TOKEN refresh ok → \(tokenExpStr(after.expiresAtMs))")
            return true
        }
        // 反向竞态：CLI 可能抢在我们前面用同一个 refreshToken 换过了，轮换后我们手里这个已失效 →
        // 我们这次拿到 invalid_grant。但此时钥匙串里其实已经是一张新的有效 token，别误判成失败。
        if !tokenNeedsRefresh(after.expiresAtMs) {
            log("TOKEN refresh rc=\(r.code)，但钥匙串已被其它进程刷新 → \(tokenExpStr(after.expiresAtMs))，按成功继续")
            return true
        }
        log("TOKEN refresh failed rc=\(r.code): \(String(out.prefix(160)))")
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
