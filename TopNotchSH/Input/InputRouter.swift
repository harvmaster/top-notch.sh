import AppKit
import Carbon.HIToolbox
import Combine

/// Turns keyboard and scroll events into `Command`s and terminal input.
///
/// One local monitor serves every window and session:
/// 1. Notch shortcuts (tabs, workspaces, presets, ⌘1–9) while an open notch is key.
/// 2. Terminal shortcuts (reset, font size) while any terminal has focus.
/// 3. macOS editing keys (⌘←, ⌘⌫, ⌘C…) translated for the focused terminal.
@MainActor
final class InputRouter {
    private let settings: SettingsStore
    private let workspaces: WorkspaceStore
    private let perform: (Command) -> Void
    private let globalHotkey = GlobalHotkey()
    /// Whether the global toggle shortcut is working, for the UI.
    let hotkeyStatus = HotkeyStatus()
    private var monitor: Any?
    private var subscription: AnyCancellable?
    private var recorderObserver: AnyCancellable?

    init(settings: SettingsStore, workspaces: WorkspaceStore, perform: @escaping (Command) -> Void) {
        self.settings = settings
        self.workspaces = workspaces
        self.perform = perform
    }

    func start(registeringGlobalHotkey: Bool = true) {
        if registeringGlobalHotkey {
            globalHotkey.onPress = { [weak self] in self?.perform(.toggleNotch) }
            subscription = settings.publisher(\.hotkeys)
                .map { $0[.toggleNotch] ?? HotkeyAction.toggleNotch.defaultChord }
                .removeDuplicates()
                .sink { [weak self] in self?.registerGlobalHotkey($0) }
            recorderObserver = NotificationCenter.default.publisher(for: ChordListener.isListeningDidChange)
                .compactMap { $0.userInfo?["isListening"] as? Bool }
                .sink { [weak self] in self?.setGlobalHotkeySuspended($0) }
        }

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumed ? nil : event
        }
    }

    func stop() {
        globalHotkey.invalidate()
        subscription = nil
        recorderObserver = nil
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    /// The global toggle is suspended while a shortcut is being recorded.
    func setGlobalHotkeySuspended(_ suspended: Bool) {
        if suspended {
            globalHotkey.unregister()
        } else if subscription != nil {
            registerGlobalHotkey(settings.settings.chord(for: .toggleNotch))
        }
    }

    private func registerGlobalHotkey(_ chord: KeyChord) {
        let status = globalHotkey.register(chord)
        hotkeyStatus.record(status, for: chord)
        if status != .registered {
            NSLog("Top NotchSH: global shortcut %@ may not work: %@", chord.displayString, String(describing: status))
        }
    }

    // MARK: - Routing

    /// Returns `true` if the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .keyDown: handleKey(event)
        case .scrollWheel: handleScroll(event)
        default: false
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let window = event.window ?? NSApp.keyWindow else { return false }

        if let panel = window as? NotchPanel, panel.isOpen, let command = notchCommand(for: event) {
            perform(command)
            return true
        }

        if window.firstResponder is NSText, let action = TextEditingKeys.action(for: event) {
            // A menu-bar-only app has no Edit menu, so text fields would
            // otherwise ignore ⌘A / ⌘C / ⌘V / ⌘X / ⌘Z.
            return NSApp.sendAction(action, to: nil, from: nil)
        }

        guard let session = (window.firstResponder as? SessionTerminalView)?.session else { return false }

        if let action = action(in: .terminal, matching: event) {
            perform(Command(action))
            return true
        }
        return session.handleKeyDown(event)
    }

    private func handleScroll(_ event: NSEvent) -> Bool {
        guard let frameView = event.window?.contentView?.superview,
              let hit = frameView.hitTest(event.locationInWindow) else { return false }
        let terminalView = sequence(first: hit, next: \.superview).lazy.compactMap { $0 as? SessionTerminalView }.first
        return terminalView?.session?.handleScrollWheel(event) ?? false
    }

    private func notchCommand(for event: NSEvent) -> Command? {
        if let action = action(in: .notch, matching: event) {
            return Command(action)
        }
        if let workspace = workspaces.workspaces.first(where: { $0.hotkey?.matches(event) == true }) {
            return .selectWorkspace(workspace.id)
        }
        if let preset = settings.settings.sizePresets.first(where: { $0.hotkey?.matches(event) == true }) {
            return .applySizePreset(preset)
        }
        if let index = KeyChord.commandDigitIndex(of: event) {
            return .selectTab(index: index)
        }
        return nil
    }

    private func action(in scope: HotkeyAction.Scope, matching event: NSEvent) -> HotkeyAction? {
        HotkeyAction.allCases.first { $0.scope == scope && settings.settings.chord(for: $0).matches(event) }
    }
}

/// Standard text-editing shortcuts, normally supplied by an app's Edit menu.
enum TextEditingKeys {
    static func action(for event: NSEvent) -> Selector? {
        let flags = event.modifierFlags.intersection(KeyChord.relevantModifiers)
        switch (flags, Int(event.keyCode)) {
        case (.command, kVK_ANSI_A): return #selector(NSText.selectAll(_:))
        case (.command, kVK_ANSI_C): return #selector(NSText.copy(_:))
        case (.command, kVK_ANSI_V): return #selector(NSText.paste(_:))
        case (.command, kVK_ANSI_X): return #selector(NSText.cut(_:))
        case (.command, kVK_ANSI_Z): return Selector(("undo:"))
        case ([.command, .shift], kVK_ANSI_Z): return Selector(("redo:"))
        default: return nil
        }
    }
}
