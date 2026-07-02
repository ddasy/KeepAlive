# Claude Code 5 小时窗口 · 精确保活 (KeepAlive)

在你不工作的时段，自动、**精确地**在每个 5 小时窗口关闭后立刻发一条极小消息，
开启下一个 5 小时窗口 —— 让窗口的时钟在闲置时段就开始走，等你真正干活时能拿到更多次满额窗口。

## 它凭什么“精确”

它不靠盲猜 5 小时间隔，也不靠 `ccusage`（后者把首条消息**向下取整到整点**再算，误差可达 ~1 小时）。
它直接查 Claude Code / `/usage` 用的那个官方端点，拿**服务端秒级真值**：

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <macOS Keychain "Claude Code-credentials" 里的 OAuth token>
anthropic-beta: oauth-2025-04-20
```

响应里的 `five_hour.resets_at` 就是当前 5 小时窗口的**真实重置时刻**。
逻辑：轮询该字段 → 一旦越过重置时刻（窗口已关）→ 发一条极小的保活消息 → 开启新窗口 → 循环。
由 launchd 每 5 分钟无状态轮询驱动，**睡眠/重启后自愈**。

保活消息本身已压到最小上下文：`cd ~/Desktop/Null`（空目录，无文件/CLAUDE.md/git）
+ `--model haiku`（最便宜）+ `--strict-mcp-config`（不加载任何 MCP 工具）
+ `unset ANTHROPIC_API_KEY`（确保走订阅而非 API 账单）。

## 两种运行方式（二选一，别同时开）

| 方式 | 适合 | 有无界面 |
|---|---|---|
| **A · 菜单栏 App**（推荐） | 想在顶栏随时看用量、手动/自动保活 | 有,菜单栏小插件 |
| **B · launchd 脚本** | 纯后台、无界面、极简 | 无 |

## 文件

| 文件 | 作用 |
|---|---|
| `KeepAliveBar.swift` | 菜单栏 App 源码（SwiftUI `MenuBarExtra`） |
| `build-app.sh` | 编译并打包成 `KeepAliveBar.app`（菜单栏 Agent，无 Dock 图标） |
| `install-app.sh` | 可选：装到 `/Applications` + 设开机自启 |
| `null/` | 保活消息从这个空目录发起（避免读入任何上下文） |
| `keepalive.sh` | launchd 版核心：查 usage → 判断 → 必要时发保活 |
| `status.sh` | **只读**面板：打印 5h/周用量 + 真实重置时间。随时可跑，不发消息 |
| `com.iu.claude-keepalive.plist` | launchd LaunchAgent 模板 |
| `install.sh` / `uninstall.sh` | 启用 / 停用 launchd 后台服务 |
| `keepalive.log` / `state.json` | launchd 版的日志与状态 |

App 的日志/空目录在 `~/Library/Application Support/KeepAliveBar/`。

## A · 菜单栏 App（推荐）

```bash
bash build-app.sh                 # 编译 → KeepAliveBar.app
open KeepAliveBar.app             # 启动，菜单栏出现 ⚡︎ 图标
# 满意后：装到 /Applications 并开机自启（可选）
bash install-app.sh
```

菜单栏图标显示距 5h 窗口重置的倒计时（如 `⚡︎ 1h35m`）；点击弹窗有：5h/周 用量进度条 +
精确重置时间、`自动保活`开关、`开机自启`开关、`立即保活` / `刷新` / `退出`。开着它、`自动保活`打开，
窗口一关就会自动续下一个 5h。若首次弹出「KeepAliveBar 想访问钥匙串」，点**始终允许**。

**开机自启**：勾选后用 `SMAppService` 注册登录项并跳转「系统设置 ▸ 通用 ▸ 登录项」让你确认
（普通 App 登录项其实是**秒开、无需密码**）。登录项绑定 App 当前所在路径，所以**建议先
`bash install-app.sh` 把 App 放到 /Applications，再勾开机自启**，位置才稳定。

## B · launchd 脚本

```bash
# 先看看现状（只读，安全）
bash status.sh

# 启用 24/7 后台保活
bash install.sh

# 确认在跑
launchctl list | grep claude-keepalive
tail -f keepalive.log

# 停用
bash uninstall.sh
```

## 怎么验证它真的“开了新窗口”

在一段闲置（窗口关闭）之后，观察 `keepalive.log` 出现 `🔔 FIRED`，
然后立刻 `bash status.sh` —— 5 小时窗口的 `重置` 时间应跳到约 5 小时之后、用量从高位回落。

## 配置（环境变量，可写进 plist 的 EnvironmentVariables）

| 变量 | 默认 | 说明 |
|---|---|---|
| `KA_MODEL` | `haiku` | 保活用的模型（最便宜，最省周限额） |
| `KA_WORKDIR` | `~/Desktop/Null` | 从这个**空目录**发起保活，避免读入目录内容/CLAUDE.md/git 上下文 |
| `KA_BUFFER_SEC` | `90` | 真实重置时刻之后再等多少秒才发（确保旧窗口彻底关闭） |
| `KA_MIN_REFIRE_SEC` | `17400` | 防抖：两次保活最小间隔（4h50m） |
| `KA_WEEKLY_GUARD_PCT` | `101` | 周用量≥此百分比时暂停保活（默认永不触发；设 90 可省额度） |
| 轮询频率 | plist `StartInterval=300` | 调小 → 窗口衔接更紧密，但请求更频繁 |

## ⚠️ 重要前提与风险（务必了解）

1. **依赖一项“被暂停”的计费政策。** Anthropic 曾计划从 2026-06-15 起把 `claude -p` / Agent SDK /
   headless 用量从订阅的 5 小时+周限额里**拆出去**、改走单独的每月额度。若那样，`claude -p`
   就**不再重置交互窗口**，本方案失效。该改动已于 6-15 被官方**暂停**，目前仍计入订阅限额
   —— 但官方明说会重推，届时需重新评估（可用 `status.sh` 观察保活后 `resets_at` 是否真的跳动来判断是否仍生效）。

2. **保活只优化“5 小时窗口不浪费”，不增加周总量。** 你的周限额是硬上限；保活消息本身用量≈0，
   对周限额几乎无消耗，但也帮不了你突破周上限。

3. **必须走订阅认证。** 脚本已在发消息前 `unset ANTHROPIC_API_KEY`，避免误走 API 计费。
   若你机器上强制用 API key，则保活会计入 API 账单而非订阅窗口。

4. **这是对个人订阅的自动化“保温”，属灰色地带。** 仅用于你自己的账号；Anthropic 未来的政策
   调整可能限制此类用法。请自行判断是否符合你的使用条款。
