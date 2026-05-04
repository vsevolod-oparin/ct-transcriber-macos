import Foundation

/// Manages Whisper model downloads and local storage via MWModelManager.
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

    let settingsManager: SettingsManager

    init(settingsManager: SettingsManager) {
        self.settingsManager = settingsManager
        MWModelManager.shared().cacheDirectory = AppPaths.modelsDirectory.path
        refreshStatuses()
    }

    nonisolated deinit {
        AppLogger.debug("ModelManager deinit", category: "lifecycle")
    }

    // MARK: - Public

    /// Rescans the models directory and updates statuses.
    /// Checks both the legacy path ({modelsDir}/{id}) and the MWModelManager path
    /// ({modelsDir}/{sanitizedHFID}) so existing models continue to work.
    func refreshStatuses() {
        let settings = settingsManager.settings.transcription
        let modelsDir = resolvedModelsDirectory(settings: settings)

        for model in settings.models {
            guard case .downloading = modelStatuses[model.id] else {
                let modelPath = resolveLocalPath(for: model, in: modelsDir)
                if let path = modelPath {
                    if case .ready = modelStatuses[model.id] {
                        // Already ready — keep existing size
                    } else {
                        modelStatuses[model.id] = .ready(path: path, sizeMB: 0)
                    }
                    let modelID = model.id
                    Task.detached(priority: .utility) {
                        let size = ModelManager.directorySize(path: path)
                        await MainActor.run { [weak self] in
                            if case .ready(let p, _) = self?.modelStatuses[modelID] {
                                self?.modelStatuses[modelID] = .ready(path: p, sizeMB: size)
                            }
                        }
                    }
                } else {
                    modelStatuses[model.id] = .notDownloaded
                }
                continue
            }
            // Keep in-progress downloading status.
        }
    }

    /// Downloads a model from HuggingFace via MWModelManager. Progress updates via modelStatuses.
    /// The huggingFaceID in WhisperModelConfig must point to a pre-converted CTranslate2 repo
    /// (e.g. "Systran/faster-whisper-large-v3", not the original PyTorch "openai/whisper-*" repo).
    func downloadModel(_ model: WhisperModelConfig) {
        guard activeTasks[model.id] == nil else { return }

        modelStatuses[model.id] = .downloading(step: "Starting...")

        let modelID = model.id
        let hfID = model.huggingFaceID
        activeTasks[modelID] = Task { [weak self] in
            await self?.performDownload(modelID: modelID, hfID: hfID)
        }
    }

    private func performDownload(modelID: String, hfID: String) async {
        let settings = settingsManager.settings.transcription
        let modelsDir = resolvedModelsDirectory(settings: settings)

        try? FileManager.default.createDirectory(
            atPath: modelsDir, withIntermediateDirectories: true)

        MWModelManager.shared().cacheDirectory = modelsDir

        let result = await fetchModelPath(hfID: hfID, modelID: modelID)

        await MainActor.run {
            guard activeTasks[modelID] != nil else { return }
            switch result {
            case .success(let path):
                let size = Self.directorySize(path: path)
                self.modelStatuses[modelID] = .ready(path: path, sizeMB: size)
            case .failure(let error):
                self.modelStatuses[modelID] = .error(error.localizedDescription)
            }
            self.activeTasks.removeValue(forKey: modelID)
        }
    }

    private func fetchModelPath(hfID: String, modelID: String) async -> Result<String, Error> {
        return await Task.detached(priority: .userInitiated) { [weak self] () -> Result<String, Error> in
            do {
                let path = try MWModelManager.shared().resolveModel(
                    hfID,
                    progress: { bytesDownloaded, totalBytes, fileName in
                        let step: String
                        if totalBytes > 0 {
                            let pct = Int(Double(bytesDownloaded) / Double(totalBytes) * 100)
                            step = "Downloading \(fileName) (\(pct)%)"
                        } else {
                            let mb = bytesDownloaded / 1_048_576
                            step = "Downloading \(fileName) (\(mb) MB)"
                        }
                        Task { @MainActor [weak self] in
                            if case .downloading = self?.modelStatuses[modelID] {
                                self?.modelStatuses[modelID] = .downloading(step: step)
                            }
                        }
                    }
                )
                return Result<String, Error>.success(path)
            } catch {
                return Result<String, Error>.failure(error)
            }
        }.value
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

        modelStatuses[model.id] = .notDownloaded

        // Delete whichever path exists (legacy id-based or MWModelManager sanitized path).
        let pathsToTry = [
            (modelsDir as NSString).appendingPathComponent(model.id),
            (modelsDir as NSString).appendingPathComponent(model.huggingFaceID.replacingOccurrences(of: "/", with: "--")),
        ]
        Task.detached {
            for path in pathsToTry {
                try? FileManager.default.removeItem(atPath: path)
            }
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

    /// Returns the local path for a model if it exists on disk, nil otherwise.
    /// Checks the MWModelManager sanitized path first, then the legacy id-based path.
    private func resolveLocalPath(for model: WhisperModelConfig, in modelsDir: String) -> String? {
        let sanitizedHFID = model.huggingFaceID.replacingOccurrences(of: "/", with: "--")
        let candidates = [
            (modelsDir as NSString).appendingPathComponent(sanitizedHFID),
            (modelsDir as NSString).appendingPathComponent(model.id),
        ]
        return candidates.first { isValidModel(at: $0) }
    }

    private func resolvedModelsDirectory(settings: TranscriptionSettings) -> String {
        if !settings.modelsDirectory.isEmpty {
            return settings.modelsDirectory
        }
        return AppPaths.modelsDirectory.path
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
