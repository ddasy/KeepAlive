# Claude Code / Codex 5 小时窗口 · 精确保活 (KeepAlive)

在你不工作的时段，自动、**精确地**在每个 5 小时窗口关闭后立刻发一条极小消息，
开启下一个 5 小时窗口。两侧都直接查服务端真值：Claude 用 `/api/oauth/usage`，
Codex 用 `/backend-api/wham/usage`。那条"极小消息"是**直连 HTTP 的推理请求**，
不再套一层 agent CLI —— Claude 8 tokens、Codex 30 tokens，而不是 22,698 / 13,871。

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

## 保活消息为什么只要 8 个 token

保活需要的只是**一条计费到订阅的推理请求**。`claude -p` / `codex exec` 会额外背上工具定义、
系统提示词、全局 `CLAUDE.md`/`AGENTS.md`、skills 清单——这些对"开窗"没有任何贡献，
却占了 99.9% 的 token。所以保活直接打 HTTP，用的是同一张订阅 OAuth 凭据：

| | 旧写法（CLI） | 现在（直连 HTTP） |
|---|---|---|
| Claude | `claude -p 'Reply OK' --model haiku` → **22,698** in / 51 out | `POST /v1/messages` → **8** in / 1 out |
| Codex | `codex exec 'Reply OK'` → **13,871** in / 16 out | `POST /backend-api/codex/responses` → **14** in / 16 out |

（2026-09-06 同机同账号实测。Claude 那 141KB 请求体里，29 个工具定义就占 97KB。）

**两侧都已实证直连确实能开窗**：
- Codex：5h 窗口关闭后 `reset_at` 会随时间滚动（= 未锚定）；发出一条 30 token 的裸 HTTP
  请求后，它立刻固定在"请求时刻 + 5h"不再变化 —— 新窗口已开。
- Claude：2026-09-07 03:29:59 窗口关闭，03:31:36 直连发出 8 token 请求，`five_hour.resets_at`
  从 `null` 变为 `08:30:00`（= 旧窗口末尾 + 5h，Claude 的窗口按半点对齐，不是从消息时刻起算）。

⚠️ `/api/oauth/usage` 对新窗口有**传播延迟**：实测发出请求 6 秒后接口仍返回 `null`，约 70 秒
后才出现新窗口。所以自证是**轮询等待**（Claude 累计 125s，Codex 53s）而不是发完看一眼——
只等几秒会稳定误报"没开出窗口"。

**自证，但故意不做自动降级**：每次直连发完都会回读 usage 确认窗口真的开出来了；
没开出来（或直连本身失败、token 过期、离线）就**明确报错**，按原节奏重试并每次刷一条 ❌ 日志。

不自动回落 CLI 是刻意的——否则直连哪天失效了，CLI 会把它悄悄补上，表面一切正常，
实际早已退回每次 22,698 tokens 且无人察觉。宁可吵，也不要"看起来正常"。

要手动退回旧写法：`KA_CLAUDE_DIRECT=0` / `KA_CODEX_DIRECT=0`（App 侧
`defaults write com.iu.keepalivebar directFire -bool false`）。这是显式开关，不是自动降级。

⚠️ 附带影响：codex 的登录态由 CLI 维护。既然不再自动回落 CLI，token 过期后直连会一直 401、
不会被自动刷新——跑一次 `codex` 或重新登录即可。日志里会写清楚。

CLI 路径（手动切回时）仍在独立的系统临时空目录中运行，命令结束后立即删除该目录，因此没有
文件、`CLAUDE.md` 或 git 上下文可被读取或遗留；Claude 用 `--model haiku`、`--strict-mcp-config`，
并清除 `ANTHROPIC_API_KEY`（确保走订阅而非 API 账单）。

## 两种运行方式（二选一，别同时开）

| 方式 | 适合 | 有无界面 |
|---|---|---|
| **A · 菜单栏 App**（推荐） | 想在顶栏随时看用量、手动/自动保活 | 有,菜单栏小插件 |
| **B · launchd 脚本** | 纯后台、无界面、极简 | 无 |

## 文件

| 文件 | 作用 |
|---|---|
| `Sources/KeepAliveBar/` | 菜单栏 App，按状态、策略、平台实现、展示和界面分目录 |
| `scripts/swift-sources.sh` | 构建与测试共用的 Swift 源文件清单 |
| `docs/ARCHITECTURE.md` | 模块职责、状态约束、新功能放置规则与验证流程 |
| `build-app.sh` | 编译 → 临时目录组包 → 整包替换 `/Applications/KeepAliveBar.app` 并重启（磁盘上只留这一份） |
| `install-app.sh` | `build-app.sh` + 保活专用 `keepalive-claude` 固定副本 + 开机自启登录项（自动去重） |
| `keepalive.sh` | launchd 版核心：查 Claude usage / Codex 快照 → 判断 → 必要时发保活 |
| `status.sh` | **只读**面板：打印 Claude/Codex 用量、重置时间和自动激活状态。随时可跑，不发消息 |
| Codex 用量来源 | `GET /backend-api/wham/usage`（服务端真值，免费）；不可达时才退回扫 rollout 日志 |
| `com.iu.claude-keepalive.plist` | launchd LaunchAgent 模板 |
| `install.sh` / `uninstall.sh` | 启用 / 停用 launchd 后台服务 |
| `keepalive.log` / `state.json` | launchd 版的日志与状态 |

App 的日志在 `~/Library/Application Support/KeepAliveBar/`。

## A · 菜单栏 App（推荐）

```bash
bash build-app.sh                 # 编译 → 直接装进 /Applications 并重启，菜单栏出现 Clawd 图标
bash install-app.sh               # 再加：开机自启登录项 + keepalive-claude 固定副本
```

**只会有一份 App**：`build-app.sh` 在临时目录里组包，编译签名都成功后才整包替换
`/Applications/KeepAliveBar.app`（编译失败不会碰你正在用的那份），项目目录里不再留 `.app`
副本——否则聚焦搜索会并排列出两个同名 App，误点项目里那份就会跑出第二个实例
（两个都保活、共用同一份 UserDefaults 和日志）。想编译到别处试跑：
`KA_DEST=/tmp/ka/KeepAliveBar.app bash build-app.sh`。

菜单栏图标显示 Claude 距 5h 窗口重置的倒计时；点击弹窗有 Claude/Codex 的 5h/周用量、
重置时间、`Claude 保活` / `Codex 保活` 两个独立开关、`开机自启`开关、`刷新` / `退出`。
对应开关打开后，Claude 窗口一关会自动续窗；Codex 由 `wham/usage` 判定：窗口到期、
或服务端明确"当前无活动窗口"时立即续窗（该接口不可达时才退回旧的"连续 5 小时"兜底）。

**两侧的窗口锚定方式不同**，这决定了各自要多"急"：Claude 按半点对齐（03:31 发的消息落进
03:30–08:30 那个窗口，早发晚发不亏）；Codex 从**消息时刻**起算，晚发一秒就真少一秒。
所以 App 对 Codex 的用量轮询平时是 5 分钟一次，**一旦窗口到点就收紧到 20 秒**，
把每轮损耗从平均 ~2.5 分钟压到 ~10 秒；开火成功后自动恢复 5 分钟节奏。
（关掉 Codex 保活、周限已满、或正在开火时不收紧，避免空转。）

**周限闸门**：Claude 周限到 100%、或 Codex 周限剩余 0 时，5h 保活一律不发（发也发不出去，
只会每 3 分钟撞一次墙刷错误日志）；越过周重置时刻自动解除——Claude 在下一次刷新拿到真实的新周用量后续窗，
Codex 同理按新的 rollout 快照恢复。被拦住时弹窗顶部会有一行说明，不至于以为保活坏了。
Claude 侧被拦期间联网复查最多每 30 分钟一次（且不会晚于周重置后 1 分钟）。

**弹窗结构**：分成「用量」（Claude + Codex，纯展示、无副作用）与「操作」（开关/按钮/上次保活结果）
两部分——悬停快照直接复用前者，两处永远同一份渲染代码。

| 开关 | 作用 |
|---|---|
| `Claude 保活` | Claude 5h 窗口关闭后是否自动续窗（独立开关，不影响 Codex） |
| `Codex 保活` | Codex 5h 窗口到期后是否自动发 `Reply OK` 续窗（独立开关，不影响 Claude） |
| `开机自启` | 注册登录项（`SMAppService`） |
| `自动查询` | 点开弹窗时是否自动查一次用量 |
| `隐藏倒计时` | 菜单栏只留 Clawd 图标，不显示 Claude 下次重置的剩余时间（暂停时仍显示 `⏸`，否则会忘了自己按过暂停） |

**悬停快照**：鼠标停在菜单栏图标上 **0.8 秒**，图标正下方浮出一张只读快照（Claude + Codex 两块用量），
**不发任何请求**——只画当前内存里的数据，底部一行标明数据截至时刻；鼠标移开即消失，也不吃点击。
配合`隐藏倒计时`用最省心：菜单栏干干净净，想看一眼就停一下鼠标，要最新数值再点开弹窗。

**开机自启**：勾选后用 `SMAppService` 注册登录项并跳转「系统设置 ▸ 通用 ▸ 登录项」让你确认
（普通 App 登录项其实是**秒开、无需密码**）。登录项绑定 App 当前所在路径，所以**建议先
`bash install-app.sh` 把 App 放到 /Applications，再勾开机自启**，位置才稳定。

### 交叉保活（菜单栏 App）

在弹窗的「保活」区域开启 **交叉保活**，设置两侧周期起点的最小间隔，默认 **120 分钟**。
可在 30–145 分钟之间以 5 分钟调整；关闭后恢复原来的到期续窗。此功能仅在两侧保活均开启时生效。

- 先到期的一侧按原有到期缓冲续窗；后到期的一侧若与对方周期起点相隔不超过阈值，就延后。
- 例如 Claude 13:00 开始新周期、Codex 14:00 到期，阈值 120 分钟时，Codex 等到 15:00 之后再触发。
- 严格大于阈值：相等时仍等待，越过边界后由现有调度触发（保留到期缓冲、轮询和失败退避）。
- 等待期间显示「Claude / Codex 交叉等待至…」；Claude 等待时菜单栏显示 `↔` 和等待倒计时。
- 以已确认的重置时间减去 5 小时推算周期起点，没有可用真值时才参考成功保活时间；失败尝试不推进周期。
- 设置和周期依据会持久化。每 5 分钟重查两侧用量，识别手动使用引起的新窗口，发送前再次检查间隔。
- 睡眠恢复后两侧都到期时，优先处理较早到期的一侧；同刻/时间未知时 Claude 优先。发送串行执行。
- 暂停、单侧关闭、周额度限制及失败退避继续生效。交叉模式跳过首次同时发送两侧消息的授权预热。

阈值上限低于 150 分钟，因为两个 5 小时周期稳定错开时，相邻间隔之和为 5 小时。
此功能控制的是 **App 的自动触发时机**：用户手动发消息和服务端窗口对齐规则仍可能改变实际重置间隔，
App 会根据之后查到的真实窗口重新计算，不能保证平台侧重置时间每次都精确满足阈值。
旧安装默认保持关闭；开启后设置会保存。纯后台 `keepalive.sh` 仍采用原调度，不读取此 App 设置。

开发验证：`bash tests/run-cross-keepalive.sh`，使用独立偏好设置测试实际 Store 与调度策略，
不启动 App 定时器、不联网、不发送保活请求。
测试直接编译生产源文件，以依赖注入隔离偏好设置，不改写源代码。
完整构建验证：`KA_VERIFY_ONLY=1 bash build-app.sh`，检查编译、资源与签名，不影响已安装实例。
工程结构与新增功能指南见 [架构文档](docs/ARCHITECTURE.md)。

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
| `KA_CLAUDE_DIRECT` | `1` | 1=直连 `POST /v1/messages` 保活（8 tokens）；0=手动退回 `claude -p`（22,698 tokens）。失败时不会自动降级 |
| `KA_CODEX_DIRECT` | `1` | 1=直连 `POST .../codex/responses`（30 tokens）；0=手动退回 `codex exec`（13,871 tokens）。失败时不会自动降级 |
| `KA_API_MODEL` | `claude-haiku-4-5-20251001` | 直连用的完整 model id（CLI 收别名，HTTP 不收） |
| `KA_MODEL` | `haiku` | 切回 CLI 写法时用的模型（最便宜，最省周限额） |
| `KA_BUFFER_SEC` | `90` | 真实重置时刻之后再等多少秒才发（确保旧窗口彻底关闭） |
| `KA_MIN_REFIRE_SEC` | `17400` | 防抖：两次保活最小间隔（4h50m） |
| `KA_WEEKLY_GUARD_PCT` | `101` | 周用量≥此百分比时暂停保活（默认永不触发；设 90 可省额度） |
| `KA_CODEX_BIN` | 自动查找 | Codex CLI 路径 |
| `KA_CODEX_MODEL` | `gpt-5.6-luna` | Codex 保活模型 |
| `KA_CODEX_EFFORT` | `low` | Codex reasoning effort |
| `KA_CODEX_PROMPT` | `Reply OK` | Codex 保活消息，建议保持为 `Reply OK` |
| `KA_CODEX_FALLBACK_SEC` | `18000` | 没有 Codex reset 快照时，等待 5 小时再首次激活 |
| `KA_CODEX_MIN_REFIRE_SEC` | `17400` | Codex 两次激活最小间隔（4h50m） |
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

登录到期提醒：Claude 区域在点击弹窗和悬停快照中显示钥匙串的
`refreshTokenExpiresAt`（登录续期截止时间），提前 3 天显示提醒，截止后提示执行 `/login`。
菜单栏同时显示 `⚠︎`，即使隐藏倒计时或暂停保活也会保留提醒。
登录期限启动时读取、此后每 5 分钟本地复查；重新登录后的正常凭据读取也会更新期限。
登录期限与名称同一行右对齐；读取失败或字段缺失时隐藏期限条目，不会用短期 `expiresAt` 替代。
Codex 当前凭据没有提供可确认的登录到期时间，因此不显示期限条目。
手动排序时点击名称展示上下箭头，临时隐藏该区域的期限与提醒；完成移动、再次点击名称或关闭弹窗后恢复。
