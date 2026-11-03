import Carbon.HIToolbox
import Foundation

/// The complete user configuration. `AppSettings()` is the default configuration.
///
/// Persisted as a single JSON document; see `SettingsStore` for how missing keys
/// fall back to these defaults so new fields never break existing installs.
struct AppSettings: Codable, Equatable {
    var general = GeneralSettings()
    var sizing = SizingSettings()
    var padding = PaddingSettings()
    var appearance = AppearanceSettings()
    var motion = MotionSettings()
    var terminal = TerminalSettings()
    var hotkeys = HotkeyAction.defaultBindings
    var sizePresets = SizePreset.defaults

    func chord(for action: HotkeyAction) -> KeyChord {
        hotkeys[action] ?? action.defaultChord
    }
}

struct GeneralSettings: Codable, Equatable {
    var showOnAllDisplays = true
    var showMenuBarIcon = true
    var closeOnFocusLoss = true
}

// MARK: - Sizing

enum ClosedHeightMode: String, Codable, CaseIterable, Identifiable {
    case matchNotch
    case matchMenuBar
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .matchNotch: "Match notch"
        case .matchMenuBar: "Match menu bar"
        case .custom: "Custom"
        }
    }
}

struct SizingSettings: Codable, Equatable {
    var notchedHeightMode = ClosedHeightMode.matchNotch
    var notchedCustomHeight = 32.0
    var externalHeightMode = ClosedHeightMode.matchMenuBar
    var externalCustomHeight = 32.0
    var externalClosedWidth = 220.0
    var openWidth = 640.0
    var openHeight = 350.0

    var openSize: CGSize { CGSize(width: openWidth, height: openHeight) }
}

// MARK: - Padding

/// Space between the panel edge and the terminal grid.
struct ContentInsets: Codable, Equatable {
    var top: Double
    var horizontal: Double
    var bottom: Double
}

/// Built-in notched displays and external displays get separate insets, because
/// the notch's rounded corners and scaling differ from a regular monitor.
struct PaddingSettings: Codable, Equatable {
    var notched = ContentInsets(top: 2, horizontal: 12, bottom: 8)
    var external = ContentInsets(top: 2, horizontal: 12, bottom: 4)

    func insets(hasNotch: Bool) -> ContentInsets {
        hasNotch ? notched : external
    }
}

// MARK: - Appearance & motion

struct AppearanceSettings: Codable, Equatable {
    var shadowEnabled = true
    var shadowRadius = 8.0
    var shadowOpacity = 0.5
    var openCornerRadius = 22.0
    var opacity = 1.0
    var blurRadius = 0.0
    var showsTitleWhenClosed = true
}

struct MotionSettings: Codable, Equatable {
    var openResponse = 0.42
    var openDamping = 0.8
    var closeResponse = 0.45
    var closeDamping = 1.0
    var resizeDuration = 0.35
}

// MARK: - Terminal

enum CursorShape: String, Codable, CaseIterable, Identifiable {
    case block, underline, bar

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct TerminalSettings: Codable, Equatable {
    static let defaultFontSize = 13.0
    static let fontSizeRange = 8.0...32.0

    /// PostScript name of a monospaced font. Empty means the system monospaced font.
    var fontName = ""
    var fontSize = defaultFontSize
    var theme = TerminalTheme.classic
    var cursorShape = CursorShape.block
    var cursorBlinks = true
    var optionAsMeta = true
    var shellPath = ""
    var scrollbackLines = 5_000
}

// MARK: - Size presets

struct SizePreset: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var width: Double
    var height: Double
    var hotkey: KeyChord?

    var size: CGSize { CGSize(width: width, height: height) }

    static let defaults: [SizePreset] = [
        SizePreset(name: "Compact", width: 480, height: 220, hotkey: .commandShift(kVK_ANSI_1)),
        SizePreset(name: "Default", width: 640, height: 350, hotkey: .commandShift(kVK_ANSI_2)),
        SizePreset(name: "Large", width: 900, height: 500, hotkey: .commandShift(kVK_ANSI_3)),
    ]

    /// The first free ⌘⇧digit chord, for newly created presets.
    static func suggestedHotkey(excluding presets: [SizePreset]) -> KeyChord? {
        let used = Set(presets.compactMap(\.hotkey))
        return KeyChord.digitKeyCodes.lazy.map(KeyChord.commandShift).first { !used.contains($0) }
    }
}
