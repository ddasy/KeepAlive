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

    // Clawd 像素蟹图标（保留彩色，不做模板染色）
    static let clawd: NSImage? = {
        guard let url = Bundle.main.url(forResource: "clawd", withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        let h: CGFloat = 13
        let ar = img.size.height > 0 ? img.size.width / img.size.height : 1.6
        img.size = NSSize(width: h * ar, height: h)  // 保持宽高比，不压扁
        img.isTemplate = false
        return img
    }()

    var body: some Scene {
        MenuBarExtra {
            ContentView().environmentObject(store)
        } label: {
            if let img = store.displayedCodexFirst ? MenuBarArtwork.codex : KeepAliveBarApp.clawd {
                Image(nsImage: img)
                // menuTitle 为空 = 隐藏倒计时：整段 Text 都不放，避免留下一块空白间距
                if !store.menuTitle.isEmpty { Text(store.menuTitle) }
            } else {
                // 没有图标资源时兜底：标题不能为空，否则状态项宽度为 0 就点不到了
                Text(store.menuTitle.isEmpty ? "◷" : store.menuTitle)
            }
        }
        .menuBarExtraStyle(.window)
    }
}
