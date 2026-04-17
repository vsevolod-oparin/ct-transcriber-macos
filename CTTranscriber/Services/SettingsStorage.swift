import Foundation

enum SettingsStorage {
    private static let configDirectoryName = "ct-transcriber"
    private static let settingsFileName = "settings.json"
    private static let bundledDefaultsFileName = "default-settings"

    static var configDirectory: URL {
        // Prefer ~/.config/ct-transcriber if ~/.config is writable.
        // Fall back to ~/Library/Application Support/CTTranscriber.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let xdgConfig = home.appendingPathComponent(".config", isDirectory: true)

        if FileManager.default.isWritableFile(atPath: xdgConfig.path) {
            return xdgConfig.appendingPathComponent(configDirectoryName, isDirectory: true)
        }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("CTTranscriber", isDirectory: true)
    }

    static var settingsFileURL: URL {
        configDirectory.appendingPathComponent(settingsFileName)
    }

    /// Loads settings from ~/.config/ct-transcriber/settings.json.
    /// On first launch (no file exists), copies the bundled default-settings.json
    /// to the config directory so the user has a shareable/editable file immediately.
    static func load() -> AppSettings {
        let url = settingsFileURL

        if FileManager.default.fileExists(atPath: url.path) {
            return decode(from: url) ?? loadBundledDefaults()
        }

        // First launch — copy bundled defaults to user config
        let defaults = loadBundledDefaults()
        save(defaults)
        return defaults
    }

    static func save(_ settings: AppSettings) {
        let directory = configDirectory

        do {
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(settings)
            try data.write(to: settingsFileURL, options: .atomic)
        } catch {
            print("Failed to save settings: \(error)")
        }
    }

    /// Resets settings to bundled defaults (re-copies the default file).
    static func resetToDefaults() -> AppSettings {
        let defaults = loadBundledDefaults()
        save(defaults)
        return defaults
    }

    // MARK: - Private

    private static func loadBundledDefaults() -> AppSettings {
        guard let url = Bundle.main.url(forResource: bundledDefaultsFileName, withExtension: "json") else {
            AppLogger.error("Bundled \(bundledDefaultsFileName).json missing from app resources", category: "settings")
            // Last resort: decode from inline minimal JSON
            return try! JSONDecoder().decode(AppSettings.self, from: Data(minimalDefaultsJSON.utf8))
        }
        guard let settings = decode(from: url) else {
            AppLogger.error("Failed to decode bundled \(bundledDefaultsFileName).json", category: "settings")
            return try! JSONDecoder().decode(AppSettings.self, from: Data(minimalDefaultsJSON.utf8))
        }
        return settings
    }

    private static let minimalDefaultsJSON = """
    {"general":{"theme":"system","fontScale":1.0},"transcription":{"modelsDirectory":"","selectedModelID":"","models":[],"beamSize":4,"temperature":1.0,"language":"","vadFilter":true,"conditionOnPreviousText":false,"skipTimestamps":false,"maxParallelTranscriptions":1},"llm":{"activeProviderID":"00000000-0000-0000-0000-000000000000","providers":[]}}
    """

    private static func decode(from url: URL) -> AppSettings? {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            print("Failed to decode settings from \(url.path): \(error)")
            return nil
        }
    }
}
