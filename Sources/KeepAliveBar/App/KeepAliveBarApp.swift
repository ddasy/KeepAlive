import SwiftUI
import AppKit

// AppDelegate 只负责一件事：启动后开始监视菜单栏图标上的悬停
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { HoverSnapshot.shared.start(store: Store.shared) }
    }
}

// MARK: - App 入口（菜单栏）
@main
struct KeepAliveBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = Store.shared

    var body: some Scene {
        MenuBarExtra {
            ContentView().environmentObject(store)
        } label: {
            // 图标与倒计时合成成一张图交出去：MenuBarExtra 的 label 只渲染第一个 Image，
            // 分成两个 Image 时倒计时会被整段丢掉（见 MenuBarCountdown 的注释）。
            if let label = store.menuBarImage {
                Image(nsImage: label)
            } else {
                // 没有图标资源、又隐藏了倒计时：状态项宽度会变 0 就点不到了，兜个占位符
                Text("◷")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
