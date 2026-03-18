import Foundation

/// Converts unsupported video formats (WebM, MKV, etc.) to MP4 using ffmpeg
/// from the conda environment. The converted file is stored alongside the original.
enum VideoConverter {
    /// File extensions that need conversion for AVPlayer playback.
    static let unsupportedExtensions: Set<String> = ["webm", "mkv", "flv", "wmv"]

    /// Returns true if the file extension needs conversion for playback.
    static func needsConversion(_ filename: String) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        return unsupportedExtensions.contains(ext)
    }

    /// Converts a video file to MP4. Returns the stored name of the converted file,
    /// or nil if conversion failed.
    ///
    /// Uses ffmpeg from the conda environment (available via faster-whisper dependency).
    static func convertToMP4(
        storedName: String,
        settings: TranscriptionSettings
    ) async -> String? {
        let sourceURL = FileStorage.url(for: storedName)
        let mp4Name = (storedName as NSString).deletingPathExtension + ".mp4"
        let destURL = FileStorage.url(for: mp4Name)

        // Skip if already converted
        if FileManager.default.fileExists(atPath: destURL.path) {
            return mp4Name
        }

        // Find ffmpeg in the conda environment
        guard let ffmpegPath = findFFmpeg(settings: settings) else {
            AppLogger.error("ffmpeg not found in conda env", category: "video")
            return nil
        }

        AppLogger.info("Converting \(storedName) to MP4...", category: "video")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = [
            "-i", sourceURL.path,
            "-c:v", "libx264",
            "-preset", "fast",
            "-crf", "23",
            "-c:a", "aac",
            "-b:a", "128k",
            "-movflags", "+faststart",
            "-y",  // overwrite
            destURL.path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                AppLogger.info("Converted to MP4: \(mp4Name)", category: "video")
                return mp4Name
            } else {
                AppLogger.error("ffmpeg exited with code \(process.terminationStatus)", category: "video")
                return nil
            }
        } catch {
            AppLogger.error("ffmpeg launch failed: \(error)", category: "video")
            return nil
        }
    }

    /// Finds ffmpeg in the bundled conda environment ONLY. Never uses system installs.
    private static func findFFmpeg(settings: TranscriptionSettings) -> String? {
        let fm = FileManager.default
        let condaBase = NSHomeDirectory() + "/.ct-transcriber/miniconda"

        // Check the transcription conda env first
        let envBin = "\(condaBase)/envs/\(settings.condaEnvName)/bin/ffmpeg"
        if fm.isExecutableFile(atPath: envBin) { return envBin }

        // Check conda base bin (ffmpeg might be installed at the base level)
        let baseBin = "\(condaBase)/bin/ffmpeg"
        if fm.isExecutableFile(atPath: baseBin) { return baseBin }

        AppLogger.error("ffmpeg not found in bundled conda env. Run: conda install -n \(settings.condaEnvName) ffmpeg", category: "video")
        return nil
    }
}
