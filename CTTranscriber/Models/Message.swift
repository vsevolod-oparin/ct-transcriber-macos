import Foundation
import SwiftData

enum MessageRole: String, Codable {
    case user
    case assistant
    case system
}

@Model
final class Message {
    var id: UUID
    var role: MessageRole
    var content: String
    var timestamp: Date
    var audioFilePath: String?

    var conversation: Conversation?

    init(role: MessageRole, content: String, audioFilePath: String? = nil) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.audioFilePath = audioFilePath
    }
}
