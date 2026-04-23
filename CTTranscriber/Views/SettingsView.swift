import SwiftUI

struct SettingsView: View {
    @Bindable var settingsManager: SettingsManager
    var modelManager: ModelManager
    @Environment(\.fontScale) private var fontScale

    var body: some View {
        let s = CGFloat(fontScale)
        TabView {
            GeneralSettingsTab(settings: $settingsManager.settings.general)
                .tabItem { Label("General", systemImage: "gear") }

            TranscriptionSettingsTab(settings: $settingsManager.settings.transcription, modelManager: modelManager)
                .tabItem { Label("Transcription", systemImage: "waveform") }

            LLMSettingsTab(settings: $settingsManager.settings.llm)
                .tabItem { Label("LLM", systemImage: "brain") }
        }
        .frame(width: 520 * s, height: 480 * s)
    }
}

// MARK: - General Tab

private struct GeneralSettingsTab: View {
    @Binding var settings: GeneralSettings
    @Environment(\.fontScale) private var fontScale

    private static let minFontScale = 0.7
    private static let maxFontScale = 2.0
    private static let fontScaleStep = 0.1

    var body: some View {
        Form {
            Picker("Theme", selection: $settings.theme) {
                ForEach(GeneralSettings.AppTheme.allCases, id: \.self) { theme in
                    Text(theme.rawValue.capitalized).tag(theme)
                }
            }
            .pickerStyle(.segmented)

            Section("Font Size") {
                HStack {
                    Text("A")
                        .font(ScaledFont(scale: fontScale).caption)
                    Slider(value: $settings.fontScale,
                           in: Self.minFontScale...Self.maxFontScale,
                           step: Self.fontScaleStep)
                    Text("A")
                        .font(ScaledFont(scale: fontScale).title)
                    Text("\(Int(settings.fontScale * 100))%")
                        .monospacedDigit()
                        .frame(width: 45 * CGFloat(fontScale), alignment: .trailing)
                }
                HStack {
                    Button("Reset") {
                        settings.fontScale = 1.0
                    }
                    .disabled(settings.fontScale == 1.0)
                    Spacer()
                    Text("Cmd+\u{2795} / Cmd+\u{2796} to adjust")
                        .font(ScaledFont(scale: fontScale).caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Transcription Tab

private struct TranscriptionSettingsTab: View {
    @Binding var settings: TranscriptionSettings
    var modelManager: ModelManager
    @State private var showModelManager = false
    @Environment(\.fontScale) private var fontScale

    private var fieldWidth: CGFloat { 60 * CGFloat(fontScale) }
    private var narrowFieldWidth: CGFloat { 40 * CGFloat(fontScale) }

    private static let minBeamSize = 1
    private static let maxBeamSize = 20
    private static let minTemperature = 0.0
    private static let maxTemperature = 2.0

    var body: some View {
        Form {
            Section("Model") {
                HStack {
                    Picker("Whisper Model", selection: $settings.selectedModelID) {
                        ForEach(settings.models) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }

                    Button("Manage Models...") {
                        showModelManager = true
                    }
                }
            }
            .sheet(isPresented: $showModelManager) {
                ModelManagerView(modelManager: modelManager)
            }

            Section("Inference") {
                HStack {
                    Text("Beam Size")
                    Spacer()
                    TextField("", value: $settings.beamSize, format: .number)
                        .frame(width: fieldWidth)
                        .multilineTextAlignment(.trailing)
                    Stepper("", value: $settings.beamSize,
                            in: Self.minBeamSize...Self.maxBeamSize)
                        .labelsHidden()
                }
                if settings.beamSize < Self.minBeamSize || settings.beamSize > Self.maxBeamSize {
                    Text("Beam size must be between \(Self.minBeamSize) and \(Self.maxBeamSize)")
                        .foregroundStyle(.red)
                        .font(ScaledFont(scale: fontScale).caption)
                }

                HStack {
                    Text("Temperature")
                    Spacer()
                    TextField("", value: $settings.temperature, format: .number.precision(.fractionLength(1)))
                        .frame(width: fieldWidth)
                        .multilineTextAlignment(.trailing)
                }
                if settings.temperature < Self.minTemperature || settings.temperature > Self.maxTemperature {
                    Text("Temperature must be between \(Self.minTemperature) and \(Self.maxTemperature)")
                        .foregroundStyle(.red)
                        .font(ScaledFont(scale: fontScale).caption)
                }

                TextField("Language (empty = auto-detect)", text: $settings.language)

                Toggle("VAD Filter (skip silence)", isOn: $settings.vadFilter)

                Toggle("Condition on Previous Text", isOn: $settings.conditionOnPreviousText)

                Toggle("Skip Timestamps (faster)", isOn: $settings.skipTimestamps)

                HStack {
                    Text("Max Parallel Transcriptions")
                    Spacer()
                    TextField("", value: $settings.maxParallelTranscriptions, format: .number)
                        .frame(width: narrowFieldWidth)
                        .multilineTextAlignment(.trailing)
                    Stepper("", value: $settings.maxParallelTranscriptions, in: 1...4)
                        .labelsHidden()
                }
            }

            Section("Storage") {
                HStack {
                    TextField("Models Directory", text: $settings.modelsDirectory)
                    Button("Browse...") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            settings.modelsDirectory = url.path
                        }
                    }
                }
                if settings.modelsDirectory.isEmpty {
                    Text("Default: ~/Library/Application Support/CTTranscriber/models/")
                        .font(ScaledFont(scale: fontScale).caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - LLM Tab

private struct LLMSettingsTab: View {
    @Binding var settings: LLMSettings
    @Environment(\.fontScale) private var fontScale

    var body: some View {
        VStack(spacing: 0) {
            // Active provider config (includes provider selector at the top)
            if let index = activeProviderIndex {
                ProviderConfigEditor(
                    config: $settings.providers[index],
                    allProviders: $settings.providers,
                    activeProviderID: $settings.activeProviderID,
                    onAdd: addProvider,
                    onRemove: removeActiveProvider,
                    canRemove: settings.providers.count > 1
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
            extraHeaders: [:],
            autoTitleModel: nil
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
    @Binding var allProviders: [ProviderConfig]
    @Binding var activeProviderID: UUID
    var onAdd: () -> Void
    var onRemove: () -> Void
    var canRemove: Bool
    @State private var availableModels: [String] = []
    @State private var isFetchingModels: Bool = false
    @State private var fallbackModelsText: String = ""
    @Environment(\.fontScale) private var fontScale

    private var fieldWidth: CGFloat { 60 * CGFloat(fontScale) }
    private var wideFieldWidth: CGFloat { 80 * CGFloat(fontScale) }
    @State private var extraHeadersText: String = ""
    @State private var testResult: TestConnectionResult = .idle

    enum TestConnectionResult: Equatable {
        case idle
        case testing
        case success
        case failure(String)
    }

    private static let minTemperature = 0.0
    private static let maxTemperature = 2.0
    private static let minMaxTokens = 1

    var body: some View {
        Form {
            Section {
                HStack {
                    Picker("Provider", selection: $activeProviderID) {
                        ForEach(allProviders) { provider in
                            Text(provider.name).tag(provider.id)
                        }
                    }

                    Button(action: onAdd) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("Add provider")

                    Button(action: onRemove) {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove provider")
                    .disabled(!canRemove)
                }
            }

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
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .onSubmit { fetchModels() }

                HStack {
                    Button("Test Connection") { testConnection() }
                        .disabled(config.apiKey.isEmpty || testResult == .testing)

                    switch testResult {
                    case .idle:
                        EmptyView()
                    case .testing:
                        ProgressView()
                            .controlSize(.small)
                    case .success:
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .font(ScaledFont(scale: fontScale).caption)
                            .foregroundStyle(.green)
                    case .failure(let msg):
                        Text(msg)
                            .font(ScaledFont(scale: fontScale).caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
            }

            Section("Extra Headers") {
                TextField("One per line: Header-Name: value", text: $extraHeadersText, axis: .vertical)
                    .lineLimit(2...5)
                    .font(.system(size: CGFloat(NSFont.systemFontSize) * CGFloat(fontScale), design: .monospaced))
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

                HStack {
                    let autoTitleBinding = Binding<String>(
                        get: { config.autoTitleModel ?? "" },
                        set: { config.autoTitleModel = $0.isEmpty ? nil : $0 }
                    )
                    if availableModels.isEmpty {
                        TextField("Auto-Title Model (optional)", text: autoTitleBinding)
                    } else {
                        Picker("Auto-Title Model", selection: autoTitleBinding) {
                            Text("Same as default").tag("")
                            ForEach(availableModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                            if let m = config.autoTitleModel, !m.isEmpty, !availableModels.contains(m) {
                                Text(m).tag(m)
                            }
                        }
                    }
                }
                Text("Fast non-thinking model recommended. Falls back to default model if empty.")
                    .font(ScaledFont(scale: fontScale).caption2)
                    .foregroundStyle(.tertiary)
            }

            Section("Defaults") {
                HStack {
                    Text("Temperature")
                    Spacer()
                    TextField("", value: $config.temperature, format: .number.precision(.fractionLength(1)))
                        .frame(width: fieldWidth)
                        .multilineTextAlignment(.trailing)
                }
                if config.temperature < Self.minTemperature || config.temperature > Self.maxTemperature {
                    Text("Temperature must be between \(Self.minTemperature) and \(Self.maxTemperature)")
                        .foregroundStyle(.red)
                        .font(ScaledFont(scale: fontScale).caption)
                }

                HStack {
                    Text("Max Tokens")
                    Spacer()
                    TextField("", value: $config.maxTokens, format: .number)
                        .frame(width: wideFieldWidth)
                        .multilineTextAlignment(.trailing)
                }
                if config.maxTokens < Self.minMaxTokens {
                    Text("Max tokens must be at least \(Self.minMaxTokens)")
                        .foregroundStyle(.red)
                        .font(ScaledFont(scale: fontScale).caption)
                }
            }

            Section("System Prompt") {
                let binding = Binding<String>(
                    get: { config.systemPrompt ?? "" },
                    set: { config.systemPrompt = $0.isEmpty ? nil : $0 }
                )
                TextEditor(text: binding)
                    .font(.system(size: CGFloat(NSFont.systemFontSize) * CGFloat(fontScale), design: .monospaced))
                    .frame(minHeight: 60, maxHeight: 120)
                Text("Sent as the first message in every conversation with this provider.")
                    .font(ScaledFont(scale: fontScale).caption2)
                    .foregroundStyle(.tertiary)
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
        testResult = .idle
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

    private func testConnection() {
        testResult = .testing
        let service = LLMServiceFactory.service(for: config)
        let messages = [ChatMessageDTO(role: "user", content: "Hi")]

        Task {
            do {
                let stream = service.streamCompletion(
                    messages: messages,
                    model: config.defaultModel,
                    temperature: 0.1,
                    maxTokens: 1,
                    baseURL: config.baseURL,
                    completionsPath: config.completionsPath,
                    apiKey: config.apiKey,
                    extraHeaders: config.extraHeaders
                )
                for try await _ in stream {
                    break // one token is enough
                }
                await MainActor.run {
                    testResult = .success
                }
            } catch {
                await MainActor.run {
                    testResult = .failure(error.localizedDescription)
                }
            }
        }
    }
}
