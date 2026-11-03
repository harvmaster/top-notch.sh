import AppKit
import SwiftUI

/// Composition root: builds every service once and wires them together.
@MainActor
final class AppModel {
    let settings: SettingsStore
    let workspaces: WorkspaceStore
    let coordinator: NotchCoordinator
    let input: InputRouter
    private let settingsWindow: SettingsWindow

    init(defaults: UserDefaults = .standard) {
        let settings = SettingsStore(defaults: defaults)
        let workspaces = WorkspaceStore(defaults: defaults) { directory in
            let session = TerminalSession(settings: settings, directory: directory)
            session.start()
            return session
        }
        let settingsWindow = SettingsWindow()
        let coordinator = NotchCoordinator(
            settings: settings,
            workspaces: workspaces,
            popouts: PopoutWindows(settings: settings),
            defaults: defaults,
            showSettings: { settingsWindow.show() }
        )
        let input = InputRouter(settings: settings, workspaces: workspaces) { [weak coordinator] command in
            coordinator?.perform(command)
        }

        self.settings = settings
        self.workspaces = workspaces
        self.coordinator = coordinator
        self.input = input
        self.settingsWindow = settingsWindow

        settingsWindow.makeRootView = {
            AnyView(
                SettingsView()
                    .environmentObject(settings)
                    .environmentObject(workspaces)
                    .environmentObject(coordinator)
            )
        }
    }

    func start(registeringGlobalHotkey: Bool = true) {
        coordinator.start()
        input.start(registeringGlobalHotkey: registeringGlobalHotkey)
    }

    func stop() {
        input.stop()
        coordinator.stop()
    }

    func perform(_ command: Command) {
        coordinator.perform(command)
    }
}
