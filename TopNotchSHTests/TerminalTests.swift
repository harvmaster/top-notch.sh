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

    func testResetSequenceDisablesInputModes() {
        let sequence = String(decoding: TerminalModes.resetSequence(inAlternateScreen: false), as: UTF8.self)
        for mode in ["1000", "1002", "1003", "1004", "1006", "2004"] {
            XCTAssertTrue(sequence.contains("\u{1b}[?\(mode)l"), "missing reset for mode \(mode)")
        }
        XCTAssertTrue(sequence.contains(TerminalModes.popKeyboardModes))
    }

    /// Leaving the alternate screen restores a saved cursor, so it must only
    /// happen when the alternate screen is actually on.
    func testOnlyLeavesTheAlternateScreenWhenOnIt() {
        let main = String(decoding: TerminalModes.resetSequence(inAlternateScreen: false), as: UTF8.self)
        let alternate = String(decoding: TerminalModes.resetSequence(inAlternateScreen: true), as: UTF8.self)
        XCTAssertFalse(main.contains("\u{1b}[?1049l"))
        XCTAssertTrue(alternate.contains("\u{1b}[?1049l"))
    }

    /// Replays what a program like Claude Code inside tmux leaves behind,
    /// then checks the reset undoes all of it without moving the cursor.
    func testResetUndoesWhatAProgramLeftBehind() {
        let terminal = Terminal(delegate: HeadlessDelegate(), options: TerminalOptions(cols: 40, rows: 10))
        terminal.feed(text: "$ ssh host\r\n")
        terminal.feed(text: "\u{1b}[?1049h\u{1b}[>1u\u{1b}[?1003h\u{1b}[?2004h\u{1b}[?1h\u{1b}[3;8r")
        terminal.feed(text: "\u{1b}[?1049h\u{1b}[>1u\u{1b}[>1u")   // a nested program
        XCTAssertTrue(terminal.isCurrentBufferAlternate)
        XCTAssertFalse(terminal.keyboardEnhancementFlags.isEmpty)

        terminal.feed(byteArray: TerminalModes.resetSequence(inAlternateScreen: terminal.isCurrentBufferAlternate))
        terminal.softReset()

        XCTAssertFalse(terminal.isCurrentBufferAlternate)
        XCTAssertTrue(terminal.keyboardEnhancementFlags.isEmpty)
        XCTAssertEqual(terminal.mouseMode, .off)
        XCTAssertFalse(terminal.bracketedPasteMode)
        XCTAssertFalse(terminal.applicationCursor)
        XCTAssertEqual(terminal.buffer.scrollTop, 0)
        XCTAssertEqual(terminal.buffer.scrollBottom, 9)
        // Back where the program started, just below "$ ssh host".
        XCTAssertEqual(terminal.buffer.y, 1)
        XCTAssertEqual(terminal.buffer.x, 0)

        // A second reset on the main screen must not move the cursor.
        terminal.feed(text: "$ ")
        terminal.feed(byteArray: TerminalModes.resetSequence(inAlternateScreen: terminal.isCurrentBufferAlternate))
        terminal.softReset()
        XCTAssertEqual(terminal.buffer.y, 1)
        XCTAssertEqual(terminal.buffer.x, 2)
    }
}

private final class HeadlessDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
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

final class ShellEscapingTests: XCTestCase {
    func testEscapesLikeTerminalApp() {
        XCTAssertEqual(ShellEscaping.escape("/Users/me/My File (1).txt"), "/Users/me/My\\ File\\ \\(1\\).txt")
        XCTAssertEqual(ShellEscaping.escape("/tmp/it's"), "/tmp/it\\'s")
        XCTAssertEqual(ShellEscaping.escape("/usr/bin/env"), "/usr/bin/env")
    }
}

final class TextEditingKeysTests: XCTestCase {
    private func action(_ keyCode: Int, _ flags: NSEvent.ModifierFlags) -> Selector? {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(keyCode)
        )!
        return TextEditingKeys.action(for: event)
    }

    func testStandardEditingShortcuts() {
        XCTAssertEqual(action(kVK_ANSI_A, .command), #selector(NSText.selectAll(_:)))
        XCTAssertEqual(action(kVK_ANSI_V, .command), #selector(NSText.paste(_:)))
        XCTAssertEqual(action(kVK_ANSI_Z, [.command, .shift]), Selector(("redo:")))
        XCTAssertNil(action(kVK_ANSI_T, .command))
    }
}
