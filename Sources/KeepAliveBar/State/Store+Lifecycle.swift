import Foundation
import ServiceManagement

extension Store {
    // 首次启动“授权预热”：只跑一次（didWarmup 标记）。趁用户在场，主动各 fire 一次 claude / codex，
    // 让本来只有到期执行任务时才冒出来的系统授权框（claude 读/写钥匙串、codex 若碰保护目录的文件访问）
    // 提前弹出来，用户当场点“始终允许”，而不是在某个 5h 边界随机冒出、阻塞续窗。
    //   · claude fire → 读 Keychain「Claude Code-credentials」→ 弹一次“始终允许”（钉在固定路径副本
    //     keepalive-claude 上，身份稳定，点一次长期有效）。这是预热的主要价值。
    //   · codex fire → 确认登录态可用；注意保活的 codex 从 App Support（非保护目录）发起，本就不需要
    //     “访问桌面”授权，所以预热不会（也无法）复现你在 ~/Desktop 里跑 codex 时的 node 授权框——
    //     那个由 `brew pin node`（冻结 node 版本、路径不再漂移）根治，不靠预热。
    // 想重新触发预热：删掉 UserDefaults 的 didWarmup 键即可。
    func warmupIfNeeded() {
        guard !paused, !crossKeepaliveEnabled, !preferences.bool(forKey: "didWarmup") else { return }
        preferences.set(true, forKey: "didWarmup")   // 先落标记：即便本次失败也不反复打扰
        log("WARMUP: 首次启动 → 主动各跑一次 claude/codex，触发系统授权（钥匙串/文件访问），请在弹框点“始终允许”")
        Task { [weak self] in
            guard let self else { return }
            if self.claudeAutoEnabled { await self.fire() }        // 触发 claude 读/写钥匙串 → 首次弹“始终允许”
            if self.codexAutoEnabled { await self.fireCodex() }    // 首次跑一次 codex，确认登录态/授权可用
        }
    }

    // 手动刷新：清零退避指数，否则退到 30 分钟后用户点“刷新”还得按老节奏等——手动动作应当立刻生效。
    func refreshNow() { refreshRetryFailures = 0; Task { await refresh() } }

    // 暂停 / 恢复：暂停后停止 GET 与续窗；恢复后立即刷新一次
    func togglePause() {
        paused.toggle()
        log(paused ? "PAUSED（停止 GET 与续窗）" : "RESUMED（恢复监控）")
        if paused {
            cancelRefreshRetry()
        } else {
            refreshNow()
        }
    }

    // 开机自启：注册/注销登录项；首次开启时跳转「系统设置▸登录项」让用户确认
    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
            lastError = nil
        } catch {
            lastError = "应用：开机自启设置失败：\(error.localizedDescription)（可在系统设置手动添加）"
        }
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        if on { SMAppService.openSystemSettingsLoginItems() }  // 跳转设置
    }
}
