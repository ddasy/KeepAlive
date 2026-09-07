# KeepAliveBar 工程结构

菜单栏应用是一个 Swift 模块，使用 SwiftUI / AppKit，最低目标为 macOS 13。
构建仍使用系统 swiftc，不要求 Xcode 工程或第三方包。纯后台 launchd 脚本是一条独立运行路径。

## 目录与职责

| 目录 | 职责 | 维护入口 |
|---|---|---|
| `Sources/KeepAliveBar/App` | 应用入口、菜单栏装配、悬停窗口、图标 | `KeepAliveBarApp.swift`、`HoverSnapshot.swift`、`MenuBarArtwork.swift` |
| `State` | ObservableObject 状态、设置恢复、生命周期与用户操作 | `Store.swift`、`Store+Lifecycle.swift` |
| `Domain` | 接口数据结构与无副作用决策 | `UsageModels.swift`、`AutomaticOrder.swift`、`CrossKeepalivePolicy.swift` |
| `Scheduling` | 周限拦截、交叉等待、定时推进、Claude 到期确认 | `Store+Scheduling.swift` |
| `Providers` | Claude/Codex 凭据、用量获取与保活请求 | 按 AI 和查询/保活职责命名的 `Store+*.swift` |
| `Infrastructure` | 外部进程、环境路径、诊断日志 | `Shell.swift`、`Store+Environment.swift`、`Store+Logging.swift` |
| `Presentation` | 当前显示顺序、菜单栏倒计时、日期和用量展示辅助 | `Store+Presentation.swift`、`DisplayFormatting.swift` |
| `Views` | 用量界面、设置控件、弹窗和快照组合 | `UsageViews.swift`、`SettingsViews.swift`、`PopoverViews.swift` |
| `tests` | 策略、展示、状态调度、设置隔离测试 | `TestMain.swift` 统一入口 |

这里的目录是同一编译模块内的职责划分，不是独立的 Swift package。`Store+…` 文件仍是同一个 Store 的扩展。
保留这一点是为了让交叉保活、异步请求和界面使用同一份状态及执行锁。
若未来需要在 CLI 或其他产品中复用网络客户端，再将请求与解析提取成独立服务；不要为每个文件新建 Store。

## 状态和依赖约束

- `Store` 及其扩展受 `@MainActor` 隔离。视图通过环境读取 Store，状态项和悬停窗口使用 `Store.shared`。
- `Store.swift` 存放发布状态、运行标记和初始化。按职责扩展需要跨文件访问的标记使用模块内访问级别；视图不直接修改执行锁、重试计数等运行状态。
- 偏好设置通过 `Store(preferences:monitoring:)` 注入。生产默认 `.standard`，保留原 bundle ID、所有设置键和持久化格式。
- 测试使用每次运行独有的 UserDefaults suite，并传入 `monitoring: false`。该参数只禁止初始化时启动任务，不会使显式调用网络/保活方法自动变成模拟操作。
- 所有新增设置读写都走 `preferences`，不要在扩展里重新使用 `UserDefaults.standard`。
- 排列、图标、倒计时共同依据 `displayedCodexFirst`；自动排序只读取已知数据，不触发查询。
- `windowEnd` 和 `codexCrossWindowEnd` 是保留的窗口锚点。nil 快照不能随意抹掉它们；Codex 空闲时滚动的 reset 也不能当成新窗口。
- 交叉等待和执行锁继续统一管理。不要因为移动方法而改变 guard 的先后顺序、await 前后的锁范围、重试节奏或 API/CLI 回退策略。
- 日志不得写入 access token、refresh token 或完整凭据输出。

## 新增功能放哪里

1. 新增排序或调度规则：先将判断放到 `Domain`，使用显式时间和输入值，添加边界测试，再接入 Store。
2. 新增展示字段：在 `Presentation` 统一计算，视图消费结果；涉及置顶 AI 时同时检查菜单栏与悬停预览。
3. 新增设置：在 Store 声明、恢复和保存，在 `SettingsViews` 添加控件，测试默认值与重启恢复。
4. 修改 API、凭据或保活：进入对应 `Providers` 文件；系统命令公共机制放到 `Infrastructure`。
5. 新增 AI：现有排序输入是 Claude/Codex 两方，必须同步扩展领域策略、发布状态、调度、展示和测试，不能只新增一个视图区块。

## 构建与测试

```bash
# 生产代码直接参与测试，无文本替换、网络或推理请求
bash tests/run-cross-keepalive.sh

# 编译优化版本、组装资源、签名并验证；不退出旧实例、不安装
KA_VERIFY_ONLY=1 bash build-app.sh

# 覆盖 /Applications/KeepAliveBar.app 并启动
bash build-app.sh
```

`scripts/swift-sources.sh` 是构建和测试共用的文件清单：收集 `Sources/KeepAliveBar/<职责目录>/*.swift`。
新增文件应放在该层级；增加更深的目录时，需要同时更新清单。测试只排除 `App/KeepAliveBarApp.swift`，由 `tests/TestMain.swift` 提供入口，所有其他生产文件保持原样编译。

`tests/run-cross-keepalive.sh` 保留旧命令名称以兼容既有使用方式，现在执行全部 Swift 测试。
测试分为策略、展示、状态调度和设置依赖隔离；测试失败通过非零退出码报告。

## 此次拆分的行为边界

设置键、数据路径、应用标识、图标资源、API 地址、查询与保活节奏均保持原样。
此前发现的 HTTP 429 冷却问题没有在这次结构重构中修改；后续应在查询入口单独修复并验证。
`keepalive.sh`、`status.sh` 仍为独立后台模式，不读取本应用的自动排序设置。
