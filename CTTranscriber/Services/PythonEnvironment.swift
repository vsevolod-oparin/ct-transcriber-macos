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

    // MARK: - Detection

    /// Checks if the conda environment is set up and functional.
    static func check(settings: TranscriptionSettings) -> Status {
        guard let condaPath = findConda() else {
            return .missing(reason: "conda not found. Install Miniconda from https://docs.anaconda.com/miniconda/")
        }

        let envName = settings.condaEnvName
        guard !envName.isEmpty else {
            return .missing(reason: "Conda environment name not set in Settings → Transcription.")
        }

        guard let pythonPath = findPythonInEnv(condaPath: condaPath, envName: envName) else {
            return .missing(reason: "Conda environment '\(envName)' not found. Run setup from Settings → Transcription.")
        }

        // Validate imports
        let validation = runPython(pythonPath: pythonPath,
                                   code: "import ctranslate2; import faster_whisper; print('ok')")
        if validation.trimmingCharacters(in: .whitespacesAndNewlines) != "ok" {
            return .missing(reason: "Environment '\(envName)' exists but CTranslate2/faster-whisper not installed. Re-run setup.")
        }

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
    static func runSetup(
        settings: TranscriptionSettings
    ) -> AsyncThrowingStream<SetupStep, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let scriptPath = Bundle.main.path(forResource: "setup_env", ofType: "sh") else {
                        throw PythonEnvError.setupScriptNotFound
                    }

                    let ct2Path = settings.ctranslate2SourcePath
                    guard !ct2Path.isEmpty else {
                        throw PythonEnvError.ctranslate2PathNotSet
                    }

                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/bash")
                    process.arguments = [scriptPath, settings.condaEnvName, ct2Path]

                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = FileHandle.nullDevice

                    try process.run()

                    let decoder = JSONDecoder()
                    for try await line in pipe.fileHandleForReading.bytes.lines {
                        if let data = line.data(using: .utf8),
                           let step = try? decoder.decode(SetupStep.self, from: data) {
                            continuation.yield(step)
                            if step.status == "error" {
                                throw PythonEnvError.setupFailed(step.message)
                            }
                        }
                    }

                    process.waitUntilExit()

                    if process.terminationStatus != 0 {
                        throw PythonEnvError.setupFailed("Setup script exited with code \(process.terminationStatus)")
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
        let searchPaths = [
            "\(NSHomeDirectory())/miniconda3/bin/conda",
            "\(NSHomeDirectory())/anaconda3/bin/conda",
            "/opt/homebrew/Caskroom/miniconda/base/bin/conda",
            "/opt/homebrew/bin/conda",
            "/usr/local/bin/conda",
        ]

        for path in searchPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Try PATH
        let whichResult = shell("which conda")
        let path = whichResult.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty && FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        return nil
    }

    private static func findPythonInEnv(condaPath: String, envName: String) -> String? {
        // Get conda info to find env path
        let envsOutput = shell("\(condaPath) env list")
        for line in envsOutput.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(envName + " ") || trimmed.hasPrefix(envName + " ") {
                let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
                if let envPath = parts.last {
                    let pythonPath = "\(envPath)/bin/python"
                    if FileManager.default.isExecutableFile(atPath: pythonPath) {
                        return pythonPath
                    }
                }
            }
        }
        return nil
    }

    private static func runPython(pythonPath: String, code: String) -> String {
        shell("\(pythonPath) -c '\(code)'")
    }

    private static func shell(_ command: String) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-l", "-c", command]
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}

// MARK: - Errors

enum PythonEnvError: LocalizedError {
    case setupScriptNotFound
    case ctranslate2PathNotSet
    case setupFailed(String)
    case environmentNotReady(String)

    var errorDescription: String? {
        switch self {
        case .setupScriptNotFound:
            "setup_env.sh not found in app bundle."
        case .ctranslate2PathNotSet:
            "CTranslate2 source path not set. Configure in Settings → Transcription."
        case .setupFailed(let msg):
            "Environment setup failed: \(msg)"
        case .environmentNotReady(let msg):
            "Python environment not ready: \(msg)"
        }
    }
}
