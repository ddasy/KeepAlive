import AppKit

// MARK: - 菜单栏标签：图标 + 倒计时 + 底部用量条
// 三样东西合成同一张图，因为 MenuBarExtra 的 label 只会渲染第一个 Image
//（实测：图标 + 倒计时两个 Image 时，状态项宽度从 87 掉到 38.5，倒计时整段消失）。
// 倒计时用菜单栏标签色正常渲染（深色菜单栏＝白字，浅色＝黑字），用量画在文字正下方的一条细线上：
// 线宽＝文字宽度，最左 0%、最右 100%，绿/橙/红沿用弹窗用量条的同一套阈值（见 UsageSeverity）。
@MainActor
enum MenuBarCountdown {
    private static let gap: CGFloat = 4      // 图标与倒计时之间的间距，对齐原先 SwiftUI 的排布
    private static let inset: CGFloat = 1    // 文字左右各留 1pt，抗锯齿的边缘像素不会被裁掉
    private static let barHeight: CGFloat = 2    // 用量条：菜单栏就这么点高，2pt 已经够看且不喧宾夺主
    private static let barGap: CGFloat = 1.5     // 文字与用量条之间的留白
    // body 每 5 秒 tick 都会重算；键相同就复用同一个 NSImage，状态项不会因为换实例而重排宽度。
    private static var cache: (key: String, image: NSImage)?

    static func label(icon: NSImage?, iconKey: String, title: String, percent: Double?,
                      fillOpacity: Double = 1, trackOpacity: Double = 0.22) -> NSImage? {
        guard icon != nil || !title.isEmpty else { return nil }
        // 颜色必须在 drawingHandler 之外按菜单栏外观解析好：handler 是延迟执行的，
        // 里面的 NSColor.labelColor 会跟着“当时的绘制外观”走，浅色/深色切换时容易画反。
        // 常量先取成局部量：drawingHandler 是 nonisolated 闭包，直接读 @MainActor 的静态属性
        // 在 Swift 6 语言模式下会变成硬错误。
        let (gap, inset, barHeight, barGap) = (Self.gap, Self.inset, Self.barHeight, Self.barGap)
        let appearance = NSApp?.effectiveAppearance ?? .currentDrawing()
        let fillOpacity = Store.normalizedOpacity(fillOpacity, fallback: 1)
        let trackOpacity = Store.normalizedOpacity(trackOpacity, fallback: 0.22)
        let fraction = percent.map { min(1, max(0, $0 / 100)) }
        // 键里把比例量化到 0.25%：文字没变、用量只抖动零点几个百分点时复用同一个 NSImage。
        let key = "\(iconKey)|\(title)|\(fraction.map { Int(($0 * 400).rounded()) } ?? -1)|\(appearance.name.rawValue)|\(fillOpacity)|\(trackOpacity)"
        if let cached = cache, cached.key == key { return cached.image }

        let font = NSFont.menuBarFont(ofSize: 0)
        var baseColor = NSColor.labelColor
        var fillColor = UsageSeverity.of(percent).menuBarColor
        appearance.performAsCurrentDrawingAppearance {
            baseColor = NSColor.labelColor.usingColorSpace(.sRGB) ?? baseColor
            fillColor = fillColor.usingColorSpace(.sRGB) ?? fillColor
        }

        fillColor = fillColor.withAlphaComponent(fillOpacity)
        let base = title.isEmpty ? nil : NSAttributedString(
            string: title, attributes: [.font: font, .foregroundColor: baseColor])
        let trackColor = baseColor.withAlphaComponent(trackOpacity)
        let textSize = base?.size() ?? .zero
        let textWidth = base == nil ? 0 : ceil(textSize.width) + inset * 2
        let iconSize = icon?.size ?? .zero
        // 文字这一列的高度要把底部用量条算进去，否则没有图标兜底时（图标资源缺失）文字会顶出画布。
        let textColumnHeight = base == nil ? 0 : ceil(textSize.height) + barHeight + barGap
        let size = NSSize(width: iconSize.width + (icon != nil && base != nil ? gap : 0) + textWidth,
                          height: max(iconSize.height, textColumnHeight))

        let image = NSImage(size: size, flipped: false) { rect in
            if let icon {
                icon.draw(in: NSRect(x: 0, y: (rect.height - iconSize.height) / 2,
                                     width: iconSize.width, height: iconSize.height))
            }
            guard let base else { return true }
            let originX = iconSize.width + (icon != nil ? gap : 0) + inset
            // 文字整体上抬，给底部那条用量条腾出位置；抬完仍在剩余空间里居中，不会贴着上沿。
            let originY = barHeight + barGap + (rect.height - barHeight - barGap - textSize.height) / 2
            base.draw(at: NSPoint(x: originX, y: originY))
            guard let fraction else { return true }   // 没有用量数据就不画线，位置不变，文字不跳
            func bar(_ width: CGFloat, _ color: NSColor) {
                guard width > 0 else { return }
                color.setFill()
                NSBezierPath(roundedRect: NSRect(x: originX, y: 0, width: width, height: barHeight),
                             xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
            }
            bar(textSize.width, trackColor)                      // 底槽：0%…100% 的整段
            bar(textSize.width * fraction, fillColor)            // 已用：从左往右填到 fraction
            return true
        }
        image.isTemplate = false   // 自带颜色，别让系统按模板染成单色
        image.accessibilityDescription = percent.map { "\(title)，已用 \(Int($0.rounded()))%" }
            ?? (title.isEmpty ? "KeepAliveBar" : title)
        cache = (key, image)
        return image
    }
}

extension Store {
    // 菜单栏标签图（图标 + 倒计时）。图标资源缺失且隐藏了倒计时时返回 nil，调用方兜个占位符。
    var menuBarImage: NSImage? {
        let codex = displayedCodexFirst
        return MenuBarCountdown.label(icon: codex ? MenuBarArtwork.codex : MenuBarArtwork.clawd,
                                      iconKey: codex ? "codex" : "clawd",
                                      title: menuTitle, percent: menuUsagePercent,
                                      fillOpacity: menuBarFillOpacity, trackOpacity: menuBarTrackOpacity)
    }
}
