import Foundation

extension Store {
    func baseEnv() -> [String: String] {
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        e["HOME"] = home
        return e
    }

    // 保活专用的固定路径 claude 副本：身份（路径/cdhash）永不随每日自动更新变，
    // 于是钥匙串“始终允许”一次点了能长期生效，不再每次到期都弹版本号授权框。
    // 副本用 install-app.sh 复制生成（cp -p 保留 Anthropic Developer ID 签名）。
    // 若副本缺失则退化为 PATH 里的 claude（仍能保活，只是会恢复每次弹框）。
    var keepaliveClaudeBin: String {
        let pinned = "\(home)/.local/share/claude/keepalive-claude"
        return FileManager.default.isExecutableFile(atPath: pinned) ? pinned : "claude"
    }

    var keepaliveCodexBin: String {
        let candidates = [
            "\(home)/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? "/usr/bin/env"
    }

    var keepaliveCodexUsesEnv: Bool { keepaliveCodexBin == "/usr/bin/env" }
}
