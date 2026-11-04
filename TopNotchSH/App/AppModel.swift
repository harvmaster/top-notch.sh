import AppKit
import SwiftUI

/// Composition root: builds every service once and wires them together.
@MainActor
final class AppModel {
    let settings: SettingsStore
    let workspaces: WorkspaceStore
    let coordinator: NotchCoordinator
    let input: InputRouter
    let updates: UpdateController
    private let popouts: PopoutWindows
    private let settingsWindow: SettingsWindow
    private let welcomeWindow = WelcomeWindow()

    init(config: ConfigDirectory = .standard) {
        if config.url == ConfigDirectory.standard.url, ConfigDirectory.override == nil {
            config.migrateFromUserDefaults()
        }
        let settings = SettingsStore(file: config.settings, watchesForEdits: true)
        let workspaces = WorkspaceStore(
            file: config.workspaces,
            restoresTabs: { settings.settings.general.restoreTabs }
        ) { directory, command in
            let session = TerminalSession(settings: settings, directory: directory)
            session.start(running: command)
            return session
        }
        let settingsWindow = SettingsWindow()
        let popouts = PopoutWindows(settings: settings)
        let coordinator = NotchCoordinator(
            settings: settings,
            workspaces: workspaces,
            popouts: popouts,
            displaysFile: config.displays,
            showSettings: { settingsWindow.show() }
        )
        let input = InputRouter(settings: settings, workspaces: workspaces) { [weak coordinator] command in
            coordinator?.perform(command)
        }

        self.settings = settings
        self.workspaces = workspaces
        self.coordinator = coordinator
        self.input = input
        self.popouts = popouts
        self.settingsWindow = settingsWindow
        updates = UpdateController(
            settings: settings,
            terminals: {
                (workspaces.workspaces.flatMap(\.tabs) + popouts.openSessions).map {
                    IdleCheck.Terminal(isRunningCommand: $0.isRunningCommand, lastInputAt: $0.lastInputAt)
                }
            },
            isInUse: { [weak coordinator] in (coordinator?.isAnyNotchOpen ?? false) || popouts.isInUse }
        )

        let updates = updates
        settingsWindow.makeRootView = {
            AnyView(
                SettingsView()
                    .environmentObject(settings)
                    .environmentObject(workspaces)
                    .environmentObject(coordinator)
                    .environmentObject(input.hotkeyStatus)
                    .environmentObject(updates)
            )
        }

        welcomeWindow.makeRootView = { dismiss in
            AnyView(
                WelcomeView(dismiss: dismiss) { settingsWindow.show() }
                    .environmentObject(settings)
                    .environmentObject(input.hotkeyStatus)
            )
        }
        welcomeWindow.onDismiss = { [weak coordinator] openTerminal in
            settings.update { $0.general.hasSeenWelcome = true }
            if openTerminal {
                coordinator?.perform(.toggleNotch)
            }
        }
    }

    func start(registeringGlobalHotkey: Bool = true, showingWelcome: Bool = true) {
        coordinator.start()
        input.start(registeringGlobalHotkey: registeringGlobalHotkey)
        // Development builds don't update themselves (unless asked to, for testing).
        #if DEBUG
        let startsUpdater = ProcessInfo.processInfo.environment["TOPNOTCHSH_UPDATE_FEED"] != nil
        #else
        let startsUpdater = true
        #endif
        if startsUpdater {
            updates.start()
            if ProcessInfo.processInfo.arguments.contains("--check-for-updates") {
                updates.checkInBackground()
            }
        }
        if showingWelcome, !settings.settings.general.hasSeenWelcome {
            welcomeWindow.show()
        }
    }

    func showWelcome() {
        welcomeWindow.show()
    }

    func stop() {
        workspaces.persist()
        input.stop()
        coordinator.stop()
    }

    func perform(_ command: Command) {
        coordinator.perform(command)
    }
}
