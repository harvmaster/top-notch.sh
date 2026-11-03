import AppKit
import Carbon.HIToolbox

/// A keyboard shortcut: a set of modifiers plus a virtual key code.
struct KeyChord: Codable, Hashable {
    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .shift, .control, .option]

    var modifiers: UInt
    var keyCode: UInt16

    init(_ modifiers: NSEvent.ModifierFlags, _ keyCode: Int) {
        self.modifiers = modifiers.intersection(Self.relevantModifiers).rawValue
        self.keyCode = UInt16(keyCode)
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(Self.relevantModifiers)
        guard !flags.isEmpty else { return nil }
        self.init(flags, Int(event.keyCode))
    }

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers)
    }

    func matches(_ event: NSEvent) -> Bool {
        event.keyCode == keyCode
            && event.modifierFlags.intersection(Self.relevantModifiers).rawValue == modifiers
    }

    /// Modifier mask in the format Carbon's `RegisterEventHotKey` expects.
    var carbonModifiers: UInt32 {
        let flags = modifierFlags
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        return carbon
    }

    /// Human-readable label such as "⌘⏎" or "⌃⇧T".
    var displayString: String {
        let flags = modifierFlags
        var result = ""
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        return result + Self.keyName(for: keyCode)
    }
}

// MARK: - Common chords

extension KeyChord {
    static func command(_ keyCode: Int) -> KeyChord { KeyChord(.command, keyCode) }
    static func commandShift(_ keyCode: Int) -> KeyChord { KeyChord([.command, .shift], keyCode) }

    static let digitKeyCodes: [Int] = [
        kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
        kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
    ]

    /// ⌘1…⌘9 → 0…8.
    static func commandDigitIndex(of event: NSEvent) -> Int? {
        guard event.modifierFlags.intersection(relevantModifiers) == .command else { return nil }
        return digitKeyCodes.firstIndex(of: Int(event.keyCode))
    }
}

// MARK: - Key names

private extension KeyChord {
    static let namedKeys: [Int: String] = [
        kVK_Return: "⏎", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_DownArrow: "↓", kVK_UpArrow: "↑", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    static func keyName(for keyCode: UInt16) -> String {
        if let name = namedKeys[Int(keyCode)] { return name }
        return translatedCharacter(for: keyCode)?.uppercased() ?? "Key\(keyCode)"
    }

    /// Resolves the character a key produces on the current keyboard layout.
    static func translatedCharacter(for keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }

        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)

        let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count, &length, &characters
            )
        }

        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}
