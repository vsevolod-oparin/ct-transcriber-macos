import Foundation
import SwiftData

enum MessageRole: String, Codable {
    case user
    case assistant
    case system
}

enum MessageLifecycle: String, Codable {
    case complete
    case streaming
    case transcriptionQueued
    case transcribing
    case errorLLM
    case errorTranscription
    case cancelled
}

@Model
final class Message {
    var id: UUID
    var role: MessageRole
    var content: String
    var timestamp: Date

    @Relationship(deleteRule: .cascade, inverse: \Attachment.message)
    var attachments: [Attachment]

    var lifecycle: MessageLifecycle?

    var conversation: Conversation?

    init(role: MessageRole, content: String) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.attachments = []
    }
}
