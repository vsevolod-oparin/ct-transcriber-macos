import Foundation

enum SettingsStorage {
    private static let configDirectoryName = "ct-transcriber"
    private static let settingsFileName = "settings.json"

    static var configDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent(configDirectoryName, isDirectory: true)
    }

    static var settingsFileURL: URL {
        configDirectory.appendingPathComponent(settingsFileName)
    }

    static func load() -> AppSettings {
        let url = settingsFileURL

        guard FileManager.default.fileExists(atPath: url.path) else {
            return AppSettings()
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            return try decoder.decode(AppSettings.self, from: data)
        } catch {
            // Corrupted file — return defaults
            return AppSettings()
        }
    }

    static func save(_ settings: AppSettings) {
        let url = settingsFileURL
        let directory = configDirectory

        do {
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(settings)
            try data.write(to: url, options: .atomic)
        } catch {
            // Log but don't crash
            print("Failed to save settings: \(error)")
        }
    }
}
