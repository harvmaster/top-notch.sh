import Foundation

/// A user intent, independent of how it was triggered (hotkey, menu, button).
enum Command: Equatable {
    case toggleNotch
    case closeNotch
    case showSettings
    case newTab
    case closeTab
    case nextTab
    case previousTab
    case selectTab(index: Int)
    case detachTab
    case nextWorkspace
    case previousWorkspace
    case selectWorkspace(WorkspaceID)
    case createWorkspace
    case deleteWorkspace(WorkspaceID)
    case applySizePreset(SizePreset)
    case resetTerminal
    case adjustFontSize(delta: Double)
    case resetFontSize

    init(_ action: HotkeyAction) {
        switch action {
        case .toggleNotch: self = .toggleNotch
        case .newTab: self = .newTab
        case .closeTab: self = .closeTab
        case .nextTab: self = .nextTab
        case .previousTab: self = .previousTab
        case .detachTab: self = .detachTab
        case .nextWorkspace: self = .nextWorkspace
        case .previousWorkspace: self = .previousWorkspace
        case .resetTerminal: self = .resetTerminal
        case .increaseFontSize: self = .adjustFontSize(delta: 1)
        case .decreaseFontSize: self = .adjustFontSize(delta: -1)
        case .resetFontSize: self = .resetFontSize
        }
    }
}
