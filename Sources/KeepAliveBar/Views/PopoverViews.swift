import SwiftUI

// 点击菜单栏图标弹出的主界面
struct ContentView: View {
    @State private var showingSettings = false
    @EnvironmentObject var s: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showingSettings {
                AppSettingsView(close: { showingSettings = false })
                    .frame(height: 540)
            } else {
                UsageSections(allowsReordering: true)
                Divider()
                ControlSections(openSettings: { showingSettings = true })
            }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear {
            s.popupOpen = true
            if s.autoQueryOnOpen { s.refreshNow() }   // 打开弹窗时按开关决定是否自动查询用量
        }
        .onDisappear { s.popupOpen = false }
    }
}

// 悬停快照：鼠标在菜单栏图标上停 0.8 秒弹出，**不发任何请求**——只把当前内存里的数据画出来。
// 想要最新数值仍然点开弹窗（受“自动查询”开关控制）。底部一行标明数据新鲜度，避免把旧快照当实时值。
// 卡片的毛玻璃背景由 NSVisualEffectView 提供（见 HoverSnapshot.makePanel），这里只画内容，
// 不加 .background —— SwiftUI 的 .regularMaterial 在 NSHostingView 里是“窗口内混合”，
// 窗口背后是空的，糊出来就是一块不透明色块，和弹窗的观感对不上。
struct SnapshotView: View {
    @EnvironmentObject var s: Store

    var freshness: String {
        if s.paused { return "已暂停 · 快照" }
        guard let r = s.lastRefresh else { return "暂无数据 · 快照" }
        return "数据截至 \(localHM(r)) · 快照"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            UsageSections()
            Text(freshness).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 300)
    }
}
