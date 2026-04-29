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

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
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

        var settings: AppSettings
        if FileManager.default.fileExists(atPath: url.path) {
            settings = decode(from: url) ?? loadBundledDefaults()
        } else {
            settings = loadBundledDefaults()
        }

        if migrateAutoTitleModels(&settings) {
            save(settings)
        }
        return settings
    }

    /// Sets autoTitleModel for providers that don't have one yet,
    /// picking a known fast non-thinking model from their fallback list or base URL.
    @discardableResult
    private static func migrateAutoTitleModels(_ settings: inout AppSettings) -> Bool {
        var changed = false
        for i in settings.llm.providers.indices {
            guard settings.llm.providers[i].autoTitleModel == nil else { continue }
            if let fast = suggestAutoTitleModel(for: settings.llm.providers[i]) {
                settings.llm.providers[i].autoTitleModel = fast
                changed = true
            }
        }
        return changed
    }

    private static func suggestAutoTitleModel(for provider: ProviderConfig) -> String? {
        let url = provider.baseURL.lowercased()
        let fallbacks = provider.fallbackModels
        let model = provider.defaultModel.lowercased()

        if url.contains("z.ai") || url.contains("bigmodel.cn") {
            return fallbacks.first { $0.lowercased().contains("turbo") } ?? "glm-5-turbo"
        }
        if url.contains("openai.com") {
            return fallbacks.first { $0.lowercased().contains("mini") } ?? "gpt-4o-mini"
        }
        if url.contains("anthropic.com") {
            return fallbacks.first { $0.lowercased().contains("haiku") } ?? "claude-haiku-4-5-20251001"
        }
        if url.contains("deepseek.com") {
            if model == "deepseek-reasoner" {
                return "deepseek-chat"
            }
            return nil
        }
        if url.contains("dashscope.aliyuncs.com") {
            return fallbacks.first { $0.lowercased().contains("turbo") } ?? "qwen-turbo"
        }
        return nil
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
            AppLogger.error("Failed to save settings: \(error)", category: "settings")
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
            return decodeMinimalDefaults()
        }
        guard let settings = decode(from: url) else {
            AppLogger.error("Failed to decode bundled \(bundledDefaultsFileName).json", category: "settings")
            return decodeMinimalDefaults()
        }
        return settings
    }

    private static func decodeMinimalDefaults() -> AppSettings {
        if let settings = try? JSONDecoder().decode(AppSettings.self, from: Data(minimalDefaultsJSON.utf8)) {
            return settings
        }
        AppLogger.error("Failed to decode minimal defaults JSON — using hardcoded fallback", category: "settings")
        return AppSettings(
            general: GeneralSettings(),
            transcription: TranscriptionSettings(
                modelsDirectory: "", selectedModelID: "", models: [],
                beamSize: 4, temperature: 1.0, language: "",
                vadFilter: true, conditionOnPreviousText: false,
                skipTimestamps: false, maxParallelTranscriptions: 1
            ),
            llm: LLMSettings(activeProviderID: UUID(), providers: [])
        )
    }

    private static let minimalDefaultsJSON = """
    {"general":{"theme":"system","fontScale":1.0},"transcription":{"modelsDirectory":"","selectedModelID":"","models":[],"beamSize":4,"temperature":1.0,"language":"","vadFilter":true,"conditionOnPreviousText":false,"skipTimestamps":false,"maxParallelTranscriptions":1},"llm":{"activeProviderID":"00000000-0000-0000-0000-000000000000","providers":[]}}
    """

    private static func decode(from url: URL) -> AppSettings? {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            AppLogger.error("Failed to decode settings from \(url.path): \(error)", category: "settings")
            return nil
        }
    }
}
