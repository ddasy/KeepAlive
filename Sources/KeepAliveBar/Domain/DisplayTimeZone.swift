import Foundation

// system 是持久化的跟随模式；固定偏移以分钟保存，不受夏令时影响。
enum DisplayTimeZone {
    static let system = "system"
    static let offsets = (Array(stride(from: -720, through: 840, by: 60))
        + [-570, -210, 210, 270, 330, 345, 390, 525, 570, 630, 765]).sorted()

    static func normalized(_ selection: String?) -> String {
        guard let selection, let minutes = Int(selection), offsets.contains(minutes) else { return system }
        return String(minutes)
    }

    static func resolve(_ selection: String, systemTimeZone: TimeZone = .autoupdatingCurrent) -> TimeZone {
        guard let minutes = Int(normalized(selection)) else { return systemTimeZone }
        return TimeZone(secondsFromGMT: minutes * 60)!
    }

    static func label(_ selection: String) -> String {
        guard let minutes = Int(normalized(selection)) else { return "跟随系统" }
        if minutes == 0 { return "UTC+0" }
        let remainder = abs(minutes) % 60
        return "UTC" + (minutes < 0 ? "−" : "+") + String(abs(minutes) / 60)
            + (remainder == 0 ? "" : String(format: ":%02d", remainder))
    }
}
