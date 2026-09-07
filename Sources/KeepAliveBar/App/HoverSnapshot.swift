import SwiftUI
import AppKit

// MARK: - 悬停快照的 AppKit 承载
// MenuBarExtra 不暴露它的 NSStatusItem，所以“图标上悬停”只能自己在 AppKit 侧实现：
//   · 定位状态项按钮：在 NSApp.windows 里找 NSStatusBarButton（状态栏窗口属于本 App）。
//   · 判定悬停：每 0.25s 比一次 NSEvent.mouseLocation 与按钮屏幕矩形。
//     刻意不用全局事件监听——鼠标移动的全局监听在后台 App 上并不可靠，而 mouseLocation
//     是廉价同步调用，0.1s 一次的轮询对 0.8 秒的停留判定绰绰有余。
//   · 展示：无边框、不激活、不吃鼠标事件的浮动面板，钉在图标正下方。
@MainActor
final class HoverSnapshot {
    static let shared = HoverSnapshot()

    private let dwell: TimeInterval = 0.8        // 悬停多久才弹
    private let pollInterval: TimeInterval = 0.1 // 判定粒度：必须远小于 dwell，否则 0.8s 会拖成 1s 才弹

    private var store: Store?
    private var timer: Timer?
    private var panel: NSPanel?
    private var host: NSView?            // 快照内容的 NSHostingView（只用到 fittingSize / 布局）
    private var statusButton: NSStatusBarButton?
    private var hoverSince: Date?
    private var loggedButton = false

    func start(store: Store) {
        guard timer == nil else { return }
        self.store = store
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        guard let store else { return }
        // 主弹窗开着时不抢戏；状态项还没建好（启动瞬间）也直接跳过，下一轮再找
        guard !store.popupOpen, let frame = buttonFrame() else { reset(); return }
        guard frame.insetBy(dx: -1, dy: -1).contains(NSEvent.mouseLocation) else { reset(); return }
        if hoverSince == nil { hoverSince = Date() }
        if Date().timeIntervalSince(hoverSince!) >= dwell { show(under: frame) }
    }

    private func reset() {
        hoverSince = nil
        if panel?.isVisible == true { panel?.orderOut(nil) }
    }

    // 状态项按钮的屏幕矩形。按钮宽度会随标题变化（隐藏倒计时后只剩图标），所以每次都重算。
    private func buttonFrame() -> NSRect? {
        if statusButton?.window == nil { statusButton = HoverSnapshot.findStatusButton() }
        guard let b = statusButton, let w = b.window, b.bounds.width > 0 else { return nil }
        let f = w.convertToScreen(b.convert(b.bounds, to: nil))
        // 启动后头几十毫秒状态项还没被系统摆到菜单栏（frame 在屏幕外，如 {0,-26}），
        // 等它落到某块屏幕上再记这一行——否则日志记的是个没用的临时值。
        if !loggedButton, NSScreen.screens.contains(where: { $0.frame.intersects(f) }) {
            loggedButton = true   // 每次启动记一行：定位依赖 MenuBarExtra 的私有视图层级，将来失效时一眼可见
            store?.log("HOVER: 已定位状态项按钮 frame=\(NSStringFromRect(f))")
        }
        return f
    }

    private static func findStatusButton() -> NSStatusBarButton? {
        for w in NSApp.windows {
            if let b = firstStatusBarButton(w.contentView) { return b }
        }
        return nil
    }

    private static func firstStatusBarButton(_ v: NSView?) -> NSStatusBarButton? {
        guard let v else { return nil }
        if let b = v as? NSStatusBarButton { return b }
        for sub in v.subviews {
            if let b = firstStatusBarButton(sub) { return b }
        }
        return nil
    }

    private func show(under frame: NSRect) {
        if panel == nil { makePanel() }
        guard let panel, let host else { return }
        // 内容高度会随数据变化（Opus/Sonnet 行可能后来才出现），所以每轮都按当前内容重算尺寸与位置
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        if panel.frame.size != size { panel.setContentSize(size) }
        var x = frame.midX - size.width / 2
        if let vf = (statusButton?.window?.screen ?? NSScreen.main)?.visibleFrame {
            x = min(max(x, vf.minX + 8), max(vf.minX + 8, vf.maxX - size.width - 8))
        }
        panel.setFrameOrigin(NSPoint(x: x, y: frame.minY - size.height - 6))
        if !panel.isVisible { panel.orderFrontRegardless() }   // 不激活本 App，不抢焦点
    }

    private func makePanel() {
        guard let store else { return }
        // controlActiveState 强制为 .active：面板刻意不抢焦点，SwiftUI 便会按“非活动窗口”渲染，
        // 进度条的 .tint 会被灰掉。指定活动态后，快照里的进度条颜色与点开弹窗时完全一致。
        let view = NSHostingView(rootView: SnapshotView()
            .environmentObject(store)
            .environment(\.controlActiveState, .active))
        view.translatesAutoresizingMaskIntoConstraints = false

        // 卡片背景用 NSVisualEffectView 的 .behindWindow 混合 —— 这是弹窗那种“透出桌面”的
        // 毛玻璃唯一的来源；SwiftUI 的 Material 在无背景的浮动窗口里只会糊成一块实色。
        let fx = NSVisualEffectView()
        fx.material = .menu                 // 与菜单栏弹窗同款的系统菜单材质
        fx.blendingMode = .behindWindow
        fx.state = .active                  // 本 App 不激活也保持模糊，不随焦点变灰
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 12
        fx.layer?.cornerCurve = .continuous
        fx.layer?.masksToBounds = true
        fx.layer?.borderWidth = 1
        fx.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        fx.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            view.topAnchor.constraint(equalTo: fx.topAnchor),
            view.bottomAnchor.constraint(equalTo: fx.bottomAnchor)
        ])

        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.contentView = fx
        p.isFloatingPanel = true
        p.level = .statusBar                 // 与菜单栏同级：盖住普通窗口，又不越过系统菜单
        p.isOpaque = false
        p.backgroundColor = .clear           // 窗口本身透明，圆角+毛玻璃由上面的 NSVisualEffectView 画
        p.hasShadow = true
        p.ignoresMouseEvents = true          // 纯展示：不吃点击，不影响再点图标
        p.hidesOnDeactivate = false
        p.animationBehavior = .utilityWindow
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel = p
        host = view
    }
}
