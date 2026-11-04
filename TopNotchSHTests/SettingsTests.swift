import Carbon.HIToolbox
import XCTest
@testable import TopNotchSH

/// A fresh, empty config directory per test.
func temporaryConfig() -> ConfigDirectory {
    ConfigDirectory(url: FileManager.default.temporaryDirectory.appending(path: "TopNotchSHTests-\(UUID().uuidString)", directoryHint: .isDirectory))
}

final class SettingsTests: XCTestCase {
    private var config: ConfigDirectory!

    override func setUp() {
        config = temporaryConfig()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: config.url)
    }

    private func writeSettings(_ json: String) throws {
        try FileManager.default.createDirectory(at: config.url, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: config.settings.url)
    }

    func testMissingKeysFallBackToDefaults() throws {
        try writeSettings(#"{"terminal":{"fontSize":17},"hotkeys":{"newTab":{"modifiers":1048576,"keyCode":45}}}"#)

        let settings = try XCTUnwrap(config.settings.load(defaults: AppSettings()))

        XCTAssertEqual(settings.terminal.fontSize, 17)
        XCTAssertEqual(settings.terminal.theme, .classic)
        XCTAssertEqual(settings.chord(for: .newTab), .command(kVK_ANSI_N))
        XCTAssertEqual(settings.chord(for: .resetTerminal), .command(kVK_ANSI_R))
        XCTAssertEqual(settings.padding, PaddingSettings())
    }

    func testRoundTripWritesReadableJSON() throws {
        var settings = AppSettings()
        settings.padding.notched.bottom = 22
        settings.sizePresets.removeLast()
        config.settings.save(settings)

        XCTAssertEqual(try config.settings.load(defaults: AppSettings()), settings)
        let text = try String(contentsOf: config.settings.url, encoding: .utf8)
        XCTAssertTrue(text.contains("\n  \"activity\" : {"), "pretty-printed with sorted keys")
    }

    func testMissingFileLoadsNothing() throws {
        XCTAssertNil(try config.settings.load(defaults: AppSettings()))
    }

    func testInvalidFileIsBackedUpNotOverwritten() throws {
        try writeSettings("{ not json")
        XCTAssertEqual(config.settings.loadOrBackUp(defaults: AppSettings()), AppSettings())
        let backup = config.settings.url.appendingPathExtension("invalid")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "{ not json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.settings.url.path))
    }

    func testMigratesFromUserDefaultsOnce() throws {
        let defaults = UserDefaults(suiteName: "TopNotchSHTests.\(UUID().uuidString)")!
        defaults.set(Data(#"{"terminal":{"fontSize":19}}"#.utf8), forKey: "settings")
        config.migrateFromUserDefaults(defaults)

        XCTAssertEqual(try config.settings.load(defaults: AppSettings())?.terminal.fontSize, 19)
        XCTAssertNil(defaults.data(forKey: "settings"), "migrated keys are removed")
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
        let store = SettingsStore(file: temporaryConfig().settings)
        var observed: [Double] = []
        let subscription = store.publisher(\.sizing.openWidth).sink { _ in observed.append(store.settings.sizing.openWidth) }
        store.update { $0.sizing.openWidth = 480 }
        subscription.cancel()
        XCTAssertEqual(observed, [640, 480])
    }

    func testHandEditsReloadButTyposAreIgnored() throws {
        let config = temporaryConfig()
        let store = SettingsStore(file: config.settings)
        store.update { $0.terminal.fontSize = 15 }

        var edited = try String(contentsOf: config.settings.url, encoding: .utf8)
        edited = edited.replacingOccurrences(of: "\"fontSize\" : 15", with: "\"fontSize\" : 21")
        try Data(edited.utf8).write(to: config.settings.url)
        store.reloadFromDisk()
        XCTAssertEqual(store.settings.terminal.fontSize, 21)

        try Data("{ broken".utf8).write(to: config.settings.url)
        store.reloadFromDisk()
        XCTAssertEqual(store.settings.terminal.fontSize, 21, "an invalid file keeps the current settings")
    }
}
