import Foundation
import SwiftData

/// Schema versioning for SwiftData models.
/// When adding new required fields or changing model structure,
/// create a new schema version and a migration plan.
enum SchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Conversation.self, Message.self, Attachment.self, BackgroundTask.self]
    }
}

enum CTTranscriberMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self]
    }

    static var stages: [MigrationStage] {
        // No migrations yet — first version.
        // When adding SchemaV2, add a migration stage here:
        // .lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self)
        []
    }
}
