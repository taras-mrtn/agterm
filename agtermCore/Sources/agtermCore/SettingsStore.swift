import Foundation

/// Reads and writes `AppSettings` as JSON on disk, in the same directory as the workspace
/// snapshot (so the `AGTERM_STATE_DIR` test override applies). Mirrors `PersistenceStore`.
///
/// Recovery contract: a missing file or corrupt JSON resolves to default `AppSettings()` —
/// `load()` never throws to the caller. `save(_:)` writes atomically (temp file then replace).
public struct SettingsStore {
    private let directory: URL
    private let fileName = "settings.json"

    private var fileURL: URL { directory.appendingPathComponent(fileName) }

    /// Creates a store rooted at `directory`, defaulting to the app's Application Support directory
    /// (the same root `PersistenceStore` uses).
    public init(directory: URL = PersistenceStore.defaultDirectory) {
        self.directory = directory
    }

    /// Loads the settings, recovering defaults on any failure (missing file, unreadable data,
    /// corrupt JSON).
    public func load() -> AppSettings {
        guard let data = try? Data(contentsOf: fileURL) else { return AppSettings() }
        guard let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return settings
    }

    /// Writes the settings atomically, creating the directory if needed.
    public func save(_ settings: AppSettings) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: fileURL, options: .atomic)
    }
}
