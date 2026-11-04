import AppKit
import SwiftUI

/// Shown once on first launch: a menu-bar app is otherwise invisible, and new
/// users need to learn the shortcut that opens it.
@MainActor
final class WelcomeWindow: NSObject, NSWindowDelegate {
    var makeRootView: ((_ dismiss: @escaping (_ openTerminal: Bool) -> Void) -> AnyView)?
    var onDismiss: ((_ openTerminal: Bool) -> Void)?

    private var window: NSWindow?
    private var opensTerminalOnClose = false

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        ActivationPolicy.present(window)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 380),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Top NotchSH"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: makeRootView? { [weak self] openTerminal in
            self?.opensTerminalOnClose = openTerminal
            self?.window?.close()
        } ?? AnyView(EmptyView()))
        window.center()
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        window = nil
        let openTerminal = opensTerminalOnClose
        opensTerminalOnClose = false
        onDismiss?(openTerminal)
        ActivationPolicy.refresh()
    }
}

struct WelcomeView: View {
    let dismiss: (_ openTerminal: Bool) -> Void
    var showSettings: () -> Void = {}

    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var hotkeyStatus: HotkeyStatus

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)

            VStack(spacing: 6) {
                Text("Welcome to Top NotchSH")
                    .font(.title2.weight(.semibold))
                Text("A terminal that lives in your notch.")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Text("Open it from any app with")
                    HotkeyRecorder(chord: Binding(
                        get: { store.settings.chord(for: .toggleNotch) },
                        set: { chord in store.update { $0.hotkeys[.toggleNotch] = chord } }
                    ))
                }
                if let problem = hotkeyStatus.problem {
                    ShortcutProblem(text: problem)
                } else {
                    Caption("Click the shortcut to change it. Everything else is in the menu bar icon's Settings.")
                        .multilineTextAlignment(.center)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.5)))

            HStack {
                Button("Settings…") {
                    dismiss(false)
                    showSettings()
                }
                Spacer()
                Button("Open Terminal") { dismiss(true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 30)
        .padding(.bottom, 22)
        .frame(width: 440)
    }
}

/// An orange warning shown when the global shortcut can't work.
struct ShortcutProblem: View {
    let text: String

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.callout)
        .foregroundStyle(.orange)
    }
}
