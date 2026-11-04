import Foundation
import Carbon.HIToolbox

/// A single system-wide hotkey registered through Carbon, which works from
/// any app without requiring Accessibility permission.
@MainActor
final class GlobalHotkey {
    private static let signature = OSType(0x544E_5348) // "TNSH"

    var onPress: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { MainActor.assumeIsolated { hotkey.onPress?() } }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
    }

    enum Status: Equatable {
        case registered
        /// A macOS shortcut (Spotlight, Mission Control, …) uses this chord and wins.
        case systemShortcut
        /// Another app holds this chord exclusively.
        case takenByAnotherApp
        case failed(OSStatus)
    }

    /// Registers exclusively, so other apps can't take the chord afterwards
    /// and an app already holding it is detected.
    @discardableResult
    func register(_ chord: KeyChord) -> Status {
        unregister()
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(
            UInt32(chord.keyCode), chord.carbonModifiers, id, GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive), &hotKeyRef
        )
        switch status {
        case noErr:
            // Registered, but an enabled macOS shortcut on the same chord fires instead.
            return SystemShortcuts.isReserved(chord) ? .systemShortcut : .registered
        case OSStatus(eventHotKeyExistsErr):
            return .takenByAnotherApp
        default:
            return .failed(status)
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
    }

    func invalidate() {
        unregister()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
        handlerRef = nil
        onPress = nil
    }
}

/// macOS's own keyboard shortcuts (System Settings → Keyboard → Keyboard
/// Shortcuts). An enabled one takes precedence over any app's hotkey.
enum SystemShortcuts {
    static func isReserved(_ chord: KeyChord) -> Bool {
        var shortcuts: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&shortcuts) == noErr,
              let list = shortcuts?.takeRetainedValue() as? [[String: Any]] else { return false }
        return list.contains { shortcut in
            (shortcut[kHISymbolicHotKeyEnabled as String] as? Bool) == true
                && (shortcut[kHISymbolicHotKeyCode as String] as? Int) == Int(chord.keyCode)
                && (shortcut[kHISymbolicHotKeyModifiers as String] as? Int).map(UInt32.init) == chord.carbonModifiers
        }
    }
}

/// Whether the global toggle shortcut actually works, for display in the UI.
@MainActor
final class HotkeyStatus: ObservableObject {
    @Published fileprivate(set) var chord: KeyChord?
    @Published fileprivate(set) var status: GlobalHotkey.Status = .registered

    /// A sentence explaining the problem, or `nil` when the shortcut works.
    var problem: String? {
        guard let chord else { return nil }
        switch status {
        case .registered:
            return nil
        case .systemShortcut:
            return "\(chord.displayString) is a macOS shortcut, which takes precedence. Pick another, or turn it off in System Settings → Keyboard → Keyboard Shortcuts."
        case .takenByAnotherApp:
            return "\(chord.displayString) is already used by another app. Pick another shortcut, or free it in that app."
        case .failed(let code):
            return "\(chord.displayString) couldn't be registered (error \(code)). Pick another shortcut."
        }
    }

    func record(_ status: GlobalHotkey.Status, for chord: KeyChord) {
        self.chord = chord
        self.status = status
    }
}
