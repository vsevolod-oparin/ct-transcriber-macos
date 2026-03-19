import Foundation

/// Manages Whisper model downloads, conversions, and local storage.
@Observable
@MainActor
final class ModelManager {
    /// Status of each model keyed by model ID.
    private(set) var modelStatuses: [String: ModelStatus] = [:]
    private var activeTasks: [String: Task<Void, Never>] = [:]

    enum ModelStatus: Equatable {
        case notDownloaded
        case downloading(step: String)
        case ready(path: String, sizeMB: Int)
        case error(String)
    }

    struct ConvertStep: Decodable {
        let type: String
        let step: String?
        let message: String?
        let output_dir: String?
    }

    let settingsManager: SettingsManager

    init(settingsManager: SettingsManager) {
        self.settingsManager = settingsManager
        refreshStatuses()
    }

    nonisolated deinit {
        AppLogger.debug("ModelManager deinit", category: "lifecycle")
    }

    // MARK: - Public

    /// Rescans the models directory and updates statuses.
    func refreshStatuses() {
        let settings = settingsManager.settings.transcription
        let modelsDir = resolvedModelsDirectory(settings: settings)

        for model in settings.models {
            let modelPath = (modelsDir as NSString).appendingPathComponent(model.id)
            if isValidModel(at: modelPath) {
                // Mark ready immediately with 0 size, compute size in background
                if case .ready = modelStatuses[model.id] {
                    // Already ready — keep existing size
                } else {
                    modelStatuses[model.id] = .ready(path: modelPath, sizeMB: 0)
                }
                let modelID = model.id
                Task.detached(priority: .utility) { [weak self] in
                    let size = Self.directorySize(path: modelPath)
                    await MainActor.run {
                        // Only update if still in ready state (not downloading/deleted)
                        if case .ready(let p, _) = self?.modelStatuses[modelID] {
                            self?.modelStatuses[modelID] = .ready(path: p, sizeMB: size)
                        }
                    }
                }
            } else if case .downloading = modelStatuses[model.id] {
                // Keep downloading status
            } else {
                modelStatuses[model.id] = .notDownloaded
            }
        }
    }

    /// Downloads and converts a model. Progress updates via modelStatuses.
    func downloadModel(_ model: WhisperModelConfig) {
        guard activeTasks[model.id] == nil else { return }

        modelStatuses[model.id] = .downloading(step: "Starting...")

        activeTasks[model.id] = Task { [weak self] in
            guard let self else { return }

            let settings = settingsManager.settings.transcription
            let modelsDir = resolvedModelsDirectory(settings: settings)
            let outputDir = (modelsDir as NSString).appendingPathComponent(model.id)

            // Ensure models directory exists
            try? FileManager.default.createDirectory(
                atPath: modelsDir, withIntermediateDirectories: true)

            guard let pythonPath = PythonEnvironment.pythonPath(settings: settings) else {
                await MainActor.run {
                    self.modelStatuses[model.id] = .error("Python environment not ready")
                    self.activeTasks.removeValue(forKey: model.id)
                }
                return
            }

            guard let scriptPath = Bundle.main.path(forResource: "convert_model", ofType: "py") else {
                await MainActor.run {
                    self.modelStatuses[model.id] = .error("convert_model.py not found in app bundle")
                    self.activeTasks.removeValue(forKey: model.id)
                }
                return
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: pythonPath)
            process.arguments = [
                scriptPath,
                "--hf-model", model.huggingFaceID,
                "--output-dir", outputDir,
                "--quantization", model.quantization,
            ]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()

                let decoder = JSONDecoder()
                for try await line in pipe.fileHandleForReading.bytes.lines {
                    guard !Task.isCancelled else { break }
                    guard let data = line.data(using: .utf8),
                          let step = try? decoder.decode(ConvertStep.self, from: data) else {
                        continue
                    }

                    await MainActor.run {
                        switch step.type {
                        case "progress":
                            self.modelStatuses[model.id] = .downloading(step: step.message ?? "Working...")
                        case "done":
                            let size = Self.directorySize(path: outputDir)
                            self.modelStatuses[model.id] = .ready(path: outputDir, sizeMB: size)
                        case "error":
                            self.modelStatuses[model.id] = .error(step.message ?? "Unknown error")
                        default:
                            break
                        }
                    }
                }

                process.waitUntilExit()

                if process.terminationStatus != 0 {
                    await MainActor.run {
                        if case .ready = self.modelStatuses[model.id] {
                            // Already marked ready by the script
                        } else {
                            self.modelStatuses[model.id] = .error("Conversion exited with code \(process.terminationStatus)")
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.modelStatuses[model.id] = .error(error.localizedDescription)
                }
            }

            await MainActor.run {
                self.activeTasks.removeValue(forKey: model.id)
            }
        }
    }

    /// Cancels an in-progress download/conversion.
    func cancelDownload(_ modelID: String) {
        activeTasks[modelID]?.cancel()
        activeTasks.removeValue(forKey: modelID)
        modelStatuses[modelID] = .notDownloaded
    }

    /// Deletes a downloaded model from disk.
    func deleteModel(_ model: WhisperModelConfig) {
        let settings = settingsManager.settings.transcription
        let modelsDir = resolvedModelsDirectory(settings: settings)
        let modelPath = (modelsDir as NSString).appendingPathComponent(model.id)

        modelStatuses[model.id] = .notDownloaded
        Task.detached {
            try? FileManager.default.removeItem(atPath: modelPath)
        }
    }

    /// Returns the full path to a downloaded model, or nil.
    func modelPath(for modelID: String) -> String? {
        if case .ready(let path, _) = modelStatuses[modelID] {
            return path
        }
        return nil
    }

    // MARK: - Private

    private func resolvedModelsDirectory(settings: TranscriptionSettings) -> String {
        if !settings.modelsDirectory.isEmpty {
            return settings.modelsDirectory
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("CTTranscriber", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .path
    }

    private func isValidModel(at path: String) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return false }
        let requiredFiles = ["model.bin", "tokenizer.json", "preprocessor_config.json"]
        return requiredFiles.allSatisfy { fm.fileExists(atPath: (path as NSString).appendingPathComponent($0)) }
    }

    private nonisolated static func directorySize(path: String) -> Int {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: path) else { return 0 }
        var totalBytes: Int64 = 0
        while let file = enumerator.nextObject() as? String {
            let fullPath = (path as NSString).appendingPathComponent(file)
            if let attrs = try? fm.attributesOfItem(atPath: fullPath),
               let size = attrs[.size] as? Int64 {
                totalBytes += size
            }
        }
        let bytesPerMB: Int64 = 1_048_576
        return Int(totalBytes / bytesPerMB)
    }
}
