import AppKit

// 图标、双行文字和用量条合成一张图片，保持现有 MenuBarExtra 标签渲染方式。
// 上行使用所选时区，下行保留倒计时/暂停/告警；用量条移到图标下方。
@MainActor
enum MenuBarCountdown {
    // 每 5 秒 tick 会重算；分钟、状态、用量和外观未改变时复用图片。
    private static var cache: (key: String, image: NSImage)?

    static func label(icon: NSImage?, iconKey: String, title: String, clock: String, timeZoneLabel: String = "", percent: Double?,
                      fillOpacity: Double = 1, trackOpacity: Double = 0.22) -> NSImage? {
        let height: CGFloat = 22
        let gap: CGFloat = 4
        let inset: CGFloat = 1
        let barHeight: CGFloat = 2
        let barGap: CGFloat = 1.5
        let appearance = NSApp?.effectiveAppearance ?? .currentDrawing()
        let fillOpacity = Store.normalizedOpacity(fillOpacity, fallback: 1)
        let trackOpacity = Store.normalizedOpacity(trackOpacity, fallback: 0.22)
        let fraction = percent.map { min(1, max(0, $0 / 100)) }
        let key = "\(iconKey)|\(title)|\(clock)|\(timeZoneLabel)|\(fraction.map { Int(($0 * 400).rounded()) } ?? -1)|\(appearance.name.rawValue)|\(fillOpacity)|\(trackOpacity)"
        if let cached = cache, cached.key == key { return cached.image }

        // 在延迟绘制闭包之外解析外观颜色，避免深浅色切换后文字颜色错误。
        var baseColor = NSColor.labelColor
        var fillColor = UsageSeverity.of(percent).menuBarColor
        appearance.performAsCurrentDrawingAppearance {
            baseColor = NSColor.labelColor.usingColorSpace(.sRGB) ?? baseColor
            fillColor = fillColor.usingColorSpace(.sRGB) ?? fillColor
        }
        fillColor = fillColor.withAlphaComponent(fillOpacity)
        let trackColor = baseColor.withAlphaComponent(trackOpacity)
        // 两行统一用 10pt 半粗体，增加小字号的清晰度；等宽数字避免时间变化时抖动。
        let clockFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        let statusFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        let upper = NSAttributedString(string: clock,
            attributes: [.font: clockFont, .foregroundColor: baseColor])
        let lower = NSAttributedString(string: title,
            attributes: [.font: statusFont, .foregroundColor: baseColor])
        let reference = NSAttributedString(string: "00:00", attributes: [.font: clockFont]).size()
        let upperSize = upper.size()
        let lowerSize = lower.size()
        let columnWidth = ceil(max(reference.width, upperSize.width, lowerSize.width))

        // 即使没有用量数据也保留图标下方空间，数据恢复时位置不跳动。
        var iconSize = icon?.size ?? .zero
        let iconMaxHeight = height - barHeight - barGap
        if iconSize.height > iconMaxHeight {
            iconSize = NSSize(width: iconSize.width * iconMaxHeight / iconSize.height, height: iconMaxHeight)
        }
        let textX = iconSize.width + (icon == nil ? 0 : gap) + inset
        let size = NSSize(width: textX + columnWidth + inset, height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            func bar(_ x: CGFloat, _ width: CGFloat, _ color: NSColor) {
                guard width > 0 else { return }
                color.setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: 0, width: width, height: barHeight),
                             xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
            }
            if let icon {
                icon.draw(in: NSRect(x: 0,
                    y: barHeight + barGap + (iconMaxHeight - iconSize.height) / 2,
                    width: iconSize.width, height: iconSize.height))
                if let fraction {
                    bar(0, iconSize.width, trackColor)
                    bar(0, iconSize.width * fraction, fillColor)
                }
            }
            // 隐藏倒计时时时钟垂直居中；暂停和告警仍按原逻辑占据下行。
            let upperCenter = title.isEmpty ? rect.height / 2 : rect.height * 0.75
            upper.draw(at: NSPoint(x: textX + (columnWidth - upperSize.width) / 2,
                                   y: upperCenter - upperSize.height / 2))
            if !title.isEmpty {
                lower.draw(at: NSPoint(x: textX + (columnWidth - lowerSize.width) / 2,
                                       y: rect.height * 0.25 - lowerSize.height / 2))
            }
            // 图标资源缺失时，在文字列左侧保留一条窄用量指示，避免信息丢失。
            if icon == nil, let fraction {
                trackColor.setFill()
                NSRect(x: 0, y: 0, width: 1, height: rect.height).fill()
                fillColor.setFill()
                NSRect(x: 0, y: 0, width: 1, height: rect.height * fraction).fill()
            }
            return true
        }
        image.isTemplate = false
        let description = "\(timeZoneLabel) \(clock)" + (title.isEmpty ? "" : "，\(title)")
        image.accessibilityDescription = percent.map { description + "，已用 \(Int($0.rounded()))%" } ?? description
        cache = (key, image)
        return image
    }
}

extension Store {
    // 时钟始终显示；倒计时隐藏或暂停不影响时钟。
    var menuBarImage: NSImage? {
        let codex = displayedCodexFirst
        return MenuBarCountdown.label(icon: codex ? MenuBarArtwork.codex : MenuBarArtwork.clawd,
                                      iconKey: codex ? "codex" : "clawd",
                                      title: menuTitle, clock: localHM(now),
                                      timeZoneLabel: DisplayTimeZone.label(timeZoneSelection), percent: menuUsagePercent,
                                      fillOpacity: menuBarFillOpacity, trackOpacity: menuBarTrackOpacity)
    }
}
