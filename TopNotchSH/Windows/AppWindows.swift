import AppKit
import Combine
import SwiftUI

/// The app lives in the menu bar, but while it has real windows (settings,
/// pop-out terminals) it shows in the Dock and ⌘-Tab so they can be found.
@MainActor
enum ActivationPolicy {
    /// Shows the app in the Dock and brings `window` forward. Switching the
    /// policy briefly hands focus to another app, so activate again once it
    /// has settled.
    static func present(_ window: NSWindow) {
        let wasAccessory = NSApp.activationPolicy() != .regular
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        guard wasAccessory else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard window.isVisible else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    static func refresh() {
        // Run after the window that triggered this has finished opening or closing.
        DispatchQueue.main.async {
            let hasWindows = NSApp.windows.contains { $0.isVisible && !($0 is NSPanel) && $0.styleMask.contains(.titled) }
            // Leaving the Dock deactivates the app, which would close an open
            // notch the user is still working in. Wait until it closes.
            let hasOpenNotch = NSApp.windows.contains { ($0 as? NotchPanel)?.isOpen == true }
            guard !hasWindows, !hasOpenNotch else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

// MARK: - Settings

@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let identifier = NSUserInterfaceItemIdentifier("settings")

    var makeRootView: (() -> AnyView)?
    private var window: NSWindow?

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        ActivationPolicy.present(window)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Top NotchSH Settings"
        window.identifier = Self.identifier
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: makeRootView?() ?? AnyView(EmptyView()))
        window.setFrameAutosaveName("SettingsWindow")
        if !window.setFrameUsingName("SettingsWindow") {
            window.center()
        }
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        window = nil
        ActivationPolicy.refresh()
    }
}

// MARK: - Pop-out terminals

/// Standalone windows for tabs detached from the notch. Closing the window
/// ends its shell; exiting the shell closes the window.
@MainActor
final class PopoutWindows: NSObject, NSWindowDelegate {
    private let settings: SettingsStore
    private var sessions: [ObjectIdentifier: TerminalSession] = [:]
    private var windows: [ObjectIdentifier: NSWindow] = [:]
    private var subscriptions: [ObjectIdentifier: AnyCancellable] = [:]
    private var sharingSubscription: AnyCancellable?

    init(settings: SettingsStore) {
        self.settings = settings
        super.init()
        sharingSubscription = settings.publisher(\.general.hideFromScreenSharing)
            .sink { [weak self] hidden in
                self?.windows.values.forEach { $0.sharingType = hidden ? .none : .readOnly }
            }
    }

    func open(_ session: TerminalSession) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.sharingType = settings.settings.general.hideFromScreenSharing ? .none : .readOnly
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self
        window.contentView = NSHostingView(rootView: PopoutView(session: session).environmentObject(settings))

        let key = ObjectIdentifier(window)
        sessions[key] = session
        windows[key] = window
        subscriptions[key] = session.$title.combineLatest(session.$customName)
            .sink { [weak window] title, name in window?.title = name ?? title }
        session.onExit = { [weak window] in window?.close() }

        window.center()
        ActivationPolicy.present(window)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let key = ObjectIdentifier(window)
        sessions.removeValue(forKey: key)?.terminate()
        windows[key] = nil
        subscriptions[key] = nil
        window.contentView = nil
        ActivationPolicy.refresh()
    }
}

private struct PopoutView: View {
    let session: TerminalSession
    @EnvironmentObject private var settingsStore: SettingsStore

    var body: some View {
        TerminalSurface(session: session)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(PanelBackground(color: settingsStore.settings.terminal.theme.palette.backgroundColor))
            .frame(minWidth: 320, minHeight: 160)
    }
}
