import AppKit
import Combine
import Sparkle

/// Decides whether relaunching for an update would interrupt anything.
struct IdleCheck {
    struct Terminal {
        var isRunningCommand: Bool
        var lastInputAt: Date
    }

    /// How long the user must have stopped typing.
    var quietPeriod: TimeInterval = 120

    /// Idle means every terminal is at its prompt, nothing has been typed for
    /// `quietPeriod`, and no notch or pop-out window is in use.
    func isIdle(terminals: [Terminal], isInUse: Bool, now: Date = Date()) -> Bool {
        !isInUse && terminals.allSatisfy {
            !$0.isRunningCommand && now.timeIntervalSince($0.lastInputAt) >= quietPeriod
        }
    }
}

/// Keeps the app up to date with Sparkle, following the user's `UpdatePolicy`.
///
/// Sparkle keeps its own preferences, so the policy in `settings.json` is
/// pushed into it on launch and whenever it changes.
@MainActor
final class UpdateController: NSObject, ObservableObject {
    @Published private(set) var isAvailable = false
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var lastCheck: Date?
    /// A downloaded update waiting for the app to become idle.
    @Published private(set) var readyVersion: String?

    private let settings: SettingsStore
    private let terminals: () -> [IdleCheck.Terminal]
    private let isInUse: () -> Bool
    private let idleCheck = IdleCheck()
    private var controller: SPUStandardUpdaterController?
    private var installNow: (() -> Void)?
    private var idleTimer: Timer?
    private var subscriptions = Set<AnyCancellable>()

    init(settings: SettingsStore, terminals: @escaping () -> [IdleCheck.Terminal], isInUse: @escaping () -> Bool) {
        self.settings = settings
        self.terminals = terminals
        self.isInUse = isInUse
    }

    func start() {
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        let updater = controller.updater

        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &subscriptions)
        updater.publisher(for: \.lastUpdateCheckDate)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.lastCheck = $0 }
            .store(in: &subscriptions)
        settings.publisher(\.updates.policy)
            .sink { [weak self] in self?.apply($0) }
            .store(in: &subscriptions)

        do {
            try updater.start()
            isAvailable = true
        } catch {
            NSLog("Top NotchSH: updater failed to start: %@", error.localizedDescription)
        }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// Checks quietly, following the policy (used at launch by `--check-for-updates`).
    func checkInBackground() {
        controller?.updater.checkForUpdatesInBackground()
    }

    /// Installs a downloaded update right away, relaunching the app.
    func installReadyUpdate() {
        guard let installNow else { return }
        self.installNow = nil
        idleTimer?.invalidate()
        idleTimer = nil
        installNow()
    }

    private func apply(_ policy: UpdatePolicy) {
        guard let updater = controller?.updater else { return }
        updater.automaticallyChecksForUpdates = policy.checksAutomatically
        updater.automaticallyDownloadsUpdates = policy.downloadsAutomatically
        // A pending update follows a policy change straight away.
        if installNow != nil {
            handleReadyUpdate()
        }
    }

    private func handleReadyUpdate() {
        switch settings.settings.updates.policy {
        case .automatic:
            installReadyUpdate()
        case .whenIdle:
            installIfIdle()
            guard installNow != nil, idleTimer == nil else { return }
            idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.installIfIdle() }
            }
        case .ask, .manual:
            // Leave it to install when the app quits.
            idleTimer?.invalidate()
            idleTimer = nil
        }
    }

    private func installIfIdle() {
        if idleCheck.isIdle(terminals: terminals(), isInUse: isInUse()) {
            installReadyUpdate()
        }
    }
}

// MARK: - Sparkle delegates

extension UpdateController: SPUUpdaterDelegate {
    /// Lets the update feed be pointed elsewhere for testing.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        ProcessInfo.processInfo.environment["TOPNOTCHSH_UPDATE_FEED"]
    }

    /// Called when an automatically downloaded update is ready. Without our
    /// help it would only install when the app quits, which a menu-bar app
    /// rarely does.
    nonisolated func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        MainActor.assumeIsolated {
            readyVersion = item.displayVersionString
            installNow = immediateInstallHandler
            handleReadyUpdate()
            return settings.settings.updates.policy.downloadsAutomatically
        }
    }
}

extension UpdateController: SPUStandardUserDriverDelegate {
    /// The app lives in the menu bar, so update alerts must be brought forward.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard handleShowingUpdate else { return }
        MainActor.assumeIsolated {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { ActivationPolicy.refresh() }
    }
}
