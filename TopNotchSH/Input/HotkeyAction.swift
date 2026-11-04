import Carbon.HIToolbox

/// Every rebindable shortcut in the app.
///
/// Bindings are stored as `[HotkeyAction: KeyChord]`, so adding a case here
/// automatically gives it a default, a settings row and persistence.
enum HotkeyAction: String, CaseIterable, Codable, CodingKeyRepresentable, Identifiable {
    case toggleNotch
    case newTab
    case closeTab
    case reopenClosedTab
    case nextTab
    case previousTab
    case detachTab
    case nextWorkspace
    case previousWorkspace
    case togglePin
    case find
    case findNext
    case findPrevious
    case resetTerminal
    case increaseFontSize
    case decreaseFontSize
    case resetFontSize

    enum Scope: String, CaseIterable {
        /// Registered system-wide; fires from any app.
        case global
        /// Fires while an open notch has keyboard focus.
        case notch
        /// Fires while any terminal (notch or pop-out) has keyboard focus.
        case terminal
    }

    var id: String { rawValue }

    var scope: Scope {
        switch self {
        case .toggleNotch:
            .global
        case .newTab, .closeTab, .reopenClosedTab, .nextTab, .previousTab, .detachTab,
             .nextWorkspace, .previousWorkspace, .togglePin:
            .notch
        case .find, .findNext, .findPrevious, .resetTerminal, .increaseFontSize, .decreaseFontSize, .resetFontSize:
            .terminal
        }
    }

    var title: String {
        switch self {
        case .toggleNotch: "Toggle notch"
        case .newTab: "New tab"
        case .closeTab: "Close tab"
        case .reopenClosedTab: "Reopen closed tab"
        case .nextTab: "Next tab"
        case .previousTab: "Previous tab"
        case .detachTab: "Detach tab to window"
        case .nextWorkspace: "Next workspace"
        case .previousWorkspace: "Previous workspace"
        case .togglePin: "Pin notch open"
        case .find: "Find"
        case .findNext: "Find next"
        case .findPrevious: "Find previous"
        case .resetTerminal: "Reset terminal input modes"
        case .increaseFontSize: "Increase font size"
        case .decreaseFontSize: "Decrease font size"
        case .resetFontSize: "Reset font size"
        }
    }

    var defaultChord: KeyChord {
        switch self {
        case .toggleNotch: .command(kVK_Return)
        case .newTab: .command(kVK_ANSI_T)
        case .closeTab: .command(kVK_ANSI_W)
        case .reopenClosedTab: .commandShift(kVK_ANSI_T)
        case .nextTab: .commandShift(kVK_ANSI_RightBracket)
        case .previousTab: .commandShift(kVK_ANSI_LeftBracket)
        case .detachTab: .command(kVK_ANSI_D)
        case .nextWorkspace: .commandShift(kVK_DownArrow)
        case .previousWorkspace: .commandShift(kVK_UpArrow)
        case .togglePin: .commandShift(kVK_ANSI_P)
        case .find: .command(kVK_ANSI_F)
        case .findNext: .command(kVK_ANSI_G)
        case .findPrevious: .commandShift(kVK_ANSI_G)
        case .resetTerminal: .command(kVK_ANSI_R)
        case .increaseFontSize: .command(kVK_ANSI_Equal)
        case .decreaseFontSize: .command(kVK_ANSI_Minus)
        case .resetFontSize: .command(kVK_ANSI_0)
        }
    }

    static var defaultBindings: [HotkeyAction: KeyChord] {
        Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.defaultChord) })
    }
}
