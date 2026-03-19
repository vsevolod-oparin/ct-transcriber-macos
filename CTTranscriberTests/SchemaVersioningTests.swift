import XCTest
import SwiftData
@testable import CT_Transcriber

final class SchemaVersioningTests: XCTestCase {

    // MARK: - Schema definition tests

    func testSchemaV1ContainsAllModels() {
        let models = SchemaV1.models
        XCTAssertEqual(models.count, 4, "SchemaV1 should contain exactly 4 model types")

        let typeNames = Set(models.map { String(describing: $0) })
        XCTAssertTrue(typeNames.contains("Conversation"), "SchemaV1 must include Conversation")
        XCTAssertTrue(typeNames.contains("Message"), "SchemaV1 must include Message")
        XCTAssertTrue(typeNames.contains("Attachment"), "SchemaV1 must include Attachment")
        XCTAssertTrue(typeNames.contains("BackgroundTask"), "SchemaV1 must include BackgroundTask")
    }

    func testSchemaV1VersionIdentifier() {
        XCTAssertEqual(SchemaV1.versionIdentifier, Schema.Version(1, 0, 0))
    }

    func testMigrationPlanHasSchemaV1() {
        let schemas = CTTranscriberMigrationPlan.schemas
        XCTAssertEqual(schemas.count, 1, "Migration plan should have exactly 1 schema version")
        XCTAssertTrue(schemas.first == SchemaV1.self, "The only schema should be SchemaV1")
    }

    func testMigrationPlanStagesEmpty() {
        XCTAssertTrue(CTTranscriberMigrationPlan.stages.isEmpty,
                      "Single-version migration plan should have no stages")
    }

    // MARK: - Container creation

    func testModelContainerCreation() throws {
        let container = CTTranscriberApp.makeModelContainer(inMemory: true)
        XCTAssertNotNil(container, "In-memory ModelContainer should be created successfully")
        // Verify the schema contains our model types by checking the container's schema
        let schema = container.schema
        let entityNames = Set(schema.entities.map(\.name))
        XCTAssertTrue(entityNames.contains("Conversation"))
        XCTAssertTrue(entityNames.contains("Message"))
        XCTAssertTrue(entityNames.contains("Attachment"))
        XCTAssertTrue(entityNames.contains("BackgroundTask"))
    }

    // MARK: - CRUD round-trip

    @MainActor
    func testModelContainerCRUD() throws {
        let container = CTTranscriberApp.makeModelContainer(inMemory: true)
        let context = container.mainContext

        // Create a conversation with a message and attachment
        let conversation = Conversation(title: "Schema Test Conversation")
        context.insert(conversation)

        let message = Message(role: .user, content: "Hello from schema test")
        message.conversation = conversation
        conversation.messages.append(message)

        let attachment = Attachment(kind: .audio, storedName: "test-uuid.mp3", originalName: "recording.mp3")
        attachment.message = message
        message.attachments.append(attachment)

        try context.save()

        // Fetch and verify
        let descriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate { $0.title == "Schema Test Conversation" }
        )
        let fetched = try context.fetch(descriptor)
        XCTAssertEqual(fetched.count, 1)

        let fetchedConversation = try XCTUnwrap(fetched.first)
        XCTAssertEqual(fetchedConversation.title, "Schema Test Conversation")
        XCTAssertEqual(fetchedConversation.messages.count, 1)

        let fetchedMessage = try XCTUnwrap(fetchedConversation.messages.first)
        XCTAssertEqual(fetchedMessage.role, .user)
        XCTAssertEqual(fetchedMessage.content, "Hello from schema test")
        XCTAssertEqual(fetchedMessage.attachments.count, 1)

        let fetchedAttachment = try XCTUnwrap(fetchedMessage.attachments.first)
        XCTAssertEqual(fetchedAttachment.kind, .audio)
        XCTAssertEqual(fetchedAttachment.storedName, "test-uuid.mp3")
        XCTAssertEqual(fetchedAttachment.originalName, "recording.mp3")
    }

    // MARK: - MessageLifecycle round-trip

    @MainActor
    func testMessageLifecyclePersistedAndFetched() throws {
        let container = CTTranscriberApp.makeModelContainer(inMemory: true)
        let context = container.mainContext

        let conversation = Conversation(title: "Lifecycle Test")
        context.insert(conversation)

        let message = Message(role: .assistant, content: "Streaming response...")
        message.lifecycle = .streaming
        message.conversation = conversation
        conversation.messages.append(message)

        try context.save()

        // Fetch back and verify lifecycle survived round-trip
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { $0.content == "Streaming response..." }
        )
        let fetched = try context.fetch(descriptor)
        XCTAssertEqual(fetched.count, 1)

        let fetchedMessage = try XCTUnwrap(fetched.first)
        XCTAssertEqual(fetchedMessage.lifecycle, .streaming,
                       "MessageLifecycle should survive persistence round-trip")
    }

    @MainActor
    func testMessageLifecycleNilByDefault() throws {
        let container = CTTranscriberApp.makeModelContainer(inMemory: true)
        let context = container.mainContext

        let conversation = Conversation(title: "Nil Lifecycle Test")
        context.insert(conversation)

        let message = Message(role: .user, content: "No lifecycle set")
        message.conversation = conversation
        conversation.messages.append(message)

        try context.save()

        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { $0.content == "No lifecycle set" }
        )
        let fetched = try context.fetch(descriptor)
        let fetchedMessage = try XCTUnwrap(fetched.first)
        XCTAssertNil(fetchedMessage.lifecycle,
                     "lifecycle should be nil when not explicitly set")
    }
}
