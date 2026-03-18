import Foundation
import SwiftData

enum TaskKind: String, Codable {
    case transcription
    case modelDownload
    case pythonSetup
}

enum TaskStatus: String, Codable {
    case pending
    case running
    case completed
    case failed
    case cancelled
}

@Model
final class BackgroundTask {
    var id: UUID
    var kind: TaskKind
    var title: String
    var status: TaskStatus
    var progress: Double // 0.0–1.0
    var errorMessage: String?
    var createdAt: Date
    var updatedAt: Date
    /// Title of the conversation this task belongs to (for display in task manager).
    var conversationTitle: String?

    /// Context for retrying: audio file path, model ID, etc.
    var contextJSON: String?

    init(kind: TaskKind, title: String, conversationTitle: String? = nil) {
        self.id = UUID()
        self.kind = kind
        self.title = title
        self.conversationTitle = conversationTitle
        self.status = .pending
        self.progress = 0
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}
