import Foundation
import SwiftData

enum ConversationExporter {

    // MARK: - Codable Transfer Types

    struct ExportedConversation: Codable {
        let id: String
        let title: String
        let createdAt: Date
        let updatedAt: Date
        let messages: [ExportedMessage]
    }

    struct ExportedMessage: Codable {
        let id: String
        let role: String
        let content: String
        let timestamp: Date
        let attachments: [ExportedAttachment]
    }

    struct ExportedAttachment: Codable {
        let kind: String
        let originalName: String
    }

    // MARK: - JSON Export

    static func exportJSON(conversation: Conversation) throws -> Data {
        guard !conversation.isDeleted, conversation.modelContext != nil else {
            throw NSError(domain: "ConversationExporter", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Conversation is no longer available"])
        }

        let sorted = conversation.messages
            .filter { !$0.isDeleted && $0.modelContext != nil }
            .sorted { $0.timestamp < $1.timestamp }

        let exported = ExportedConversation(
            id: conversation.id.uuidString,
            title: conversation.title,
            createdAt: conversation.createdAt,
            updatedAt: conversation.updatedAt,
            messages: sorted.map { msg in
                ExportedMessage(
                    id: msg.id.uuidString,
                    role: msg.role.rawValue,
                    content: msg.content,
                    timestamp: msg.timestamp,
                    attachments: msg.attachments
                        .filter { !$0.isDeleted && $0.modelContext != nil }
                        .map { att in
                            ExportedAttachment(kind: att.kind.rawValue, originalName: att.originalName)
                        }
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(exported)
    }

    // MARK: - Markdown Export

    static func exportMarkdown(conversation: Conversation) -> String {
        guard !conversation.isDeleted, conversation.modelContext != nil else { return "" }

        var md = "# \(conversation.title)\n\n"
        let sorted = conversation.messages
            .filter { !$0.isDeleted && $0.modelContext != nil }
            .sorted { $0.timestamp < $1.timestamp }

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        for message in sorted {
            let role = message.role == .user ? "**You**" : "**Assistant**"
            let time = dateFormatter.string(from: message.timestamp)
            md += "### \(role) — \(time)\n\n"

            for attachment in message.attachments where !attachment.isDeleted && attachment.modelContext != nil {
                md += "> Attachment: \(attachment.originalName) (\(attachment.kind.rawValue))\n\n"
            }

            if !message.content.isEmpty {
                md += message.content + "\n\n"
            }
            md += "---\n\n"
        }
        return md
    }

    // MARK: - JSON Import

    static func importJSON(data: Data, into context: ModelContext) throws -> Conversation {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let exported = try decoder.decode(ExportedConversation.self, from: data)

        let conversation = Conversation(title: exported.title)
        conversation.createdAt = exported.createdAt
        conversation.updatedAt = exported.updatedAt

        context.insert(conversation)

        for msg in exported.messages {
            let role = MessageRole(rawValue: msg.role) ?? .user
            let message = Message(role: role, content: msg.content)
            message.timestamp = msg.timestamp
            conversation.messages.append(message)
        }

        try context.save()
        return conversation
    }

    // MARK: - Bulk Export (ZIP)

    static func exportBulkZIP(conversations: [Conversation]) throws -> Data {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for conversation in conversations {
            let data = try exportJSON(conversation: conversation)
            let safeName = conversation.title
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .prefix(50)
            let fileName = "\(safeName).json"
            try data.write(to: tempDir.appendingPathComponent(fileName))
        }

        // Create ZIP using ditto (built-in macOS tool)
        let zipURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", tempDir.path, zipURL.path]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw NSError(domain: "ConversationExporter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create ZIP archive"])
        }

        let data = try Data(contentsOf: zipURL)
        try? FileManager.default.removeItem(at: zipURL)
        return data
    }
}
