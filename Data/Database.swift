import Foundation
import GRDB

/// Owns the GRDB connection and schema. All persistence flows through this.
final class AppDatabase {
    let dbQueue: DatabaseQueue

    /// On-disk database at FileLocations.databaseURL.
    static func open() throws -> AppDatabase {
        try FileLocations.prepare()
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(path: FileLocations.databaseURL.path, configuration: config)
        return try AppDatabase(queue: queue)
    }

    /// In-memory database for tests and previews.
    static func inMemory() throws -> AppDatabase {
        try AppDatabase(queue: DatabaseQueue())
    }

    init(queue: DatabaseQueue) throws {
        self.dbQueue = queue
        try migrator.migrate(dbQueue)
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "intents") { t in
                t.column("id", .text).primaryKey()
                t.column("label", .text).notNull()
                t.column("photoRef", .text)
                t.column("respondNote", .text)
                t.column("boardSlot", .integer).unique()
                t.column("createdAt", .datetime).notNull()
                t.column("archivedAt", .datetime)
            }

            try db.create(table: "sessions") { t in
                t.column("id", .text).primaryKey()
                t.column("startedAt", .datetime).notNull()
                t.column("endedAt", .datetime)
                t.column("device", .text).notNull()
            }

            try db.create(table: "segments") { t in
                t.column("id", .text).primaryKey()
                t.column("sessionId", .text).notNull()
                    .references("sessions", onDelete: .cascade)
                t.column("clipRef", .text).notNull()
                t.column("startedAt", .datetime).notNull()
                t.column("durationMs", .integer).notNull()
                t.column("state", .text).notNull()
                t.column("labelledAt", .datetime)
            }
            try db.create(index: "segments_state", on: "segments", columns: ["state", "startedAt"])

            try db.create(table: "exemplars") { t in
                t.column("id", .text).primaryKey()
                t.column("intentId", .text).notNull()
                    .references("intents", onDelete: .cascade)
                t.column("clipRef", .text).notNull()
                t.column("embedding", .blob)
                t.column("device", .text).notNull()
                t.column("contextJSON", .text).notNull()
                t.column("labeller", .text).notNull()
                t.column("timestamp", .datetime).notNull()
                t.column("decayExempt", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "exemplars_intent", on: "exemplars", columns: ["intentId"])

            try db.create(table: "negatives") { t in
                t.column("id", .text).primaryKey()
                t.column("rejectedIntentId", .text).notNull()
                    .references("intents", onDelete: .cascade)
                t.column("clipRef", .text)
                t.column("embedding", .blob)
                t.column("exchangeId", .text)
                t.column("timestamp", .datetime).notNull()
            }

            try db.create(table: "events") { t in
                t.column("id", .text).primaryKey()
                t.column("exchangeId", .text)
                t.column("type", .text).notNull()
                t.column("intentId", .text)
                t.column("latencyMs", .integer)
                t.column("device", .text).notNull()
                t.column("timestamp", .datetime).notNull()
            }
            try db.create(index: "events_type_time", on: "events", columns: ["type", "timestamp"])
        }

        return migrator
    }
}
