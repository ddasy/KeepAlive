import Foundation

extension TestSuite {
    func testTimeZone() {
        let s = Store(preferences: defaults, monitoring: false)
        check(s.timeZoneSelection == "system", "clean install follows the system time zone")
        check(s.displayTimeZone == .autoupdatingCurrent, "system mode uses a live time zone")
        for name in ["Asia/Tokyo", "America/Los_Angeles"] {
            let zone = TimeZone(identifier: name)!
            check(DisplayTimeZone.resolve("system", systemTimeZone: zone) == zone, "system selection follows \(name)")
            check(DisplayTimeZone.resolve("480", systemTimeZone: zone).secondsFromGMT() == 28800,
                  "fixed UTC+8 ignores system zone \(name)")
        }
        let date = ISO8601DateFormatter().date(from: "2026-11-13T16:00:00Z")!
        s.now = date.addingTimeInterval(-3600)
        s.windowEnd = date
        s.paused = false
        s.timeZoneSelection = "480"
        check(s.localHM(date) == "00:00" && s.localMDHM(date) == "11-14 00:00", "UTC+8 crosses date boundary")
        check(s.localHM(date.addingTimeInterval(-1)) == "23:59", "clock rolls over at local midnight")
        check(s.resetInfo(date, s.now) == "重置 00:00（剩余时间 1h 0m）", "reset display uses selected zone and unchanged duration")
        check(s.weeklyResetInfo(date, s.now) == "重置11月14日 00:00（剩余1h 0m）", "weekly reset includes selected-zone date")
        check(s.formattedTime(date, format: "yyyy-MM-dd HH:mm") == "2026-11-14 00:00", "login deadline uses selected-zone full date")
        let countdown = s.menuTitle
        s.lastFireResult = "Claude 保活成功"
        s.lastFireResultReset = date
        s.codexLastFireResult = "Codex 激活成功"
        s.codexLastFireResultReset = date
        check(s.fireResultText(codex: false).contains("11-14 00:00:00"), "success record uses UTC+8")
        s.timeZoneSelection = "-720"
        check(s.localHM(date) == "04:00" && s.localMDHM(date) == "11-13 04:00", "negative UTC offset uses previous date")
        check(s.fireResultText(codex: false).contains("11-13 04:00:00")
            && s.fireResultText(codex: true).contains("11-13 04:00:00"), "existing success records immediately follow new zone")
        check(s.menuTitle == countdown && s.windowEnd == date, "time zone changes preserve countdown and scheduling anchor")
        s.timeZoneSelection = "345"
        check(s.localHM(date) == "21:45", "quarter-hour offset is supported")
        check(DisplayTimeZone.label("345") == "UTC+5:45" && DisplayTimeZone.label("-210") == "UTC−3:30", "fractional offsets have unambiguous labels")
        s.timeZoneSelection = "840"
        check(s.localMDHM(date) == "11-14 06:00", "maximum UTC+14 offset is supported")
        s.timeZoneSelection = "480"
        check(Store(preferences: defaults, monitoring: false).timeZoneSelection == "480", "selected offset persists across restart")
        s.timeZoneSelection = "system"
        check(Store(preferences: defaults, monitoring: false).timeZoneSelection == "system", "returning to system mode persists")
        for invalid in ["bad", "900", "1"] {
            defaults.set(invalid, forKey: "displayTimeZone")
            check(Store(preferences: defaults, monitoring: false).timeZoneSelection == "system", "invalid stored time zone falls back to system")
        }
        s.lastFireResult = "失败"
        s.codexLastFireResult = "失败"
        check(s.lastFireResultReset == nil && s.codexLastFireResultReset == nil, "new results clear previous success deadlines")
        check(s.fireResultText(codex: false) == "失败", "errors do not inherit a stale reset timestamp")
    }
}
