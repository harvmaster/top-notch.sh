import AppKit
import Carbon.HIToolbox
import SwiftTerm
import XCTest
@testable import TopNotchSH

final class TerminalKeyMapTests: XCTestCase {
    private func action(_ keyCode: Int, _ modifiers: NSEvent.ModifierFlags = .command, appCursor: Bool = false) -> TerminalKeyAction? {
        TerminalKeyMap.action(modifiers: modifiers, keyCode: UInt16(keyCode), applicationCursor: appCursor)
    }

    func testCommandArrowsJumpToLineEnds() {
        XCTAssertEqual(action(kVK_LeftArrow), .send(EscapeSequences.moveHomeNormal))
        XCTAssertEqual(action(kVK_RightArrow), .send(EscapeSequences.moveEndNormal))
        XCTAssertEqual(action(kVK_LeftArrow, appCursor: true), .send(EscapeSequences.moveHomeApp))
        XCTAssertEqual(action(kVK_RightArrow, appCursor: true), .send(EscapeSequences.moveEndApp))
    }

    func testEditingShortcuts() {
        XCTAssertEqual(action(kVK_Delete), .send([0x15]))
        XCTAssertEqual(action(kVK_ANSI_L), .send([0x0C]))
        XCTAssertEqual(action(kVK_ANSI_C), .copy)
        XCTAssertEqual(action(kVK_ANSI_V), .paste)
        XCTAssertEqual(action(kVK_ANSI_A), .selectAll)
    }

    func testOptionArrowsMoveByWord() {
        XCTAssertEqual(action(kVK_LeftArrow, .option), .send(EscapeSequences.emacsBack))
        XCTAssertEqual(action(kVK_RightArrow, .option), .send(EscapeSequences.emacsForward))
        XCTAssertNil(TerminalKeyMap.action(modifiers: .option, keyCode: UInt16(kVK_LeftArrow), applicationCursor: false, optionAsMeta: false))
    }

    func testOtherModifierCombinationsPassThrough() {
        XCTAssertNil(action(kVK_LeftArrow, [.command, .shift]))
        XCTAssertNil(action(kVK_LeftArrow, [.option, .shift]))
        XCTAssertNil(action(kVK_ANSI_R))
    }

    func testResetSequenceDisablesMouseReporting() {
        let sequence = String(decoding: TerminalModes.resetSequence, as: UTF8.self)
        for mode in ["1000", "1002", "1003", "1006", "2004", "1049"] {
            XCTAssertTrue(sequence.contains("\u{1b}[?\(mode)l"), "missing reset for mode \(mode)")
        }
    }
}

final class ScrollFollowTests: XCTestCase {
    func testFollowsOutputAtBottom() {
        var follow = ScrollFollow()
        follow.didScroll(to: 1, canScroll: true)
        XCTAssertNil(follow.restorePosition(canScroll: true))
    }

    func testHoldsPositionWhileReadingScrollback() {
        var follow = ScrollFollow()
        follow.didScroll(to: 0.4, canScroll: true)
        XCTAssertEqual(follow.restorePosition(canScroll: true), 0.4)
        XCTAssertNil(follow.restorePosition(canScroll: false))
    }

    func testTypingSnapsBack() {
        var follow = ScrollFollow()
        follow.didScroll(to: 0.2, canScroll: true)
        XCTAssertTrue(follow.userDidType())
        XCTAssertFalse(follow.userDidType())
        XCTAssertNil(follow.restorePosition(canScroll: true))
    }
}

final class MouseWheelTests: XCTestCase {
    func testTicks() {
        XCTAssertEqual(MouseWheel.ticks(for: 0.5), 1)
        XCTAssertEqual(MouseWheel.ticks(for: -3), 3)
        XCTAssertEqual(MouseWheel.ticks(for: 7), 10)
        XCTAssertEqual(MouseWheel.ticks(for: 12), 20)
    }

    func testCellUsesTopLeftOrigin() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 400)
        let topLeft = MouseWheel.cell(at: CGPoint(x: 1, y: 399), in: bounds, cols: 80, rows: 20)
        XCTAssertEqual(topLeft.column, 0)
        XCTAssertEqual(topLeft.row, 0)

        let bottomRight = MouseWheel.cell(at: CGPoint(x: 900, y: -10), in: bounds, cols: 80, rows: 20)
        XCTAssertEqual(bottomRight.column, 79)
        XCTAssertEqual(bottomRight.row, 19)
    }
}
