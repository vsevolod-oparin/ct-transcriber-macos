import Foundation
import SwiftData

enum AttachmentKind: String, Codable {
    case audio
    case video
    case image
    case text
}

@Model
final class Attachment {
    var id: UUID
    var kind: AttachmentKind
    /// UUID-based filename stored on disk (e.g., "A1B2C3.mp3")
    var storedName: String
    /// Original filename as provided by the user (e.g., "meeting.mp3")
    var originalName: String
    /// Persisted playback position (seconds) — resumes from here on next play.
    var playbackPosition: Double = 0

    var message: Message?

    init(kind: AttachmentKind, storedName: String, originalName: String) {
        self.id = UUID()
        self.kind = kind
        self.storedName = storedName
        self.originalName = originalName
    }
}
