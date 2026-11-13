import AppKit
import Combine

extension Store {
    nonisolated static func nextClockMinute(after date: Date) -> Date {
        let minute = (date.timeIntervalSince1970 / 60).rounded(.down)
        return Date(timeIntervalSince1970: (minute + 1) * 60)
    }

    func startMenuClock() {
        guard monitoringEnabled else { return }
        clockSubscriptions.removeAll()
        NotificationCenter.default.publisher(for: .NSSystemClockDidChange)
            .merge(with: NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange),
                   NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshMenuClock() }
            }
            .store(in: &clockSubscriptions)
        refreshMenuClock()
    }

    // 每次重新计算下一整分钟，避免启动相位、唤醒或系统校时造成持续偏移。
    // 仅更新显示，不调用 tick、不联网；暂停保活时也照常走时。
    func refreshMenuClock(at date: Date = Date()) {
        clockNow = date
        clockTimer?.invalidate()
        clockTimer = nil
        guard monitoringEnabled else { return }
        let timer = Timer(fire: Self.nextClockMinute(after: date), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMenuClock() }
        }
        clockTimer = timer
        // 菜单跟踪期间也可执行，不因用户展开菜单而停住。
        RunLoop.main.add(timer, forMode: .common)
    }
}
