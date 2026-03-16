import Foundation
import SwiftUI

@Observable
final class SettingsManager {
    var settings: AppSettings {
        didSet {
            if settings != oldValue {
                SettingsStorage.save(settings)
            }
        }
    }

    init() {
        self.settings = SettingsStorage.load()
    }

    // MARK: - API Key accessors (Keychain-backed)

    func apiKey(for provider: LLMSettings.LLMProvider) -> String {
        KeychainService.load(key: keychainKey(for: provider)) ?? ""
    }

    func setApiKey(_ key: String, for provider: LLMSettings.LLMProvider) {
        if key.isEmpty {
            KeychainService.delete(key: keychainKey(for: provider))
        } else {
            KeychainService.save(key: keychainKey(for: provider), value: key)
        }
    }

    private func keychainKey(for provider: LLMSettings.LLMProvider) -> String {
        "apikey-\(provider.rawValue)"
    }

    // MARK: - Theme

    var colorScheme: ColorScheme? {
        switch settings.general.theme {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
