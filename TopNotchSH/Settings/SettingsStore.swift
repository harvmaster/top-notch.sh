import Combine
import SwiftUI

/// Single source of truth for `AppSettings`. Every mutation is persisted.
@MainActor
final class SettingsStore: ObservableObject {
    @Published private(set) var settings: AppSettings {
        didSet { changes.send(settings) }
    }

    /// Unlike `$settings`, which fires *before* the property changes, this
    /// fires after, so subscribers can read `settings` and see the new value.
    private let changes: CurrentValueSubject<AppSettings, Never>
    private let persistence: JSONDefaults<AppSettings>

    init(defaults: UserDefaults = .standard) {
        persistence = JSONDefaults(key: "settings", defaults: defaults)
        let settings = persistence.load(fallback: AppSettings())
        self.settings = settings
        changes = CurrentValueSubject(settings)
    }

    func update(_ mutate: (inout AppSettings) -> Void) {
        var updated = settings
        mutate(&updated)
        guard updated != settings else { return }
        settings = updated
        persistence.save(updated)
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
