import SwiftUI

struct SettingsView: View {
    @Bindable var settingsManager: SettingsManager

    var body: some View {
        TabView {
            GeneralSettingsTab(settings: $settingsManager.settings.general)
                .tabItem { Label("General", systemImage: "gear") }

            TranscriptionSettingsTab(settings: $settingsManager.settings.transcription)
                .tabItem { Label("Transcription", systemImage: "waveform") }

            LLMSettingsTab(settings: $settingsManager.settings.llm)
                .tabItem { Label("LLM", systemImage: "brain") }
        }
        .frame(width: 520, height: 480)
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

    var body: some View {
        VStack(spacing: 0) {
            // Provider selector + add/remove
            HStack {
                Picker("Provider", selection: $settings.activeProviderID) {
                    ForEach(settings.providers) { provider in
                        Text(provider.name).tag(provider.id)
                    }
                }

                Button(action: addProvider) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add provider")

                Button(action: removeActiveProvider) {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .help("Remove provider")
                .disabled(settings.providers.count <= 1)
            }
            .padding(.horizontal)
            .padding(.top, 8)

            // Active provider config
            if let index = activeProviderIndex {
                ProviderConfigEditor(
                    config: $settings.providers[index]
                )
            }
        }
    }

    private var activeProviderIndex: Int? {
        settings.providers.firstIndex { $0.id == settings.activeProviderID }
    }

    private func addProvider() {
        let newProvider = ProviderConfig(
            id: UUID(),
            name: "New Provider",
            apiType: .openaiCompatible,
            baseURL: "https://",
            completionsPath: "v1/chat/completions",
            modelsPath: "v1/models",
            defaultModel: "",
            fallbackModels: [],
            temperature: 0.7,
            maxTokens: 4096,
            apiKey: "",
            extraHeaders: [:]
        )
        settings.providers.append(newProvider)
        settings.activeProviderID = newProvider.id
    }

    private func removeActiveProvider() {
        guard settings.providers.count > 1 else { return }
        settings.providers.removeAll { $0.id == settings.activeProviderID }
        settings.activeProviderID = settings.providers.first!.id
    }
}

// MARK: - Provider Config Editor

private struct ProviderConfigEditor: View {
    @Binding var config: ProviderConfig
    @State private var availableModels: [String] = []
    @State private var isFetchingModels: Bool = false
    @State private var fallbackModelsText: String = ""
    @State private var extraHeadersText: String = ""

    private static let minTemperature = 0.0
    private static let maxTemperature = 2.0
    private static let minMaxTokens = 1

    var body: some View {
        Form {
            Section("Provider") {
                TextField("Name", text: $config.name)

                Picker("API Type", selection: $config.apiType) {
                    ForEach(LLMApiType.allCases) { apiType in
                        Text(apiType.rawValue).tag(apiType)
                    }
                }
            }

            Section("Endpoints") {
                TextField("Base URL", text: $config.baseURL)
                TextField("Completions Path", text: $config.completionsPath)
                TextField("Models Path (empty = no fetch)", text: $config.modelsPath)
            }

            Section("Authentication") {
                SecureField("API Key", text: $config.apiKey)
                    .onSubmit { fetchModels() }
            }

            Section("Extra Headers") {
                TextField("One per line: Header-Name: value", text: $extraHeadersText, axis: .vertical)
                    .lineLimit(2...5)
                    .font(.system(.body, design: .monospaced))
                    .onChange(of: extraHeadersText) { _, newValue in
                        config.extraHeaders = parseHeaders(newValue)
                    }
            }

            Section("Model") {
                HStack {
                    if availableModels.isEmpty {
                        TextField("Default Model", text: $config.defaultModel)
                    } else {
                        Picker("Default Model", selection: $config.defaultModel) {
                            ForEach(availableModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                            if !config.defaultModel.isEmpty && !availableModels.contains(config.defaultModel) {
                                Text(config.defaultModel).tag(config.defaultModel)
                            }
                        }
                    }

                    if isFetchingModels {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Button(action: fetchModels) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Fetch models from API")
                    .disabled(config.apiKey.isEmpty)
                }

                TextField("Fallback Models (comma-separated)", text: $fallbackModelsText)
                    .onChange(of: fallbackModelsText) { _, newValue in
                        config.fallbackModels = newValue
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                    }
            }

            Section("Defaults") {
                HStack {
                    Text("Temperature")
                    Spacer()
                    TextField("", value: $config.temperature, format: .number.precision(.fractionLength(1)))
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                }
                if config.temperature < Self.minTemperature || config.temperature > Self.maxTemperature {
                    Text("Temperature must be between \(Self.minTemperature) and \(Self.maxTemperature)")
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                HStack {
                    Text("Max Tokens")
                    Spacer()
                    TextField("", value: $config.maxTokens, format: .number)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                }
                if config.maxTokens < Self.minMaxTokens {
                    Text("Max tokens must be at least \(Self.minMaxTokens)")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { loadProviderState() }
        .onChange(of: config.id) { _, _ in loadProviderState() }
    }

    private func loadProviderState() {
        fallbackModelsText = config.fallbackModels.joined(separator: ", ")
        extraHeadersText = formatHeaders(config.extraHeaders)
        availableModels = config.fallbackModels
        fetchModels()
    }

    private func formatHeaders(_ headers: [String: String]) -> String {
        headers.sorted(by: { $0.key < $1.key })
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
    }

    private func parseHeaders(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty {
                result[key] = value
            }
        }
        return result
    }

    private func fetchModels() {
        guard !config.apiKey.isEmpty, !config.modelsPath.isEmpty else {
            availableModels = config.fallbackModels
            return
        }
        isFetchingModels = true
        Task {
            let models = await ModelListService.fetchModels(
                provider: config,
                apiKey: config.apiKey
            )
            await MainActor.run {
                availableModels = models
                if !models.contains(config.defaultModel), let first = models.first {
                    config.defaultModel = first
                }
                isFetchingModels = false
            }
        }
    }
}
