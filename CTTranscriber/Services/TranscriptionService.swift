import Foundation

/// Runs whisper transcription via the bundled transcribe.py subprocess.
enum TranscriptionService {

    /// A single event from transcribe.py stdout.
    struct TranscribeEvent: Decodable {
        let type: String        // "info", "segment", "done", "error"
        let language: String?
        let language_probability: Double?
        let duration: Double?
        let start: Double?
        let end: Double?
        let text: String?
        let num_segments: Int?
        let elapsed: Double?
        let message: String?
    }

    /// Result of a completed transcription.
    struct TranscriptionResult {
        let language: String
        let duration: Double
        let segments: [Segment]
        let elapsed: Double

        struct Segment {
            let start: Double
            let end: Double
            let text: String
        }

        /// Formatted transcript with timestamps.
        var formattedTranscript: String {
            segments.map { seg in
                let startStr = formatTimestamp(seg.start)
                let endStr = formatTimestamp(seg.end)
                return "[\(startStr) → \(endStr)] \(seg.text)"
            }.joined(separator: "\n")
        }

        /// Plain text without timestamps.
        var plainText: String {
            segments.map(\.text).joined(separator: " ")
        }

        private func formatTimestamp(_ seconds: Double) -> String {
            let mins = Int(seconds) / 60
            let secs = Int(seconds) % 60
            return String(format: "%d:%02d", mins, secs)
        }
    }

    /// Progress updates during transcription.
    enum Progress {
        case started(language: String, duration: Double)
        case segment(index: Int, text: String, progress: Double)
        case completed(TranscriptionResult)
        case error(String)
    }

    /// Transcribes an audio file. Yields progress updates, returns result on completion.
    static func transcribe(
        audioPath: String,
        modelPath: String,
        settings: TranscriptionSettings
    ) -> AsyncThrowingStream<Progress, Error> {
        AsyncThrowingStream { continuation in
            // Shared reference so onTermination can kill the subprocess
            class ProcessBox: @unchecked Sendable { var process: Process? }
            let box = ProcessBox()

            let task = Task {
                do {
                    guard let pythonPath = PythonEnvironment.pythonPath(settings: settings) else {
                        throw TranscriptionError.environmentNotReady
                    }

                    guard let scriptPath = PythonEnvironment.transcribeScriptPath else {
                        throw TranscriptionError.scriptNotFound
                    }

                    let process = Process()
                    box.process = process
                    process.executableURL = URL(fileURLWithPath: pythonPath)

                    var args = [
                        scriptPath,
                        "--model", modelPath,
                        "--audio", audioPath,
                        "--device", settings.device,
                        "--beam-size", String(settings.beamSize),
                        "--temperature", String(settings.temperature),
                    ]

                    if !settings.language.isEmpty {
                        args += ["--language", settings.language]
                    }

                    if settings.vadFilter {
                        args.append("--vad-filter")
                    } else {
                        args.append("--no-vad-filter")
                    }

                    if settings.conditionOnPreviousText {
                        args.append("--condition-on-previous-text")
                    }

                    if settings.flashAttention {
                        args.append("--flash-attention")
                    } else {
                        args.append("--no-flash-attention")
                    }

                    if settings.skipTimestamps {
                        args.append("--skip-timestamps")
                    }

                    process.arguments = args

                    AppLogger.info("Transcription command: \(pythonPath) \(args.joined(separator: " "))", category: "transcription")

                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe

                    try process.run()

                    let decoder = JSONDecoder()
                    var segments: [TranscriptionResult.Segment] = []
                    var language = ""
                    var duration = 0.0
                    var segmentIndex = 0

                    for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
                        try Task.checkCancellation()

                        guard let data = line.data(using: .utf8),
                              let event = try? decoder.decode(TranscribeEvent.self, from: data) else {
                            continue
                        }

                        switch event.type {
                        case "info":
                            language = event.language ?? ""
                            duration = event.duration ?? 0
                            continuation.yield(.started(language: language, duration: duration))

                        case "segment":
                            if let start = event.start, let end = event.end, let text = event.text {
                                segments.append(.init(start: start, end: end, text: text))
                                segmentIndex += 1
                                let progress = duration > 0 ? min(1.0, end / duration) : 0
                                continuation.yield(.segment(index: segmentIndex, text: text, progress: progress))
                            }

                        case "done":
                            let result = TranscriptionResult(
                                language: language,
                                duration: duration,
                                segments: segments,
                                elapsed: event.elapsed ?? 0
                            )
                            continuation.yield(.completed(result))

                        case "error":
                            throw TranscriptionError.transcriptionFailed(event.message ?? "Unknown error")

                        default:
                            break
                        }
                    }

                    process.waitUntilExit()

                    if process.terminationStatus != 0 && segments.isEmpty {
                        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        let stderrText = String(data: stderrData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                        let lastLines = stderrText.split(separator: "\n").suffix(5).joined(separator: "\n")
                        AppLogger.error("transcribe.py exited with code \(process.terminationStatus). Stderr:\n\(stderrText)", category: "transcription")

                        let errorDetail = lastLines.isEmpty
                            ? "exit code \(process.terminationStatus)"
                            : lastLines
                        throw TranscriptionError.transcriptionFailed(errorDetail)
                    }

                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: TranscriptionError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
                if let p = box.process, p.isRunning {
                    p.terminate()
                }
            }
        }
    }
}

// MARK: - Errors

enum TranscriptionError: LocalizedError {
    case environmentNotReady
    case scriptNotFound
    case modelNotDownloaded
    case transcriptionFailed(String)
    case cancelled

    var isCancelled: Bool {
        if case .cancelled = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .environmentNotReady:
            "Python environment not ready. Run setup from Settings → Environment."
        case .scriptNotFound:
            "transcribe.py not found in app bundle."
        case .modelNotDownloaded:
            "Whisper model not downloaded. Open Settings → Transcription → Manage Models."
        case .transcriptionFailed(let msg):
            "Transcription failed: \(msg)"
        case .cancelled:
            "Transcription cancelled."
        }
    }
}
