import AppKit

// 原生矢量绘制：参考图的紫蓝渐变云朵 + 白色终端提示符。
// drawingHandler 按屏幕倍率渲染，在 Retina 菜单栏上也保持清晰。
enum MenuBarArtwork {
    // Clawd 像素蟹（保留彩色，不做模板染色）。放在这里而不是 App 入口，是因为菜单栏标签
    // 现在由 MenuBarCountdown 合成，而入口文件不参与库编译（测试只编译库源文件）。
    static let clawd: NSImage? = {
        guard let url = Bundle.main.url(forResource: "clawd", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        let height: CGFloat = 13
        let ratio = image.size.height > 0 ? image.size.width / image.size.height : 1.6
        image.size = NSSize(width: height * ratio, height: height)   // 保持宽高比，不压扁
        image.isTemplate = false
        return image
    }()

    static let codex: NSImage = {
        if let url = Bundle.main.url(forResource: "codex", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 19.8, height: 19.8)
            image.isTemplate = false
            return image
        }
        return drawnCodex
    }()

    private static let drawnCodex = NSImage(size: NSSize(width: 19.8, height: 19.8), flipped: true) { rect in
        guard let context = NSGraphicsContext.current?.cgContext else { return false }
        context.saveGState()
        defer { context.restoreGState() }
        context.scaleBy(x: rect.width / 100, y: rect.height / 100)

        let cloud = NSBezierPath()
        cloud.move(to: NSPoint(x: 22, y: 23))
        cloud.curve(to: NSPoint(x: 61, y: 13), controlPoint1: NSPoint(x: 27, y: 4), controlPoint2: NSPoint(x: 49, y: 0))
        cloud.curve(to: NSPoint(x: 89, y: 42), controlPoint1: NSPoint(x: 81, y: 7), controlPoint2: NSPoint(x: 95, y: 25))
        cloud.curve(to: NSPoint(x: 79, y: 81), controlPoint1: NSPoint(x: 102, y: 56), controlPoint2: NSPoint(x: 96, y: 77))
        cloud.curve(to: NSPoint(x: 40, y: 92), controlPoint1: NSPoint(x: 73, y: 100), controlPoint2: NSPoint(x: 53, y: 103))
        cloud.curve(to: NSPoint(x: 12, y: 64), controlPoint1: NSPoint(x: 18, y: 98), controlPoint2: NSPoint(x: 7, y: 81))
        cloud.curve(to: NSPoint(x: 22, y: 23), controlPoint1: NSPoint(x: -1, y: 49), controlPoint2: NSPoint(x: 7, y: 27))
        cloud.close()
        NSGradient(starting: NSColor(calibratedRed: 0.70, green: 0.62, blue: 1, alpha: 1),
                   ending: NSColor(calibratedRed: 0.26, green: 0.23, blue: 1, alpha: 1))?
            .draw(in: cloud, angle: 90)

        NSColor.white.setStroke()
        let terminal = NSBezierPath()
        terminal.lineWidth = 6.5
        terminal.lineCapStyle = .round
        terminal.lineJoinStyle = .round
        terminal.move(to: NSPoint(x: 29, y: 39))
        terminal.line(to: NSPoint(x: 37, y: 52))
        terminal.line(to: NSPoint(x: 29, y: 65))
        terminal.move(to: NSPoint(x: 53, y: 65))
        terminal.line(to: NSPoint(x: 71, y: 65))
        terminal.stroke()
        return true
    }
}
