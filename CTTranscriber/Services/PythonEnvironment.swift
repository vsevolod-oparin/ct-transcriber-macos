import Foundation

/// Manages the conda Python environment for whisper-metal transcription.
enum PythonEnvironment {

    /// Status of the Python environment.
    enum Status: Equatable {
        case notChecked
        case missing(reason: String)
        case ready(pythonPath: String)
    }

    /// A single step reported by setup_env.sh.
    struct SetupStep: Decodable {
        let step: String
        let status: String
        let message: String
    }

    /// Where bundled Miniconda gets installed. No spaces in path — Miniconda installer
    /// and conda itself can have issues with spaces in prefixes.
    private static let bundledMinicondaPath =
        NSHomeDirectory() + "/.ct-transcriber/miniconda"

    // MARK: - Detection

    /// Checks if the conda environment is set up and functional.
    static func check(settings: TranscriptionSettings) -> Status {
        AppLogger.info("Checking Python environment...", category: "python-env")

        guard let condaPath = findConda() else {
            AppLogger.error("conda not found in any search path", category: "python-env")
            return .missing(reason: "Conda not found. Click 'Set Up Transcription' to install automatically.")
        }
        AppLogger.info("Found conda at: \(condaPath)", category: "python-env")

        let envName = settings.condaEnvName
        guard !envName.isEmpty else {
            AppLogger.error("condaEnvName is empty", category: "python-env")
            return .missing(reason: "Conda environment name not set in Settings → Transcription.")
        }

        guard let pythonPath = findPythonInEnv(condaPath: condaPath, envName: envName) else {
            AppLogger.error("Python not found for env '\(envName)' (conda: \(condaPath))", category: "python-env")
            return .missing(reason: "Environment '\(envName)' not found. Click 'Set Up Transcription' to create it.")
        }
        AppLogger.info("Found Python at: \(pythonPath)", category: "python-env")

        // Validate imports
        let validation = runPython(pythonPath: pythonPath,
                                   code: "import ctranslate2; import faster_whisper; print('ok')")
        let trimmed = validation.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != "ok" {
            AppLogger.error("Import validation failed. Output: '\(trimmed)'", category: "python-env")
            // Also capture stderr
            let stderr = runPythonWithStderr(pythonPath: pythonPath,
                                             code: "import ctranslate2; import faster_whisper; print('ok')")
            AppLogger.error("Stderr: \(stderr)", category: "python-env")
            return .missing(reason: "CTranslate2 or faster-whisper not installed. Re-run setup.")
        }

        AppLogger.info("Python environment ready", category: "python-env")
        return .ready(pythonPath: pythonPath)
    }

    /// Returns the path to the Python executable in the conda env, or nil.
    static func pythonPath(settings: TranscriptionSettings) -> String? {
        guard let condaPath = findConda(),
              let path = findPythonInEnv(condaPath: condaPath, envName: settings.condaEnvName) else {
            return nil
        }
        return path
    }

    /// Returns the path to the bundled transcribe.py script.
    static var transcribeScriptPath: String? {
        Bundle.main.path(forResource: "transcribe", ofType: "py")
    }

    // MARK: - Setup

    /// Runs setup_env.sh as a subprocess, streaming progress steps.
    /// Automatically chooses wheel mode or source mode based on settings.
    static func runSetup(
        settings: TranscriptionSettings
    ) -> AsyncThrowingStream<SetupStep, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let scriptPath = Bundle.main.path(forResource: "setup_env", ofType: "sh") else {
                        throw PythonEnvError.setupScriptNotFound
                    }

                    var arguments = [scriptPath, settings.condaEnvName]

                    // Prefer pre-built package, fall back to source build
                    if !settings.ct2PackageURL.isEmpty {
                        arguments += ["--package-url", settings.ct2PackageURL]
                    } else if !settings.ctranslate2SourcePath.isEmpty {
                        arguments += ["--source", settings.ctranslate2SourcePath]
                    }
                    // Download default model during setup
                    if !settings.selectedModelID.isEmpty {
                        if let model = settings.models.first(where: { $0.id == settings.selectedModelID }) {
                            arguments += [
                                "--download-model", model.huggingFaceID,
                                "--model-id", model.id,
                                "--model-quantization", model.quantization,
                            ]
                        }
                    }

                    // If neither is set, script installs deps but skips CT2

                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/bash")
                    process.arguments = arguments

                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe

                    // Log stderr in background
                    let stderrTask = Task {
                        for try await line in stderrPipe.fileHandleForReading.bytes.lines {
                            AppLogger.debug("[setup_env] \(line)", category: "python-env")
                        }
                    }

                    try process.run()

                    let decoder = JSONDecoder()
                    for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
                        if let data = line.data(using: .utf8),
                           let step = try? decoder.decode(SetupStep.self, from: data) {
                            AppLogger.info("[setup_env] \(step.step): \(step.status) — \(step.message)", category: "python-env")
                            continuation.yield(step)
                            if step.status == "error" {
                                throw PythonEnvError.setupFailed(step.message)
                            }
                        } else {
                            // Non-JSON stdout (e.g. conda/pip output passed through)
                            AppLogger.debug("[setup_env] \(line)", category: "python-env")
                        }
                    }

                    _ = try? await stderrTask.value
                    process.waitUntilExit()

                    if process.terminationStatus != 0 {
                        throw PythonEnvError.setupFailed("Setup exited with code \(process.terminationStatus)")
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Private

    private static func findConda() -> String? {
        // Only use the app's own bundled Miniconda. Never use or contaminate the user's
        // system conda/anaconda installation.
        let bundledConda = bundledMinicondaPath + "/bin/conda"
        if FileManager.default.isExecutableFile(atPath: bundledConda) {
            AppLogger.debug("Found bundled Miniconda at \(bundledConda)", category: "python-env")
            return bundledConda
        }

        AppLogger.debug("Bundled Miniconda not found at \(bundledConda)", category: "python-env")
        return nil
    }

    private static func findPythonInEnv(condaPath: String, envName: String) -> String? {
        // Derive env path directly from conda path (no subprocess needed).
        // conda is at <prefix>/bin/conda → envs at <prefix>/envs/<name>
        let condaDir = (condaPath as NSString).deletingLastPathComponent
        let condaPrefix = (condaDir as NSString).deletingLastPathComponent
        let pythonPath = "\(condaPrefix)/envs/\(envName)/bin/python"

        if FileManager.default.isExecutableFile(atPath: pythonPath) {
            return pythonPath
        }

        AppLogger.debug("Python not found at \(pythonPath)", category: "python-env")
        return nil
    }

    private static func runPython(pythonPath: String, code: String) -> String {
        runProcess(executable: pythonPath, arguments: ["-c", code])
    }

    private static func runPythonWithStderr(pythonPath: String, code: String) -> String {
        let process = Process()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = ["-c", code]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return "Process launch failed: \(error)"
        }
    }

    private static func shell(_ command: String) -> String {
        runProcess(executable: "/bin/bash", arguments: ["-l", "-c", command])
    }

    private static func runProcess(executable: String, arguments: [String]) -> String {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}

// MARK: - Errors

enum PythonEnvError: LocalizedError {
    case setupScriptNotFound
    case setupFailed(String)
    case environmentNotReady(String)

    var errorDescription: String? {
        switch self {
        case .setupScriptNotFound:
            "setup_env.sh not found in app bundle."
        case .setupFailed(let msg):
            "Environment setup failed: \(msg)"
        case .environmentNotReady(let msg):
            "Python environment not ready: \(msg)"
        }
    }
}
