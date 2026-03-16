import SwiftUI

struct SettingsView: View {
    @Bindable var settingsManager: SettingsManager

    var body: some View {
        TabView {
            GeneralSettingsTab(settings: $settingsManager.settings.general)
                .tabItem { Label("General", systemImage: "gear") }

            TranscriptionSettingsTab(settings: $settingsManager.settings.transcription)
                .tabItem { Label("Transcription", systemImage: "waveform") }

            LLMSettingsTab(settings: $settingsManager.settings.llm, settingsManager: settingsManager)
                .tabItem { Label("LLM", systemImage: "brain") }
        }
        .frame(width: 480, height: 380)
    }
}

// MARK: - General Tab

private struct GeneralSettingsTab: View {
    @Binding var settings: GeneralSettings

    var body: some View {
        Form {
            Picker("Theme", selection: $settings.theme) {
                ForEach(GeneralSettings.AppTheme.allCases, id: \.self) { theme in
                    Text(theme.rawValue.capitalized).tag(theme)
                }
            }
            .pickerStyle(.segmented)
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Transcription Tab

private struct TranscriptionSettingsTab: View {
    @Binding var settings: TranscriptionSettings

    private static let minBeamSize = 1
    private static let maxBeamSize = 20
    private static let minTemperature = 0.0
    private static let maxTemperature = 2.0

    var body: some View {
        Form {
            Picker("Model", selection: $settings.model) {
                ForEach(TranscriptionSettings.WhisperModel.allCases) { model in
                    Text(model.displayName).tag(model)
                }
            }

            Picker("Device", selection: $settings.device) {
                Text("Metal GPU (mps)").tag("mps")
                Text("CPU").tag("cpu")
            }

            HStack {
                Text("Beam Size")
                Spacer()
                TextField("", value: $settings.beamSize, format: .number)
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                Stepper("", value: $settings.beamSize,
                        in: Self.minBeamSize...Self.maxBeamSize)
                    .labelsHidden()
            }
            if settings.beamSize < Self.minBeamSize || settings.beamSize > Self.maxBeamSize {
                Text("Beam size must be between \(Self.minBeamSize) and \(Self.maxBeamSize)")
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            HStack {
                Text("Temperature")
                Spacer()
                TextField("", value: $settings.temperature, format: .number.precision(.fractionLength(1)))
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
            }
            if settings.temperature < Self.minTemperature || settings.temperature > Self.maxTemperature {
                Text("Temperature must be between \(Self.minTemperature) and \(Self.maxTemperature)")
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            TextField("Language (empty = auto-detect)", text: $settings.language)

            Toggle("VAD Filter (skip silence)", isOn: $settings.vadFilter)

            Toggle("Condition on Previous Text", isOn: $settings.conditionOnPreviousText)
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - LLM Tab

private struct LLMSettingsTab: View {
    @Binding var settings: LLMSettings
    var settingsManager: SettingsManager
    @State private var apiKeyText: String = ""

    private static let minTemperature = 0.0
    private static let maxTemperature = 2.0
    private static let minMaxTokens = 1

    var body: some View {
        Form {
            Picker("Provider", selection: $settings.provider) {
                ForEach(LLMSettings.LLMProvider.allCases) { provider in
                    Text(provider.rawValue).tag(provider)
                }
            }
            .onChange(of: settings.provider) { _, newProvider in
                settings.baseURL = newProvider.defaultBaseURL
                apiKeyText = settingsManager.apiKey(for: newProvider)
            }

            TextField("Base URL", text: $settings.baseURL)

            SecureField("API Key", text: $apiKeyText)
                .onChange(of: apiKeyText) { _, newValue in
                    settingsManager.setApiKey(newValue, for: settings.provider)
                }

            TextField("Model", text: $settings.modelName)

            HStack {
                Text("Temperature")
                Spacer()
                TextField("", value: $settings.temperature, format: .number.precision(.fractionLength(1)))
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
            }
            if settings.temperature < Self.minTemperature || settings.temperature > Self.maxTemperature {
                Text("Temperature must be between \(Self.minTemperature) and \(Self.maxTemperature)")
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            HStack {
                Text("Max Tokens")
                Spacer()
                TextField("", value: $settings.maxTokens, format: .number)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
            }
            if settings.maxTokens < Self.minMaxTokens {
                Text("Max tokens must be at least \(Self.minMaxTokens)")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            apiKeyText = settingsManager.apiKey(for: settings.provider)
        }
    }
}
