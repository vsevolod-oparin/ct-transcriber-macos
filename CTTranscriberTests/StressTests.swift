import XCTest
import SwiftData
@testable import CT_Transcriber

final class StressTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: Conversation.self, Message.self, Attachment.self, BackgroundTask.self,
            configurations: config
        )
    }

    // MARK: - Data Creation

    /// Creates a conversation with N messages of varying content types.
    @MainActor
    private func createStressConversation(messageCount: Int, in context: ModelContext) -> Conversation {
        let conversation = Conversation(title: "Stress Test (\(messageCount) msgs)")
        context.insert(conversation)

        for i in 0..<messageCount {
            let role: MessageRole = i % 2 == 0 ? .user : .assistant
            let content: String

            switch i % 10 {
            case 0:
                // Short message
                content = "Message \(i): Hello, how are you?"
            case 1:
                // Medium assistant response with markdown
                content = """
                **Response \(i)**

                Here are some points:
                - First item with **bold**
                - Second item with *italic*
                - Third item with `code`

                Some follow-up text here.
                """
            case 2:
                // User message with question
                content = "Can you explain how \(["Swift concurrency", "SwiftData", "NSTableView", "markdown rendering", "audio transcription"][i % 5]) works in detail?"
            case 3:
                // Long assistant response with code block
                content = """
                ## Implementation Details

                Here's the code:

                ```swift
                func process(items: [Item]) async throws {
                    for item in items {
                        try await item.validate()
                        let result = try await item.transform()
                        await MainActor.run {
                            self.results.append(result)
                        }
                    }
                }
                ```

                This handles the processing pipeline with proper async/await patterns.
                The key points are:
                1. Each item is validated first
                2. Then transformed asynchronously
                3. Results are collected on the main actor

                Let me know if you need more details.
                """
            case 4:
                // Short user follow-up
                content = "Thanks, that makes sense. What about \(i)?"
            case 5:
                // Transcription-style message with timestamps
                content = """
                **Transcription** (en, \(String(format: "%.1f", Double(i) * 0.3))s)

                [0:00 → 0:05] This is segment number \(i) of the transcription.
                [0:05 → 0:10] It contains multiple lines with timestamps.
                [0:10 → 0:15] Each line represents a spoken segment.
                [0:15 → 0:20] The timestamps are clickable for seeking.
                [0:20 → 0:25] And the text wraps when it gets long enough to demonstrate wrapping behavior in the table view cells.
                """
            case 6:
                // Medium user message
                content = "I have a few questions about message \(i): first, how does the caching work? Second, what about memory management? Third, is there a performance impact?"
            case 7:
                // Assistant with table
                content = """
                Here's a comparison:

                | Feature | Status | Notes |
                |---------|--------|-------|
                | Item \(i)a | Done | Works well |
                | Item \(i)b | Pending | Needs review |
                | Item \(i)c | In Progress | Almost ready |
                """
            case 8:
                // Error message
                content = "⚠ [LLM] Connection timeout after 30 seconds. Please check your API settings."
            default:
                // Very long text (>200 chars)
                content = String(repeating: "This is a longer message for stress testing purposes. ", count: 8) + "Message number \(i)."
            }

            let message = Message(role: role, content: content)
            message.lifecycle = role == .assistant ? .complete : nil
            conversation.messages.append(message)
        }

        try? context.save()
        return conversation
    }

    // MARK: - Stress Tests

    @MainActor
    func testCreate1000Messages() throws {
        let container = try makeContainer()
        let context = container.mainContext

        measure {
            let _ = createStressConversation(messageCount: 1000, in: context)
        }
    }

    @MainActor
    func testFetch1000Messages() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let conversation = createStressConversation(messageCount: 1000, in: context)

        measure {
            let sorted = conversation.messages.sorted { $0.timestamp < $1.timestamp }
            XCTAssertEqual(sorted.count, 1000)
        }
    }

    @MainActor
    func testSortedMessagesWithFilter1000() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let conversation = createStressConversation(messageCount: 1000, in: context)

        measure {
            let sorted = conversation.messages
                .filter { !$0.isDeleted && $0.modelContext != nil }
                .sorted { $0.timestamp < $1.timestamp }
            XCTAssertEqual(sorted.count, 1000)
        }
    }

    @MainActor
    func testMessageHash1000() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let conversation = createStressConversation(messageCount: 1000, in: context)
        let sorted = conversation.messages.sorted { $0.timestamp < $1.timestamp }

        measure {
            for msg in sorted {
                let _ = ChatTableView.messageHash(msg)
            }
        }
    }

    @MainActor
    func testMarkdownParsing1000() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let conversation = createStressConversation(messageCount: 1000, in: context)
        let sorted = conversation.messages.sorted { $0.timestamp < $1.timestamp }

        // Parse markdown for all assistant messages
        measure {
            for msg in sorted where msg.role == .assistant {
                let _ = parseMarkdown(msg.content)
            }
        }
    }

    @MainActor
    func testMessageAnalysis1000() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let conversation = createStressConversation(messageCount: 1000, in: context)
        let sorted = conversation.messages.sorted { $0.timestamp < $1.timestamp }

        measure {
            for msg in sorted {
                let _ = MessageAnalysis(message: msg)
            }
        }
    }

    @MainActor
    func testCreate5000Messages() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let start = CFAbsoluteTimeGetCurrent()
        let conversation = createStressConversation(messageCount: 5000, in: context)
        let createTime = CFAbsoluteTimeGetCurrent() - start

        let sortStart = CFAbsoluteTimeGetCurrent()
        let sorted = conversation.messages.sorted { $0.timestamp < $1.timestamp }
        let sortTime = CFAbsoluteTimeGetCurrent() - sortStart

        let hashStart = CFAbsoluteTimeGetCurrent()
        for msg in sorted {
            let _ = ChatTableView.messageHash(msg)
        }
        let hashTime = CFAbsoluteTimeGetCurrent() - hashStart

        let parseStart = CFAbsoluteTimeGetCurrent()
        for msg in sorted where msg.role == .assistant {
            let _ = parseMarkdown(msg.content)
        }
        let parseTime = CFAbsoluteTimeGetCurrent() - parseStart

        XCTAssertEqual(sorted.count, 5000)

        // Log results
        print("""
        === Stress Test: 5000 Messages ===
        Create + save: \(String(format: "%.1f", createTime * 1000))ms
        Sort: \(String(format: "%.1f", sortTime * 1000))ms
        Hash (all): \(String(format: "%.1f", hashTime * 1000))ms
        Markdown parse (assistant): \(String(format: "%.1f", parseTime * 1000))ms
        Per-message sort: \(String(format: "%.3f", sortTime * 1000 / 5000))ms
        Per-message hash: \(String(format: "%.3f", hashTime * 1000 / 5000))ms
        Per-message parse: \(String(format: "%.3f", parseTime * 1000 / 2500))ms
        ===================================
        """)
    }

    @MainActor
    func testQueryPerformance1000() throws {
        let container = try makeContainer()
        let context = container.mainContext

        // Create 10 conversations with 100 messages each = 1000 total
        for i in 0..<10 {
            let c = createStressConversation(messageCount: 100, in: context)
            c.title = "Conversation \(i)"
        }

        measure {
            let descriptor = FetchDescriptor<Conversation>(
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
            let conversations = try! context.fetch(descriptor)
            XCTAssertEqual(conversations.count, 10)
            // Access messages to trigger faulting
            for c in conversations {
                let _ = c.messages.count
            }
        }
    }

    @MainActor
    func testFilteredConversationsSearch() throws {
        let container = try makeContainer()
        let context = container.mainContext

        // Create 50 conversations with 50 messages each
        for i in 0..<50 {
            let c = createStressConversation(messageCount: 50, in: context)
            c.title = "Topic \(i): \(["Swift", "Python", "Metal", "Audio", "Chat"][i % 5])"
        }
        try context.save()

        let descriptor = FetchDescriptor<Conversation>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        let conversations = try context.fetch(descriptor)
        let query = "swift"

        measure {
            let filtered = conversations.filter { conversation in
                conversation.title.lowercased().contains(query) ||
                conversation.messages.contains { $0.content.lowercased().contains(query) }
            }
            XCTAssertGreaterThan(filtered.count, 0)
        }
    }
}
