import Foundation

// Each invocation owns a unique preferences domain; never touch the installed app's settings.
@MainActor
final class TestSuite {
    let suiteName = "com.iu.keepalivebar.tests.\(UUID().uuidString)"
    lazy var defaults = UserDefaults(suiteName: suiteName)!
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    var checks = 0

    func check(_ condition: Bool, _ label: String) {
        precondition(condition, label)
        checks += 1
    }

    func reset() { defaults.removePersistentDomain(forName: suiteName) }

    func run() {
        defer { reset() }
        testPreferences()
        reset()
        testCrossKeepalivePolicy()
        testPresentation()
        reset()
        testStoreScheduling()
        print("PASS: \(checks) checks (production sources; isolated settings; no network or inference requests)")
    }
}

@main
struct TestMain {
    @MainActor static func main() { TestSuite().run() }
}
