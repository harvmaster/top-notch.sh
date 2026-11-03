import Foundation

/// Stores a `Codable` value as JSON in `UserDefaults`.
///
/// Loading deep-merges the stored document over the encoded fallback, so keys
/// added in newer versions pick up their defaults instead of failing to decode.
struct JSONDefaults<Value: Codable> {
    let key: String
    var defaults: UserDefaults = .standard

    func load(fallback: Value) -> Value {
        guard let storedData = defaults.data(forKey: key) else { return fallback }

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        guard let stored = try? JSONSerialization.jsonObject(with: storedData),
              let fallbackData = try? encoder.encode(fallback),
              let base = try? JSONSerialization.jsonObject(with: fallbackData),
              let mergedData = try? JSONSerialization.data(withJSONObject: Self.merge(base, stored)),
              let value = try? decoder.decode(Value.self, from: mergedData) else {
            return (try? decoder.decode(Value.self, from: storedData)) ?? fallback
        }
        return value
    }

    func save(_ value: Value) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    /// Objects merge key-by-key; any other value in `overlay` replaces `base`.
    static func merge(_ base: Any, _ overlay: Any) -> Any {
        guard let baseObject = base as? [String: Any],
              let overlayObject = overlay as? [String: Any] else {
            return overlay
        }
        return baseObject.merging(overlayObject) { merge($0, $1) }
    }
}
