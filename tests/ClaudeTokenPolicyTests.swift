import Foundation

extension TestSuite {
    func testClaudeTokenPolicy() {
        func act(_ remaining: TimeInterval?, cli: Bool, rt: Bool = true) -> ClaudeTokenAction {
            ClaudeTokenPolicy.action(expiresAt: remaining.map { base.addingTimeInterval($0) }, now: base,
                                     cliRunning: cli, hasRefreshToken: rt)
        }
        check(act(nil, cli: false) == .use, "unknown expiry uses token")
        check(act(3600, cli: false) == .use, "fresh token used without CLI")
        check(act(300, cli: false) == .use, "self-refresh lead boundary still uses token")
        check(act(299, cli: false) == .refreshSelf, "no CLI refreshes ahead of expiry")
        check(act(-600, cli: false) == .refreshSelf, "no CLI refreshes expired token")
        check(act(299, cli: true) == .use, "CLI present keeps using near-expiry token")
        check(act(31, cli: true) == .use, "CLI present uses token beyond usable margin")
        check(act(30, cli: true) == .waitForCLI, "CLI present waits at usable margin")
        check(act(-600, cli: true) == .waitForCLI, "CLI present never refreshes expired token")
        check(act(-600, cli: true, rt: false) == .loginRequired, "cleared refresh token requires login with CLI")
        check(act(-600, cli: false, rt: false) == .loginRequired, "cleared refresh token requires login without CLI")
        check(act(120, cli: false, rt: false) == .use, "missing refresh token still uses valid access token")
        check(ClaudeTokenPolicy.usable(expiresAt: nil, now: base), "unknown expiry is usable")
        check(!ClaudeTokenPolicy.usable(expiresAt: base, now: base), "expired token is unusable")
    }
}
