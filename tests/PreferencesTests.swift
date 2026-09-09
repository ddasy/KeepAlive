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
        check(first.visibleMenuControls.isEmpty, "feature controls default to settings only")
        check(first.menuBarFillOpacity == 1 && first.menuBarTrackOpacity == 0.22, "existing bar appearance is preserved by default")
        first.setMenuControl(.claude, visible: true)
        first.setMenuControl(.claude, visible: true)
        check(first.visibleMenuControls == ["claude"], "showing a control is idempotent")
        first.setMenuControl(.claude, visible: false)
        check(!first.claudeAutoEnabled, "hiding a control preserves disabled feature state")
        first.codexAutoEnabled = true
        first.setMenuControl(.codex, visible: false)
        check(first.codexAutoEnabled, "hiding a control preserves enabled feature state")
        first.setMenuControl(.cross, visible: true)
        first.menuBarFillOpacity = 0.65
        first.menuBarTrackOpacity = 0.13
        first.codexFirst = true
        first.automaticSorting = true
        first.hideCountdown = true
        first.autoQueryOnOpen = false
        first.paused = true
        first.windowEnd = base
        check(!other.codexFirst && !other.automaticSorting && !other.hideCountdown, "settings do not leak between stores with different suites")
        check(other.autoQueryOnOpen && !other.paused && other.windowEnd == nil, "window and lifecycle settings remain isolated")

        let restored = Store(preferences: defaults, monitoring: false)
        check(restored.showsMenuControl(.cross) && !restored.showsMenuControl(.claude), "per-control visibility persists")
        check(restored.menuBarFillOpacity == 0.65 && restored.menuBarTrackOpacity == 0.13, "both bar depths persist independently")
        check(other.visibleMenuControls.isEmpty && other.menuBarFillOpacity == 1, "new preferences remain isolated")
        check(restored.codexFirst && restored.automaticSorting && restored.hideCountdown, "all display preferences restore from the injected suite")
        check(!restored.autoQueryOnOpen && restored.paused && restored.windowEnd == base, "lifecycle preferences and window anchor restore")
        defaults.set(2.0, forKey: "menuBarFillOpacity")
        defaults.set(-1.0, forKey: "menuBarTrackOpacity")
        let bounded = Store(preferences: defaults, monitoring: false)
        check(bounded.menuBarFillOpacity == 1 && bounded.menuBarTrackOpacity == 0, "out-of-range stored opacity is clamped")
        check(Store.normalizedOpacity(.nan, fallback: 0.22) == 0.22, "nonfinite opacity falls back safely")
        first.windowEnd = nil
        check(Store(preferences: defaults, monitoring: false).windowEnd == nil, "removing an anchor uses the injected suite")
        check(defaults.object(forKey: "didWarmup") == nil, "test initialization never triggers credential warmup")
        check(first.refreshRetryTask == nil && first.lastRefresh == nil, "test initialization never schedules refresh work")
    }
}
