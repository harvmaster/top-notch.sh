import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Click once to record a shortcut, then press it. Esc or a second click
/// cancels. Optionally clearable.
struct HotkeyRecorder: View {
    @Binding var chord: KeyChord?
    var allowsClearing = false

    @StateObject private var listener = ChordListener()

    var body: some View {
        HStack(spacing: 6) {
            Button {
                listener.isListening ? listener.stop() : listener.start { chord = $0 }
            } label: {
                Text(listener.isListening ? "Type shortcut…" : chord?.displayString ?? "None")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(listener.isListening ? Color.accentColor : chord == nil ? .secondary : .primary)
                    .frame(width: 130, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(listener.isListening ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.1))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(listener.isListening ? Color.accentColor : Color.secondary.opacity(0.25))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(listener.isListening ? "Press a shortcut, or Esc to cancel" : "Click to record a shortcut")

            if allowsClearing {
                Button {
                    listener.stop()
                    chord = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(chord == nil)
                .help("Clear shortcut")
            }
        }
        .fixedSize()
        .onDisappear { listener.stop() }
    }
}

extension HotkeyRecorder {
    /// Recorder for a shortcut that must always exist.
    init(chord: Binding<KeyChord>) {
        self.init(chord: Binding<KeyChord?>(get: { chord.wrappedValue }, set: { if let value = $0 { chord.wrappedValue = value } }))
    }
}

/// Captures the next key chord through a local event monitor, so no view has
/// to win keyboard focus first. Only one listener is active at a time.
///
/// Posts `isListeningDidChange` so the global toggle hotkey can step aside
/// while a chord (possibly the toggle itself) is being captured.
@MainActor
final class ChordListener: ObservableObject {
    static let isListeningDidChange = Notification.Name("ChordListenerIsListeningDidChange")

    private static weak var active: ChordListener?

    @Published private(set) var isListening = false {
        didSet {
            guard isListening != oldValue else { return }
            NotificationCenter.default.post(name: Self.isListeningDidChange, object: nil, userInfo: ["isListening": isListening])
        }
    }
    private var monitor: Any?
    private var onChord: ((KeyChord) -> Void)?

    func start(onChord: @escaping (KeyChord) -> Void) {
        Self.active?.stop()
        Self.active = self
        self.onChord = onChord
        isListening = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return nil
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        onChord = nil
        isListening = false
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            stop()
            return
        }
        // Shortcuts need at least one modifier.
        guard let chord = KeyChord(event: event) else {
            NSSound.beep()
            return
        }
        onChord?(chord)
        stop()
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
