import Foundation
import UniformTypeIdentifiers

enum FileStorage {
    private static let appDirectoryName = "CTTranscriber"
    private static let filesDirectoryName = "files"

    static var filesDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let appDir = appSupport.appendingPathComponent(appDirectoryName, isDirectory: true)
        return appDir.appendingPathComponent(filesDirectoryName, isDirectory: true)
    }

    /// Copies a file to app storage, returning the UUID-based stored filename.
    static func copyToStorage(from sourceURL: URL) throws -> String {
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: filesDirectory.path) {
            try fileManager.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
        }

        let fileExtension = sourceURL.pathExtension
        let storedName = "\(UUID().uuidString).\(fileExtension)"
        let destinationURL = filesDirectory.appendingPathComponent(storedName)

        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return storedName
    }

    /// Writes data directly to storage (e.g., LLM-generated images).
    static func writeToStorage(data: Data, extension ext: String) throws -> String {
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: filesDirectory.path) {
            try fileManager.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
        }

        let storedName = "\(UUID().uuidString).\(ext)"
        let destinationURL = filesDirectory.appendingPathComponent(storedName)

        try data.write(to: destinationURL)
        return storedName
    }

    /// Returns the full URL for a stored filename.
    static func url(for storedName: String) -> URL {
        filesDirectory.appendingPathComponent(storedName)
    }

    /// Deletes a stored file.
    static func delete(storedName: String) {
        do {
            try FileManager.default.removeItem(at: url(for: storedName))
        } catch {
            AppLogger.error("Failed to delete file \(storedName): \(error)", category: "storage")
        }
    }

    /// Video file extensions not always recognized by UTType on macOS.
    private static let videoExtensions: Set<String> = ["webm", "mkv", "avi", "flv", "wmv", "ts"]
    /// Audio file extensions as fallback.
    private static let audioExtensions: Set<String> = ["ogg", "opus", "wma"]

    /// Determines the attachment kind from a file URL based on its UTType.
    static func attachmentKind(for url: URL) -> AttachmentKind {
        let ext = url.pathExtension.lowercased()

        // Check extension-based fallbacks first (WebM, MKV, etc. may not have UTTypes on macOS)
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }

        guard let utType = UTType(filenameExtension: ext) else {
            return .text
        }

        if utType.conforms(to: .audio) {
            return .audio
        } else if utType.conforms(to: .movie) || utType.conforms(to: .video) {
            return .video
        } else if utType.conforms(to: .image) {
            return .image
        } else {
            return .text
        }
    }
}
