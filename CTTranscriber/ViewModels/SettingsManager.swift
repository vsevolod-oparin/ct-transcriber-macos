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

    // MARK: - Theme

    var colorScheme: ColorScheme? {
        switch settings.general.theme {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
