import Combine
import SwiftUI

/// Single source of truth for `AppSettings`, persisted to `settings.json`.
/// Every mutation is saved, and hand edits to the file apply immediately.
@MainActor
final class SettingsStore: ObservableObject {
    @Published private(set) var settings: AppSettings {
        didSet { changes.send(settings) }
    }

    /// Unlike `$settings`, which fires *before* the property changes, this
    /// fires after, so subscribers can read `settings` and see the new value.
    private let changes: CurrentValueSubject<AppSettings, Never>
    private let file: ConfigFile<AppSettings>
    private var watcher: DirectoryWatcher?

    init(file: ConfigFile<AppSettings>, watchesForEdits: Bool = false) {
        self.file = file
        let settings = file.loadOrBackUp(defaults: AppSettings())
        self.settings = settings
        changes = CurrentValueSubject(settings)
        if watchesForEdits {
            watcher = DirectoryWatcher(url: file.url.deletingLastPathComponent()) { [weak self] in
                self?.reloadFromDisk()
            }
        }
    }

    func update(_ mutate: (inout AppSettings) -> Void) {
        var updated = settings
        mutate(&updated)
        guard updated != settings else { return }
        settings = updated
        file.save(updated)
    }

    /// Picks up hand edits. A half-written or invalid file is ignored, so a
    /// typo never resets everything to defaults.
    func reloadFromDisk() {
        guard let loaded = try? file.load(defaults: AppSettings()), loaded != settings else { return }
        settings = loaded
    }

    func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { value in self.update { $0[keyPath: keyPath] = value } }
        )
    }

    /// Emits the value at `keyPath` whenever it changes (including the current value).
    func publisher<Value: Equatable>(_ keyPath: KeyPath<AppSettings, Value>) -> AnyPublisher<Value, Never> {
        changes.map(keyPath).removeDuplicates().eraseToAnyPublisher()
    }
}
