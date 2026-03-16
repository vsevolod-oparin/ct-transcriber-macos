import Foundation
import UniformTypeIdentifiers

enum FileStorage {
    private static let appDirectoryName = "CTTranscriber"
    private static let filesDirectoryName = "files"

    static var filesDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
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
        try? FileManager.default.removeItem(at: url(for: storedName))
    }

    /// Determines the attachment kind from a file URL based on its UTType.
    static func attachmentKind(for url: URL) -> AttachmentKind {
        guard let utType = UTType(filenameExtension: url.pathExtension) else {
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
