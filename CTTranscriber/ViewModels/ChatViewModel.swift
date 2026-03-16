import Foundation
import SwiftUI

@Observable
final class ChatViewModel {
    var conversations: [Conversation] = []
    var selectedConversationID: UUID?
    var messageText: String = ""

    var selectedConversation: Conversation? {
        conversations.first { $0.id == selectedConversationID }
    }

    init() {
        // Seed with mock data
        let conv1 = Conversation(title: "Meeting Notes Transcription")
        conv1.createdAt = Date().addingTimeInterval(-86400 * 2)
        conv1.updatedAt = Date().addingTimeInterval(-86400)
        conv1.messages = [
            Message(role: .user, content: "Please transcribe the attached meeting recording."),
            Message(role: .assistant, content: "I've transcribed the audio. The meeting covered Q3 roadmap planning with 5 action items identified."),
            Message(role: .user, content: "Can you summarize the key decisions?"),
            Message(role: .assistant, content: "Key decisions from the meeting:\n\n1. Launch date moved to October 15\n2. Budget approved for new ML infrastructure\n3. Team expansion: 2 new engineers\n4. Weekly sync moved to Thursdays\n5. Documentation sprint planned for next month"),
        ]

        let conv2 = Conversation(title: "Podcast Episode 42")
        conv2.createdAt = Date().addingTimeInterval(-3600 * 5)
        conv2.updatedAt = Date().addingTimeInterval(-3600)
        conv2.messages = [
            Message(role: .user, content: "Transcribe this podcast episode about AI in healthcare."),
            Message(role: .assistant, content: "Transcription complete. The episode discusses three main topics: diagnostic AI, drug discovery, and patient data privacy."),
        ]

        let conv3 = Conversation(title: "Lecture: Intro to ML")
        conv3.createdAt = Date().addingTimeInterval(-86400 * 7)
        conv3.updatedAt = Date().addingTimeInterval(-86400 * 5)
        conv3.messages = [
            Message(role: .user, content: "Here's a recording of today's ML lecture."),
            Message(role: .assistant, content: "Transcription of the lecture is ready. Topics covered: supervised learning, loss functions, and gradient descent basics."),
            Message(role: .user, content: "What were the recommended readings mentioned?"),
            Message(role: .assistant, content: "The professor recommended:\n- \"Pattern Recognition and Machine Learning\" by Bishop\n- \"Deep Learning\" by Goodfellow et al.\n- Stanford CS229 lecture notes (available online)"),
        ]

        conversations = [conv1, conv2, conv3]
    }

    func createConversation() {
        let conversation = Conversation()
        conversations.insert(conversation, at: 0)
        selectedConversationID = conversation.id
    }

    func renameConversation(_ conversation: Conversation, to newTitle: String) {
        conversation.title = newTitle
        conversation.updatedAt = Date()
    }

    func deleteConversation(_ conversation: Conversation) {
        conversations.removeAll { $0.id == conversation.id }
        if selectedConversationID == conversation.id {
            selectedConversationID = conversations.first?.id
        }
    }

    func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let conversation = selectedConversation else { return }

        let message = Message(role: .user, content: text)
        conversation.messages.append(message)
        conversation.updatedAt = Date()
        messageText = ""

        // Move conversation to top
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            let conv = conversations.remove(at: index)
            conversations.insert(conv, at: 0)
        }
    }
}
