import Foundation
import os

/// Simple app logger that writes to both os_log and a file at
/// ~/Library/Application Support/CTTranscriber/ct-transcriber.log
///
/// Includes automatic log rotation: when the log exceeds `maxLogSizeBytes`,
/// the current file is moved to `.1` (previous `.1` to `.2`, etc.) and a
/// fresh file is started. Up to `maxLogFiles` rotated files are kept.
enum AppLogger {
    private static let subsystem = "com.branch.ct-transcriber"
    private static let osLog = Logger(subsystem: subsystem, category: "app")

    /// Maximum log file size before rotation (10 MB).
    private static let maxLogSizeBytes: UInt64 = 10 * 1_048_576
    /// Number of rotated log files to keep (e.g., .1, .2, .3).
    private static let maxLogFiles = 3

    /// Serial queue for file I/O — prevents data races on log file.
    private static let fileQueue = DispatchQueue(label: "com.branch.ct-transcriber.logger")

    private static let logFileURL: URL = {
        let dir = AppPaths.storageRoot
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return AppPaths.logFileURL
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String, category: String = "app") {
        log(level: "INFO", message: message, category: category)
    }

    static func error(_ message: String, category: String = "app") {
        log(level: "ERROR", message: message, category: category)
    }

    static func debug(_ message: String, category: String = "app") {
        log(level: "DEBUG", message: message, category: category)
    }

    private static func log(level: String, message: String, category: String) {
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] [\(level)] [\(category)] \(message)\n"

        // os_log
        switch level {
        case "ERROR": osLog.error("\(message)")
        case "DEBUG": osLog.debug("\(message)")
        default: osLog.info("\(message)")
        }

        // File log (append) with rotation — dispatched to serial queue for thread safety
        if let data = line.data(using: .utf8) {
            fileQueue.async {
                rotateIfNeeded()

                if FileManager.default.fileExists(atPath: logFileURL.path) {
                    if let handle = try? FileHandle(forWritingTo: logFileURL) {
                        handle.seekToEndOfFile()
                        handle.write(data)
                        handle.closeFile()
                    }
                } else {
                    try? data.write(to: logFileURL)
                }
            }
        }
    }

    /// Rotates log files when the current file exceeds `maxLogSizeBytes`.
    /// ct-transcriber.log → ct-transcriber.log.1 → .2 → .3 (oldest deleted).
    private static func rotateIfNeeded() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: logFileURL.path),
              let size = attrs[.size] as? UInt64,
              size >= maxLogSizeBytes else {
            return
        }

        let basePath = logFileURL.path

        // Delete the oldest rotated file
        let oldestPath = "\(basePath).\(maxLogFiles)"
        try? fm.removeItem(atPath: oldestPath)

        // Shift existing rotated files: .2 → .3, .1 → .2, etc.
        for i in stride(from: maxLogFiles - 1, through: 1, by: -1) {
            let src = "\(basePath).\(i)"
            let dst = "\(basePath).\(i + 1)"
            if fm.fileExists(atPath: src) {
                try? fm.moveItem(atPath: src, toPath: dst)
            }
        }

        // Move current log to .1
        try? fm.moveItem(atPath: basePath, toPath: "\(basePath).1")
    }

    /// Returns the log file path for display in UI.
    static var logFilePath: String {
        logFileURL.path
    }
}
