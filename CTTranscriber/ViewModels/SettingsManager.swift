import Foundation
import SwiftUI

// MARK: - Font Scale Environment Key

private struct FontScaleKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}

extension EnvironmentValues {
    var fontScale: Double {
        get { self[FontScaleKey.self] }
        set { self[FontScaleKey.self] = newValue }
    }
}

/// Scaled font sizes based on macOS system defaults × fontScale.
struct ScaledFont {
    let scale: Double
    private var s: CGFloat { CGFloat(scale) }
    private static let base = CGFloat(NSFont.systemFontSize)

    var body: Font      { .system(size: Self.base * s) }
    var headline: Font  { .system(size: Self.base * s, weight: .semibold) }
    var caption: Font   { .system(size: (Self.base - 2) * s) }
    var caption2: Font  { .system(size: (Self.base - 4) * s) }
    var title: Font     { .system(size: (Self.base + 8) * s, weight: .bold) }
    var title2: Font    { .system(size: (Self.base + 4) * s) }
    var title3: Font    { .system(size: (Self.base + 2) * s) }
}

extension View {
    /// Access scaled fonts from environment. Usage: `let sf = scaledFonts`
    func scaledFonts(from scale: Double) -> ScaledFont {
        ScaledFont(scale: scale)
    }
}

/// A property wrapper-style helper for use inside View bodies.
/// Usage: `@Environment(\.fontScale) private var fontScale` then `ScaledFont(scale: fontScale).headline`
extension Font {
    static func scaled(_ style: @escaping (ScaledFont) -> Font, scale: Double) -> Font {
        ScaledFont(scale: scale).body // placeholder — use ScaledFont directly instead
    }
}

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

    // MARK: - Font Scale

    private static let fontScaleStep = 0.1
    private static let minFontScale = 0.7
    private static let maxFontScale = 2.0

    var fontScale: Double {
        settings.general.fontScale
    }

    func increaseFontScale() {
        settings.general.fontScale = min(Self.maxFontScale, settings.general.fontScale + Self.fontScaleStep)
    }

    func decreaseFontScale() {
        settings.general.fontScale = max(Self.minFontScale, settings.general.fontScale - Self.fontScaleStep)
    }
}
