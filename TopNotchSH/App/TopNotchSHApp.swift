import Combine
import SwiftUI

@main
struct TopNotchSHApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Top NotchSH", systemImage: "apple.terminal", isInserted: delegate.menuBarIconBinding) {
            Button("Toggle Notch") { delegate.model.perform(.toggleNotch) }
            Divider()
            Button("Settings…") { delegate.model.perform(.showSettings) }
                .keyboardShortcut(",")
            Divider()
            Button("Quit Top NotchSH") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

/// Starts and stops the app. Observable so the menu bar icon follows settings.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let model: AppModel
    private var subscription: AnyCancellable?

    override init() {
        #if DEBUG
        model = SelfTest.isRequested ? AppModel(defaults: SelfTest.defaults) : AppModel()
        #else
        model = AppModel()
        #endif
        super.init()
        subscription = model.settings.publisher(\.general.showMenuBarIcon)
            .dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var menuBarIconBinding: Binding<Bool> {
        model.settings.binding(\.general.showMenuBarIcon)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if SelfTest.isRequested {
            model.start(registeringGlobalHotkey: false)
            SelfTest(model: model).start()
            return
        }
        #endif
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    /// With the menu bar icon hidden, launching the app again opens settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        model.perform(.showSettings)
        return false
    }
}
