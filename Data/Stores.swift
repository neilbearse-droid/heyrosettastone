import Foundation
import GRDB

// MARK: - Intents

struct IntentStore {
    let db: AppDatabase

    func all(includeArchived: Bool = false) throws -> [IntentRecord] {
        try db.dbQueue.read { db in
            var request = IntentRecord.order(Column("label"))
            if !includeArchived {
                request = request.filter(Column("archivedAt") == nil)
            }
            return try request.fetchAll(db)
        }
    }

    func fetch(id: String) throws -> IntentRecord? {
        try db.dbQueue.read { try IntentRecord.fetchOne($0, key: id) }
    }

    func insert(_ intent: IntentRecord) throws {
        try db.dbQueue.write { try intent.insert($0) }
    }

    /// Updates label, photo, and respond-note. Deliberately does NOT touch
    /// boardSlot — slot changes go through BoardLayout only (§2.3).
    func updateDetails(id: String, label: String, photoRef: String?, respondNote: String?) throws {
        try db.dbQueue.write { db in
            guard var intent = try IntentRecord.fetchOne(db, key: id) else { return }
            intent.label = label
            intent.photoRef = photoRef
            intent.respondNote = respondNote
            try intent.update(db)
        }
    }

    /// Archive rather than delete: exemplars stay reviewable (§5.4 spirit).
    /// Hard deletion of an intent and its exemplars is available in
    /// Dictionary behind a confirmation.
    func archive(id: String) throws {
        try db.dbQueue.write { db in
            guard var intent = try IntentRecord.fetchOne(db, key: id) else { return }
            intent.archivedAt = Date()
            intent.boardSlot = nil
            try intent.update(db)
        }
    }

    func deleteForever(id: String) throws {
        let clips: [String] = try db.dbQueue.write { db in
            let refs = try String.fetchAll(
                db,
                sql: "SELECT clipRef FROM exemplars WHERE intentId = ?",
                arguments: [id]
            )
            _ = try IntentRecord.deleteOne(db, key: id) // cascades exemplars, negatives
            return refs
        }
        // Only remove clip files no longer referenced by any segment or exemplar.
        for ref in clips {
            if (try? isClipReferenced(ref)) == false {
                try? FileManager.default.removeItem(at: FileLocations.clipURL(id: ref))
            }
        }
    }

    private func isClipReferenced(_ ref: String) throws -> Bool {
        try db.dbQueue.read { db in
            let inExemplars = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM exemplars WHERE clipRef = ?", arguments: [ref]) ?? 0
            let inSegments = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM segments WHERE clipRef = ?", arguments: [ref]) ?? 0
            return inExemplars + inSegments > 0
        }
    }
}

// MARK: - Exemplars

struct ExemplarStore {
    let db: AppDatabase

    /// The single write path for exemplars — the Face ID rule (§2.2). Every
    /// caller is an explicit human confirmation: the Confirm card, the Review
    /// queue, or the Ask flow. Each selected segment becomes one exemplar and
    /// the segment is flagged labelled.
    func confirm(segments: [SegmentRecord],
                 intentId: String,
                 device: String,
                 labeller: String,
                 now: Date = Date()) throws -> [ExemplarRecord] {
        try db.dbQueue.write { db in
            var created: [ExemplarRecord] = []
            for segment in segments {
                let context: [String: String] = [
                    "sessionId": segment.sessionId,
                    "hourOfDay": String(Calendar.current.component(.hour, from: segment.startedAt)),
                    "station": device,
                ]
                let contextJSON = String(
                    data: try JSONEncoder().encode(context), encoding: .utf8) ?? "{}"
                let exemplar = ExemplarRecord(
                    intentId: intentId,
                    clipRef: segment.clipRef,
                    embedding: segment.embedding,
                    device: device,
                    contextJSON: contextJSON,
                    labeller: labeller,
                    timestamp: now
                )
                try exemplar.insert(db)

                var updated = segment
                updated.state = SegmentState.labelled.rawValue
                updated.labelledAt = now
                try updated.update(db)
                created.append(exemplar)
            }
            return created
        }
    }

    func forIntent(_ intentId: String) throws -> [ExemplarRecord] {
        try db.dbQueue.read {
            try ExemplarRecord
                .filter(Column("intentId") == intentId)
                .order(Column("timestamp").desc)
                .fetchAll($0)
        }
    }

    func count(intentId: String) throws -> Int {
        try db.dbQueue.read {
            try ExemplarRecord.filter(Column("intentId") == intentId).fetchCount($0)
        }
    }

    func totalCount() throws -> Int {
        try db.dbQueue.read { try ExemplarRecord.fetchCount($0) }
    }

    /// Pruning one mislabelled clip without corrupting the class (§5.2).
    func delete(id: String) throws {
        try db.dbQueue.write { _ = try ExemplarRecord.deleteOne($0, key: id) }
    }

    func recordNegative(_ negative: NegativeRecord) throws {
        try db.dbQueue.write { try negative.insert($0) }
    }
}

// MARK: - Sessions & segments

struct SessionStore {
    let db: AppDatabase

    func insert(_ session: SessionRecord) throws {
        try db.dbQueue.write { try session.insert($0) }
    }

    func close(id: String, at date: Date) throws {
        try db.dbQueue.write { db in
            guard var session = try SessionRecord.fetchOne(db, key: id) else { return }
            session.endedAt = date
            try session.update(db)
        }
    }

    func insertSegment(_ segment: SegmentRecord) throws {
        try db.dbQueue.write { try segment.insert($0) }
    }

    func segments(sessionId: String) throws -> [SegmentRecord] {
        try db.dbQueue.read {
            try SegmentRecord
                .filter(Column("sessionId") == sessionId)
                .order(Column("startedAt"))
                .fetchAll($0)
        }
    }

    func updateSegmentState(id: String, state: SegmentState, at date: Date = Date()) throws {
        try db.dbQueue.write { db in
            guard var segment = try SegmentRecord.fetchOne(db, key: id) else { return }
            segment.state = state.rawValue
            segment.labelledAt = (state == .labelled || state == .discarded || state == .notHim) ? date : nil
            try segment.update(db)
        }
    }

    func updateSegmentEmbedding(id: String, embedding: Data) throws {
        try db.dbQueue.write { db in
            guard var segment = try SegmentRecord.fetchOne(db, key: id) else { return }
            segment.embedding = embedding
            try segment.update(db)
        }
    }
}

// MARK: - Calibration

struct CalibrationStore {
    let db: AppDatabase

    func record(_ observation: CalibrationObservationRecord) throws {
        try db.dbQueue.write { try observation.insert($0) }
    }

    func observations(intentId: String) throws -> [CalibrationObservationRecord] {
        try db.dbQueue.read {
            try CalibrationObservationRecord
                .filter(Column("intentId") == intentId)
                .order(Column("timestamp"))
                .fetchAll($0)
        }
    }
}

// MARK: - Review queue

/// The deferred labelling queue (§4.4). Segments expire after 24 h because
/// parental memory of what he meant goes stale. Expired segments are never
/// deleted — they flip to .expired and stay on disk.
struct ReviewQueue {
    static let expiryInterval: TimeInterval = 24 * 60 * 60

    let db: AppDatabase

    /// Flags pending segments older than 24 h as expired, then returns what
    /// remains labellable, oldest first. Call on queue load.
    func pending(now: Date = Date()) throws -> [SegmentRecord] {
        try sweepExpired(now: now)
        return try db.dbQueue.read {
            try SegmentRecord
                .filter(Column("state") == SegmentState.pending.rawValue)
                .order(Column("startedAt"))
                .fetchAll($0)
        }
    }

    func expired() throws -> [SegmentRecord] {
        try db.dbQueue.read {
            try SegmentRecord
                .filter(Column("state") == SegmentState.expired.rawValue)
                .order(Column("startedAt").desc)
                .fetchAll($0)
        }
    }

    func sweepExpired(now: Date = Date()) throws {
        let cutoff = now.addingTimeInterval(-Self.expiryInterval)
        try db.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE segments SET state = ? WHERE state = ? AND startedAt < ?",
                arguments: [SegmentState.expired.rawValue, SegmentState.pending.rawValue, cutoff]
            )
        }
    }
}

// MARK: - Events

struct EventLog {
    let db: AppDatabase

    func log(_ event: EventRecord) throws {
        try db.dbQueue.write { try event.insert($0) }
    }

    /// Confirmation counts per intent, most frequent first — drives the
    /// frequency-sorted grid on the Confirm card and Phase 2 priors.
    func confirmCounts() throws -> [String: Int] {
        try db.dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT intentId, COUNT(*) AS n FROM events
                WHERE type IN (?, ?) AND intentId IS NOT NULL
                GROUP BY intentId
                """,
                arguments: [EventType.confirm.rawValue, EventType.boardTap.rawValue]
            )
            var counts: [String: Int] = [:]
            for row in rows {
                if let id: String = row["intentId"] { counts[id] = row["n"] }
            }
            return counts
        }
    }

    /// Median ms from exchange open to confirm, per day — the §2.9 success
    /// metric, shown as a trend in Progress.
    func confirmLatencies(since: Date) throws -> [(day: Date, medianMs: Int)] {
        try db.dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT date(timestamp) AS day, latencyMs FROM events
                WHERE type = ? AND latencyMs IS NOT NULL AND timestamp >= ?
                ORDER BY day
                """,
                arguments: [EventType.confirm.rawValue, since]
            )
            var byDay: [String: [Int]] = [:]
            for row in rows {
                guard let day: String = row["day"], let ms: Int = row["latencyMs"] else { continue }
                byDay[day, default: []].append(ms)
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = TimeZone(identifier: "UTC")
            return byDay.compactMap { day, values in
                guard let date = formatter.date(from: day) else { return nil }
                let sorted = values.sorted()
                return (day: date, medianMs: sorted[sorted.count / 2])
            }
            .sorted { $0.day < $1.day }
        }
    }
}
