import Carbon.HIToolbox
import XCTest
@testable import TopNotchSH

final class SettingsTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "TopNotchSHTests.\(UUID().uuidString)")
    }

    func testMissingKeysFallBackToDefaults() throws {
        let partial = #"{"terminal":{"fontSize":17},"hotkeys":{"newTab":{"modifiers":1048576,"keyCode":45}}}"#
        defaults.set(Data(partial.utf8), forKey: "settings")

        let settings = JSONDefaults<AppSettings>(key: "settings", defaults: defaults).load(fallback: AppSettings())

        XCTAssertEqual(settings.terminal.fontSize, 17)
        XCTAssertEqual(settings.terminal.theme, .classic)
        XCTAssertEqual(settings.chord(for: .newTab), .command(kVK_ANSI_N))
        XCTAssertEqual(settings.chord(for: .resetTerminal), .command(kVK_ANSI_R))
        XCTAssertEqual(settings.padding, PaddingSettings())
    }

    func testRoundTrip() {
        let store = JSONDefaults<AppSettings>(key: "settings", defaults: defaults)
        var settings = AppSettings()
        settings.padding.notched.bottom = 22
        settings.sizePresets.removeLast()
        store.save(settings)

        XCTAssertEqual(store.load(fallback: AppSettings()), settings)
    }

    func testCorruptDataFallsBack() {
        defaults.set(Data("not json".utf8), forKey: "settings")
        XCTAssertEqual(JSONDefaults<AppSettings>(key: "settings", defaults: defaults).load(fallback: AppSettings()), AppSettings())
    }

    func testDefaultHotkeysAreUnique() {
        let chords = HotkeyAction.allCases.map(\.defaultChord)
        XCTAssertEqual(Set(chords).count, chords.count)
    }

    func testResetHotkeyDefaultsToCommandR() {
        XCTAssertEqual(HotkeyAction.resetTerminal.defaultChord, KeyChord(.command, kVK_ANSI_R))
        XCTAssertEqual(HotkeyAction.resetTerminal.scope, .terminal)
    }

    func testSuggestedPresetHotkeySkipsUsedDigits() {
        XCTAssertEqual(SizePreset.suggestedHotkey(excluding: SizePreset.defaults), .commandShift(kVK_ANSI_4))
    }

    func testPaddingPerDisplayKind() {
        var padding = PaddingSettings()
        padding.notched.bottom = 30
        XCTAssertEqual(padding.insets(hasNotch: true).bottom, 30)
        XCTAssertEqual(padding.insets(hasNotch: false), padding.external)
    }
}

final class KeyChordTests: XCTestCase {
    func testDisplayStringOrdersModifiersLikeMacOS() {
        XCTAssertEqual(KeyChord([.command, .shift, .control, .option], kVK_Return).displayString, "⌃⌥⇧⌘⏎")
        XCTAssertEqual(KeyChord.commandShift(kVK_UpArrow).displayString, "⇧⌘↑")
    }

    func testIgnoresNonShortcutModifiers() {
        let chord = KeyChord([.command, .capsLock, .numericPad], kVK_ANSI_T)
        XCTAssertEqual(chord, .command(kVK_ANSI_T))
    }

    func testCarbonModifiers() {
        XCTAssertEqual(KeyChord.commandShift(kVK_ANSI_T).carbonModifiers, UInt32(cmdKey | shiftKey))
    }
}

@MainActor
final class SettingsStoreTests: XCTestCase {
    /// Subscribers must see the new value when they read the store, not the old one.
    func testPublisherFiresAfterTheChange() {
        let store = SettingsStore(defaults: UserDefaults(suiteName: "TopNotchSHTests.\(UUID().uuidString)")!)
        var observed: [Double] = []
        let subscription = store.publisher(\.sizing.openWidth).sink { _ in observed.append(store.settings.sizing.openWidth) }
        store.update { $0.sizing.openWidth = 480 }
        subscription.cancel()
        XCTAssertEqual(observed, [640, 480])
    }
}
