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

    @discardableResult
    func register(_ chord: KeyChord) -> Bool {
        unregister()
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(UInt32(chord.keyCode), chord.carbonModifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            NSLog("Top NotchSH: could not register %@ as the global hotkey (OSStatus %d); another app may own it.", chord.displayString, status)
        }
        return status == noErr
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
