import Foundation

/// Where Top NotchSH keeps its configuration: `~/.config/top-notchsh`.
///
/// Each concern is a separate, human-editable JSON file:
/// `settings.json`, `workspaces.json` and `displays.json`.
struct ConfigDirectory {
    let url: URL

    static let standard = ConfigDirectory(
        url: FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".config/top-notchsh", directoryHint: .isDirectory)
    )

    var settings: ConfigFile<AppSettings> { file("settings.json") }
    var workspaces: ConfigFile<[WorkspaceRecord]> { file("workspaces.json") }
    var displays: ConfigFile<[ScreenID: WorkspaceID]> { file("displays.json") }

    private func file<Value>(_ name: String) -> ConfigFile<Value> {
        ConfigFile(url: url.appending(path: name, directoryHint: .notDirectory))
    }

    /// Moves configuration written by earlier builds (in UserDefaults) into
    /// files, once. Existing files always win.
    func migrateFromUserDefaults(_ defaults: UserDefaults = .standard) {
        let legacy: [(key: String, file: URL)] = [
            ("settings", settings.url),
            ("workspaces", workspaces.url),
            ("screenAssignments", displays.url),
        ]
        for (key, file) in legacy {
            guard let data = defaults.data(forKey: key) else { continue }
            if !FileManager.default.fileExists(atPath: file.path),
               let object = try? JSONSerialization.jsonObject(with: data) {
                try? ConfigFile<AnyCodableJSON>.write(object, to: file)
            }
            defaults.removeObject(forKey: key)
        }
    }
}

/// One JSON configuration file.
///
/// Loading deep-merges the file over the encoded defaults, so keys added in
/// newer versions (or left out by hand) pick up their defaults. Writes are
/// atomic, pretty-printed and key-sorted so the file diffs cleanly.
struct ConfigFile<Value: Codable> {
    let url: URL

    enum LoadError: Error {
        case invalid(underlying: Error)
    }

    /// The stored value, `nil` if there is no file. Throws if the file exists
    /// but can't be read or decoded.
    func load(defaults: Value) throws -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            let stored = try JSONSerialization.jsonObject(with: data)
            let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(defaults))
            let merged = try JSONSerialization.data(withJSONObject: Self.merge(base, stored))
            return try JSONDecoder().decode(Value.self, from: merged)
        } catch {
            throw LoadError.invalid(underlying: error)
        }
    }

    /// Loads the value, falling back to `defaults`. An invalid file is moved
    /// aside (`settings.json.invalid`) rather than being overwritten later.
    func loadOrBackUp(defaults: Value) -> Value {
        do {
            return try load(defaults: defaults) ?? defaults
        } catch {
            let backup = url.appendingPathExtension("invalid")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            NSLog("Top NotchSH: %@ could not be read and was moved to %@: %@", url.path, backup.lastPathComponent, String(describing: error))
            return defaults
        }
    }

    func save(_ value: Value) {
        do {
            let data = try JSONEncoder().encode(value)
            try Self.write(JSONSerialization.jsonObject(with: data), to: url)
        } catch {
            NSLog("Top NotchSH: failed to save %@: %@", url.path, String(describing: error))
        }
    }

    static func write(_ object: Any, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
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

/// Placeholder type for writing raw JSON objects through `ConfigFile.write`.
struct AnyCodableJSON: Codable {}

/// Calls back when files in a directory change (including atomic replaces),
/// so hand edits to the config take effect immediately.
final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject?

    init?(url: URL, onChange: @escaping @MainActor () -> Void) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { onChange() } }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    deinit {
        source?.cancel()
    }
}
