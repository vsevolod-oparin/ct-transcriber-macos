import Foundation
import AVFoundation

/// Runs whisper transcription via the MetalWhisper framework (in-process, no subprocess).
enum TranscriptionService {

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
                let startStr = TimeFormatting.formatTime(seg.start)
                let endStr = TimeFormatting.formatTime(seg.end)
                return "[\(startStr) → \(endStr)] \(seg.text)"
            }.joined(separator: "\n")
        }

        /// Plain text without timestamps.
        var plainText: String {
            segments.map(\.text).joined(separator: " ")
        }
    }

    /// Progress updates during transcription.
    enum Progress {
        case started(language: String, duration: Double)
        case segment(index: Int, text: String, progress: Double)
        case completed(TranscriptionResult)
        case error(String)
    }

    /// Transcribes an audio file using the MetalWhisper framework.
    /// Yields progress updates; finishes with `.completed` then closes the stream.
    static func transcribe(
        audioPath: String,
        modelPath: String,
        settings: TranscriptionSettings
    ) -> AsyncThrowingStream<Progress, Error> {
        AsyncThrowingStream { continuation in
            // Shared stop flag checked from the ObjC segmentHandler (background GCD queue).
            class StopBox: @unchecked Sendable { var value = false }
            let stopBox = StopBox()

            let task = Task.detached(priority: .userInitiated) {
                do {
                    let audioURL = URL(fileURLWithPath: audioPath)

                    // Probe audio duration before starting so progress % is meaningful.
                    let duration: Double = await {
                        let asset = AVURLAsset(url: audioURL)
                        guard let d = try? await asset.load(.duration) else { return 0 }
                        let s = d.seconds
                        return (s.isNaN || s.isInfinite) ? 0 : s
                    }()

                    continuation.yield(.started(language: "detecting...", duration: duration))

                    // Load model into GPU memory (blocks until ready).
                    let transcriber = try MWTranscriber(modelPath: modelPath)

                    let options = MWTranscriptionOptions()
                    options.beamSize = UInt(max(1, settings.beamSize))
                    options.temperatures = [NSNumber(value: settings.temperature)]
                    options.conditionOnPreviousText = settings.conditionOnPreviousText
                    options.withoutTimestamps = settings.skipTimestamps

                    if settings.vadFilter {
                        options.vadFilter = true
                        // silero_vad_v6.onnx is bundled inside MetalWhisper.framework/Resources.
                        // Bundle(for:) resolves to the framework bundle, not the app bundle.
                        if let vadPath = Bundle(for: MWTranscriber.self)
                                .path(forResource: "silero_vad_v6", ofType: "onnx") {
                            options.vadModelPath = vadPath
                        }
                    }

                    let language: String? = settings.language.isEmpty ? nil : settings.language

                    var segments: [TranscriptionResult.Segment] = []
                    let segmentsLock = NSLock()
                    var segmentIndex = 0
                    var outInfo: MWTranscriptionInfo? = nil
                    let t0 = Date()

                    // Synchronous call; segmentHandler fires on the transcriber's background queue.
                    let _ = try transcriber.transcribeURL(
                        audioURL,
                        language: language,
                        task: "transcribe",
                        typedOptions: options,
                        segmentHandler: { segment, stop in
                            if stopBox.value || Task.isCancelled {
                                stop.pointee = true
                                return
                            }
                            let text = segment.text.trimmingCharacters(in: .whitespaces)
                            guard !text.isEmpty else { return }

                            let start = Double(segment.start)
                            let end = Double(segment.end)
                            segmentsLock.lock()
                            segments.append(.init(start: start, end: end, text: text))
                            segmentsLock.unlock()
                            segmentIndex += 1

                            let progress = duration > 0 ? min(1.0, end / duration) : 0
                            continuation.yield(.segment(index: segmentIndex, text: text, progress: progress))
                        },
                        info: &outInfo
                    )

                    if stopBox.value || Task.isCancelled {
                        continuation.finish(throwing: TranscriptionError.cancelled)
                        return
                    }

                    let elapsed = Date().timeIntervalSince(t0)
                    let lang = outInfo?.language ?? "unknown"
                    let actualDuration = outInfo.map { Double($0.duration) } ?? duration

                    segmentsLock.lock()
                    let result = TranscriptionResult(
                        language: lang,
                        duration: actualDuration,
                        segments: segments,
                        elapsed: elapsed
                    )
                    segmentsLock.unlock()
                    continuation.yield(.completed(result))
                    continuation.finish()

                } catch is CancellationError {
                    continuation.finish(throwing: TranscriptionError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                stopBox.value = true
                task.cancel()
            }
        }
    }
}

// MARK: - Errors

enum TranscriptionError: LocalizedError {
    case modelNotDownloaded
    case transcriptionFailed(String)
    case cancelled

    var isCancelled: Bool {
        if case .cancelled = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .modelNotDownloaded:
            "Whisper model not downloaded. Open Settings → Transcription → Manage Models."
        case .transcriptionFailed(let msg):
            "Transcription failed: \(msg)"
        case .cancelled:
            "Transcription cancelled."
        }
    }
}
