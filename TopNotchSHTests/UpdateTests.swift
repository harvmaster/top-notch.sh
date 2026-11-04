import XCTest
@testable import TopNotchSH

final class IdleCheckTests: XCTestCase {
    private let now = Date()
    private let check = IdleCheck(quietPeriod: 120)

    private func terminal(running: Bool = false, typedSecondsAgo: TimeInterval = 600) -> IdleCheck.Terminal {
        IdleCheck.Terminal(isRunningCommand: running, lastInputAt: now.addingTimeInterval(-typedSecondsAgo))
    }

    func testIdleWhenEveryTerminalIsAtItsPrompt() {
        XCTAssertTrue(check.isIdle(terminals: [terminal(), terminal()], isInUse: false, now: now))
        XCTAssertTrue(check.isIdle(terminals: [], isInUse: false, now: now), "no terminals at all is idle")
    }

    func testARunningCommandAnywhereBlocks() {
        XCTAssertFalse(check.isIdle(terminals: [terminal(), terminal(running: true)], isInUse: false, now: now))
    }

    func testRecentTypingBlocks() {
        XCTAssertFalse(check.isIdle(terminals: [terminal(typedSecondsAgo: 30)], isInUse: false, now: now))
        XCTAssertTrue(check.isIdle(terminals: [terminal(typedSecondsAgo: 121)], isInUse: false, now: now))
    }

    func testAnOpenNotchOrFocusedWindowBlocks() {
        XCTAssertFalse(check.isIdle(terminals: [terminal()], isInUse: true, now: now))
    }
}

final class UpdatePolicyTests: XCTestCase {
    func testPolicyMapsOntoSparkle() {
        XCTAssertTrue(UpdatePolicy.ask.checksAutomatically)
        XCTAssertFalse(UpdatePolicy.ask.downloadsAutomatically)
        XCTAssertTrue(UpdatePolicy.automatic.downloadsAutomatically)
        XCTAssertTrue(UpdatePolicy.whenIdle.downloadsAutomatically)
        XCTAssertFalse(UpdatePolicy.manual.checksAutomatically)
        XCTAssertFalse(UpdatePolicy.manual.downloadsAutomatically)
    }

    func testDefaultsToAsking() {
        XCTAssertEqual(AppSettings().updates.policy, .ask)
    }
}
