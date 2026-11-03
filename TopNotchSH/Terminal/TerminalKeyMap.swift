import AppKit
import Carbon.HIToolbox
import SwiftTerm

/// What a ⌘-key shortcut means inside a terminal.
enum TerminalKeyAction: Equatable {
    case send([UInt8])
    case copy
    case paste
    case selectAll
}

/// macOS-style editing shortcuts translated into terminal input.
///
/// ⌘← / ⌘→ jump to line start/end, ⌘⌫ kills the line, ⌘L clears the screen,
/// and ⌘C / ⌘V / ⌘A work even without an Edit menu (the app is menu-bar only).
/// With "Option as Meta", ⌥← / ⌥→ send the emacs word-motion keys that shells
/// bind by default (SwiftTerm would otherwise send xterm-style `ESC[1;3D`).
enum TerminalKeyMap {
    static let killLine: [UInt8] = [0x15]
    static let clearScreen: [UInt8] = [0x0C]

    static func action(
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16,
        applicationCursor: Bool,
        optionAsMeta: Bool = true
    ) -> TerminalKeyAction? {
        switch modifiers.intersection(KeyChord.relevantModifiers) {
        case .command:
            return commandAction(keyCode: keyCode, applicationCursor: applicationCursor)
        case .option where optionAsMeta:
            switch Int(keyCode) {
            case kVK_LeftArrow: return .send(EscapeSequences.emacsBack)
            case kVK_RightArrow: return .send(EscapeSequences.emacsForward)
            default: return nil
            }
        default:
            return nil
        }
    }

    private static func commandAction(keyCode: UInt16, applicationCursor: Bool) -> TerminalKeyAction? {
        switch Int(keyCode) {
        case kVK_LeftArrow:
            return .send(applicationCursor ? EscapeSequences.moveHomeApp : EscapeSequences.moveHomeNormal)
        case kVK_RightArrow:
            return .send(applicationCursor ? EscapeSequences.moveEndApp : EscapeSequences.moveEndNormal)
        case kVK_Delete:
            return .send(killLine)
        case kVK_ANSI_L:
            return .send(clearScreen)
        case kVK_ANSI_C:
            return .copy
        case kVK_ANSI_V:
            return .paste
        case kVK_ANSI_A:
            return .selectAll
        default:
            return nil
        }
    }
}
