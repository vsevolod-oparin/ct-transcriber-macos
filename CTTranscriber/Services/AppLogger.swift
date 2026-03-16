import Foundation
import os

/// Simple app logger that writes to both os_log and a file at
/// ~/Library/Application Support/CTTranscriber/ct-transcriber.log
enum AppLogger {
    private static let subsystem = "com.branch.ct-transcriber"
    private static let osLog = Logger(subsystem: subsystem, category: "app")

    private static let logFileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("CTTranscriber", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ct-transcriber.log")
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

        // File log (append)
        if let data = line.data(using: .utf8) {
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

    /// Returns the log file path for display in UI.
    static var logFilePath: String {
        logFileURL.path
    }
}
