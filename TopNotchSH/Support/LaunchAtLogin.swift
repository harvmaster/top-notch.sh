import ServiceManagement

/// Login-item registration. Read from the system each time rather than stored,
/// so it stays correct when changed in System Settings.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Top NotchSH: failed to update login item: \(error.localizedDescription)")
        }
    }
}
