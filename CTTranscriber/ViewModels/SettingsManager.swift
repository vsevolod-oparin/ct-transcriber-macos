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

    // MARK: - Active provider convenience

    var activeProvider: ProviderConfig? {
        settings.llm.activeProvider
    }

    // MARK: - API Key accessors (Keychain-backed, keyed by provider ID)

    func apiKey(for provider: ProviderConfig) -> String {
        KeychainService.load(key: keychainKey(for: provider)) ?? ""
    }

    func setApiKey(_ key: String, for provider: ProviderConfig) {
        if key.isEmpty {
            KeychainService.delete(key: keychainKey(for: provider))
        } else {
            KeychainService.save(key: keychainKey(for: provider), value: key)
        }
    }

    private func keychainKey(for provider: ProviderConfig) -> String {
        "apikey-\(provider.id.uuidString)"
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
