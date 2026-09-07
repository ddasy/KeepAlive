import Foundation

extension TestSuite {
    func testPreferences() {
        let otherName = "com.iu.keepalivebar.tests.\(UUID().uuidString)"
        let otherDefaults = UserDefaults(suiteName: otherName)!
        defer { otherDefaults.removePersistentDomain(forName: otherName) }

        defaults.set(false, forKey: "autoEnabled")
        let first = Store(preferences: defaults, monitoring: false)
        let other = Store(preferences: otherDefaults, monitoring: false)
        check(!first.claudeAutoEnabled && !first.codexAutoEnabled, "legacy autoEnabled migrates through injected preferences")
        check(other.claudeAutoEnabled && other.codexAutoEnabled, "independent suite preserves clean-install defaults")
        first.codexFirst = true
        first.automaticSorting = true
        first.hideCountdown = true
        first.autoQueryOnOpen = false
        first.paused = true
        first.windowEnd = base
        check(!other.codexFirst && !other.automaticSorting && !other.hideCountdown, "settings do not leak between stores with different suites")
        check(other.autoQueryOnOpen && !other.paused && other.windowEnd == nil, "window and lifecycle settings remain isolated")

        let restored = Store(preferences: defaults, monitoring: false)
        check(restored.codexFirst && restored.automaticSorting && restored.hideCountdown, "all display preferences restore from the injected suite")
        check(!restored.autoQueryOnOpen && restored.paused && restored.windowEnd == base, "lifecycle preferences and window anchor restore")
        first.windowEnd = nil
        check(Store(preferences: defaults, monitoring: false).windowEnd == nil, "removing an anchor uses the injected suite")
        check(defaults.object(forKey: "didWarmup") == nil, "test initialization never triggers credential warmup")
        check(first.refreshRetryTask == nil && first.lastRefresh == nil, "test initialization never schedules refresh work")
    }
}
