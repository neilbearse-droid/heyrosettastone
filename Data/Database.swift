import Foundation
import GRDB

/// Owns the GRDB connection and schema. All persistence flows through this.
final class AppDatabase {
    let dbQueue: DatabaseQueue

    /// On-disk database at FileLocations.databaseURL.
    static func open() throws -> AppDatabase {
        // The Settings toggle persists here; passing it through is what
        // keeps clips in (or out of) the backup across launches.
        try FileLocations.prepare(
            includeAudioInBackup: UserDefaults.standard.bool(forKey: "includeAudioInBackup")
        )
        var config = Configuration()
        config.foreignKeysEnabled = true
        // Full local deletion (§8): overwrite freed pages with zeros so a
        // deleted label, embedding or event does not linger in the file.
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA secure_delete = ON")
        }
        let queue = try DatabaseQueue(path: FileLocations.databaseURL.path, configuration: config)
        return try AppDatabase(queue: queue)
    }

    /// In-memory database for tests and previews.
    static func inMemory() throws -> AppDatabase {
        try AppDatabase(queue: DatabaseQueue())
    }

    init(queue: DatabaseQueue) throws {
        self.dbQueue = queue
        try Self.migrator.migrate(dbQueue)
    }

    /// Exposed (not private) so tests can migrate a queue part-way with
    /// `migrator.migrate(queue, upTo:)`, seed old-schema rows, and then
    /// check what the later migrations do to them.
    static var migrator: DatabaseMigrator {
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

        // Phase 2: ranking. Segments carry their embedding from capture time
        // so the Confirm card ranks without re-encoding, and calibration
        // observations record (score, accepted) pairs per intent so each
        // word learns its own threshold (§5.2).
        migrator.registerMigration("v2-ranking") { db in
            try db.alter(table: "segments") { t in
                t.add(column: "embedding", .blob)
            }

            try db.create(table: "calibrationObservations") { t in
                t.column("id", .text).primaryKey()
                t.column("intentId", .text).notNull()
                    .references("intents", onDelete: .cascade)
                t.column("score", .double).notNull()
                t.column("accepted", .boolean).notNull()
                t.column("timestamp", .datetime).notNull()
            }
            try db.create(index: "calibration_intent", on: "calibrationObservations", columns: ["intentId"])
        }

        // v3: exemplars remember when and in which exchange the utterance
        // was captured (hour-of-day prior must use capture time, maturity
        // holds out whole sessions), plus the indexes the stores and the
        // maintenance sweeps query on. Back-fills from the segment that
        // shares the clip; falls back to the confirmation timestamp.
        migrator.registerMigration("v3-capture-context") { db in
            try db.alter(table: "exemplars") { t in
                t.add(column: "sessionId", .text)
                t.add(column: "capturedAt", .datetime)
            }
            try db.execute(sql: """
                UPDATE exemplars SET capturedAt = (
                    SELECT s.startedAt FROM segments s
                    WHERE s.clipRef = exemplars.clipRef
                    LIMIT 1
                )
                WHERE capturedAt IS NULL
                """)
            try db.execute(sql: "UPDATE exemplars SET capturedAt = timestamp WHERE capturedAt IS NULL")
            try db.execute(sql: """
                UPDATE exemplars SET sessionId = (
                    SELECT s.sessionId FROM segments s
                    WHERE s.clipRef = exemplars.clipRef
                    LIMIT 1
                )
                WHERE sessionId IS NULL
                """)

            try db.create(index: "segments_session", on: "segments", columns: ["sessionId"])
            try db.create(index: "segments_clip", on: "segments", columns: ["clipRef"])
            try db.create(index: "exemplars_clip", on: "exemplars", columns: ["clipRef"])
            try db.create(index: "negatives_intent", on: "negatives", columns: ["rejectedIntentId"])
        }

        // v4: a shown-guess observation remembers which exchange it was
        // shown in and which feature definition scored it. The exchange id
        // lets Progress measure the Phase 2 acceptance criterion in-app
        // (was his word among the guesses at the yes moment?); the version
        // lets a feature change retire old rows exactly instead of by
        // timestamp. Nullable, no back-fill: rows that predate v4 keep
        // falling back to `CalibrationFeature.versionCutoff`.
        migrator.registerMigration("v4-outcome-context") { db in
            try db.alter(table: "calibrationObservations") { t in
                t.add(column: "exchangeId", .text)
                t.add(column: "featureVersion", .integer)
            }
            try db.create(index: "calibration_exchange", on: "calibrationObservations", columns: ["exchangeId"])
            try db.create(index: "negatives_exchange", on: "negatives", columns: ["exchangeId"])
        }

        return migrator
    }
}
