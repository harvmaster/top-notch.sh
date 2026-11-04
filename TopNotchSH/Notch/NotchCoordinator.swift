import AppKit
import Combine

/// Owns one `NotchController` per display, keeps them in sync with the
/// connected screens and settings, and carries out every `Command`.
@MainActor
final class NotchCoordinator: ObservableObject {
    /// All connected displays, for the settings UI.
    @Published private(set) var screens: [ScreenGeometry] = []
    /// Which workspace each display shows. Persisted, including for
    /// displays that are currently disconnected.
    @Published private(set) var assignments: [ScreenID: WorkspaceID]

    private let settings: SettingsStore
    private let workspaces: WorkspaceStore
    private let popouts: PopoutWindows
    private let showSettings: () -> Void
    private let assignmentStore: ConfigFile<[ScreenID: WorkspaceID]>

    private(set) var controllers: [ScreenID: NotchController] = [:]
    private var previousApp: NSRunningApplication?
    private var subscriptions = Set<AnyCancellable>()

    init(
        settings: SettingsStore,
        workspaces: WorkspaceStore,
        popouts: PopoutWindows,
        displaysFile: ConfigFile<[ScreenID: WorkspaceID]>,
        showSettings: @escaping () -> Void
    ) {
        self.settings = settings
        self.workspaces = workspaces
        self.popouts = popouts
        self.showSettings = showSettings
        assignmentStore = displaysFile
        assignments = displaysFile.loadOrBackUp(defaults: [:])
    }

    func start() {
        syncScreens()

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.syncScreens() }
            .store(in: &subscriptions)

        settings.publisher(\.general.showOnAllDisplays)
            .dropFirst()
            .sink { [weak self] _ in self?.syncScreens() }
            .store(in: &subscriptions)

        settings.publisher(\.general.hideFromScreenSharing)
            .dropFirst()
            .sink { [weak self] hidden in self?.controllers.values.forEach { $0.setHiddenFromScreenSharing(hidden) } }
            .store(in: &subscriptions)

        Publishers.Merge(
            settings.publisher(\.sizing).dropFirst().map { _ in () },
            settings.publisher(\.appearance).dropFirst().map { _ in () }
        )
        .sink { [weak self] in self?.controllers.values.forEach { $0.refresh() } }
        .store(in: &subscriptions)
    }

    func stop() {
        subscriptions.removeAll()
        controllers.values.forEach { $0.tearDown() }
        controllers.removeAll()
    }

    // MARK: - Commands

    func perform(_ command: Command) {
        perform(command, on: nil)
    }

    private func perform(_ command: Command, on target: NotchController?) {
        let notch = target ?? focusedNotch

        switch command {
        case .toggleNotch:
            if let focusedNotch {
                focusedNotch.close()
            } else if let notch = notchUnderPointer, notch.isOpen {
                // Open but unfocused (pinned, or focus-loss closing is off): bring it forward.
                notch.focus()
            } else {
                notchUnderPointer?.open()
            }
        case .closeNotch:
            notch?.close()
        case .newTab:
            notch?.workspace.newTab()
        case .closeTab:
            notch?.workspace.closeActiveTab()
        case .reopenClosedTab:
            notch?.workspace.reopenClosedTab()
        case .togglePin:
            notch?.togglePin()
        case .find(let direction):
            focusedSession?.find(direction)
        case .nextTab:
            notch?.workspace.selectTab(offset: 1)
        case .previousTab:
            notch?.workspace.selectTab(offset: -1)
        case .selectTab(let index):
            notch?.workspace.selectTab(at: index)
        case .detachTab:
            guard let workspace = notch?.workspace,
                  let tab = workspace.activeTab,
                  let session = workspace.detachTab(tab.id) else { return }
            popouts.open(session)
        case .nextWorkspace, .previousWorkspace:
            guard let notch else { return }
            let offset = command == .nextWorkspace ? 1 : -1
            assign(workspaces.workspace(notch.workspace.id, offset: offset), to: notch)
        case .selectWorkspace(let id):
            guard let notch, let workspace = workspaces.workspace(id) else { return }
            assign(workspace, to: notch)
        case .createWorkspace:
            guard let notch else { return }
            assign(workspaces.create(), to: notch)
        case .deleteWorkspace(let id):
            guard let workspace = workspaces.workspace(id) else { return }
            delete(workspace)
        case .applySizePreset(let preset):
            settings.update {
                $0.sizing.openWidth = preset.width
                $0.sizing.openHeight = preset.height
            }
        case .resetTerminal:
            focusedSession?.resetInputModes()
        case .adjustFontSize(let delta):
            settings.update {
                $0.terminal.fontSize = ($0.terminal.fontSize + delta).clamped(to: TerminalSettings.fontSizeRange)
            }
        case .resetFontSize:
            settings.update { $0.terminal.fontSize = TerminalSettings.defaultFontSize }
        case .showSettings:
            showSettings()
        }
    }

    // MARK: - Workspaces

    func assign(_ workspace: Workspace, toScreen screenID: ScreenID) {
        if let controller = controllers[screenID] {
            assign(workspace, to: controller)
        } else {
            setAssignment(workspace.id, for: screenID)
        }
    }

    func workspace(forScreen screenID: ScreenID) -> Workspace {
        workspaces.workspace(assignments[screenID]) ?? workspaces.primary
    }

    /// Deletes a workspace and moves every display that showed it to a neighbour.
    func delete(_ workspace: Workspace) {
        guard let fallback = workspaces.delete(workspace) else { return }
        for controller in controllers.values where controller.workspace === workspace {
            assign(fallback, to: controller)
        }
        for (screenID, workspaceID) in assignments where workspaceID == workspace.id {
            setAssignment(fallback.id, for: screenID)
        }
    }

    private func assign(_ workspace: Workspace, to controller: NotchController) {
        setAssignment(workspace.id, for: controller.id)
        if controller.isOpen {
            closeOthers(showing: workspace, except: controller)
        }
        controller.show(workspace)
    }

    private func setAssignment(_ workspaceID: WorkspaceID, for screenID: ScreenID) {
        guard assignments[screenID] != workspaceID else { return }
        assignments[screenID] = workspaceID
        assignmentStore.save(assignments)
    }

    /// A terminal view can only live in one window, so a workspace is
    /// presented on at most one open notch at a time.
    private func closeOthers(showing workspace: Workspace, except controller: NotchController) {
        for other in controllers.values where other !== controller && other.isOpen && other.workspace === workspace {
            other.close()
        }
    }

    // MARK: - Screens

    private func syncScreens() {
        screens = NSScreen.screens.map(ScreenGeometry.init)
        let visible = visibleScreens().map(ScreenGeometry.init)
        let visibleIDs = Set(visible.map(\.id))

        for (id, controller) in controllers where !visibleIDs.contains(id) {
            controller.tearDown()
            controllers[id] = nil
        }

        for geometry in visible {
            if let controller = controllers[geometry.id] {
                controller.refresh(geometry: geometry)
            } else {
                let controller = NotchController(
                    geometry: geometry,
                    workspace: workspace(forScreen: geometry.id),
                    settings: settings,
                    workspaces: workspaces
                )
                controller.delegate = self
                controllers[geometry.id] = controller
            }
        }
    }

    /// Every display, or just the one with a notch (falling back to the menu-bar display).
    private func visibleScreens() -> [NSScreen] {
        let screens = NSScreen.screens
        if settings.settings.general.showOnAllDisplays {
            return screens
        }
        return [screens.first { $0.safeAreaInsets.top > 0 } ?? screens.first].compactMap { $0 }
    }

    var isAnyNotchOpen: Bool {
        controllers.values.contains(where: \.isOpen)
    }

    private var focusedNotch: NotchController? {
        controllers.values.first { $0.isOpen && $0.isKey }
    }

    private var notchUnderPointer: NotchController? {
        let pointer = NSEvent.mouseLocation
        return controllers.values.first { NSMouseInRect(pointer, $0.geometry.frame, false) }
            ?? controllers.values.first { $0.geometry.frame.origin == .zero }
            ?? controllers.values.first
    }

    private var focusedSession: TerminalSession? {
        (NSApp.keyWindow?.firstResponder as? SessionTerminalView)?.session
    }
}

// MARK: - NotchControllerDelegate

extension NotchCoordinator: NotchControllerDelegate {
    func notchWillOpen(_ controller: NotchController) {
        if !NSApp.isActive {
            previousApp = NSWorkspace.shared.frontmostApplication
        }
        closeOthers(showing: controller.workspace, except: controller)
    }

    func notchDidClose(_ controller: NotchController) {
        guard !controllers.values.contains(where: \.isOpen) else { return }
        ActivationPolicy.refresh()
        defer { previousApp = nil }

        // Hand focus back to whatever was frontmost, unless the user has moved
        // on to another app or has one of our own windows (settings, pop-outs)
        // open. Checking visibility rather than key status avoids a race with
        // a window that is still becoming key.
        let hasOwnWindows = NSApp.windows.contains { $0.isVisible && !($0 is NSPanel) && $0.styleMask.contains(.titled) }
        guard NSApp.isActive, !hasOwnWindows, let previousApp, !previousApp.isTerminated else { return }
        previousApp.activate()
    }

    func notch(_ controller: NotchController, perform command: Command) {
        perform(command, on: controller)
    }
}
