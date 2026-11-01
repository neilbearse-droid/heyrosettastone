import Foundation
import GRDB

// Store discipline: a record handed in by a caller is a snapshot and may be
// stale (the capture path writes `segments.embedding` asynchronously after
// insert). Stores therefore never `update(db)` a caller-supplied record;
// they update the specific columns they own with a scoped UPDATE, and
// re-fetch inside the write transaction when they need current values.

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
    /// boardSlot — slot changes go through BoardLayout / BoardStore only (§2.3).
    func updateDetails(id: String, label: String, photoRef: String?, respondNote: String?) throws {
        try db.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE intents SET label = ?, photoRef = ?, respondNote = ? WHERE id = ?",
                arguments: [label, photoRef, respondNote, id]
            )
        }
    }

    /// Archive rather than delete: exemplars stay reviewable (§5.4 spirit).
    /// Hard deletion of an intent and its exemplars is available in
    /// Dictionary behind a confirmation.
    func archive(id: String, at date: Date = Date()) throws {
        try db.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE intents SET archivedAt = ?, boardSlot = NULL WHERE id = ?",
                arguments: [date, id]
            )
        }
    }

    /// "Delete this word and its clips" (§8 full local deletion). Deletes
    /// the intent row (cascading exemplars, negatives and calibration
    /// observations), tombstones the segment rows that shared those clips
    /// as discarded, and removes the clip files — and the word's photo —
    /// from disk. The only clip kept is one that another intent's exemplar
    /// still references, which would otherwise leave that exemplar without
    /// audio; likewise a photo another intent still shows. Returns the
    /// photo ref whose file was removed (nil if none) so the caller can
    /// drop it from `PhotoCache`.
    @discardableResult
    func deleteForever(id: String, now: Date = Date()) throws -> String? {
        let (clipsToRemove, photoToRemove): ([String], String?) = try db.dbQueue.write { db in
            let photoRef = try String.fetchOne(
                db, sql: "SELECT photoRef FROM intents WHERE id = ?", arguments: [id])
            let refs = try String.fetchAll(
                db,
                sql: "SELECT DISTINCT clipRef FROM exemplars WHERE intentId = ?",
                arguments: [id]
            )
            _ = try IntentRecord.deleteOne(db, key: id) // cascades exemplars, negatives
            var removable: [String] = []
            for ref in refs where !FileLocations.isDeleted(clipRef: ref) {
                let stillReferenced = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM exemplars WHERE clipRef = ?", arguments: [ref]) ?? 0
                guard stillReferenced == 0 else { continue }
                try ClipTombstone.tombstoneSegments(db, clipRef: ref, state: .discarded, at: now)
                removable.append(ref)
            }
            var removablePhoto: String?
            if let photoRef {
                let photoStillShown = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM intents WHERE photoRef = ?", arguments: [photoRef]) ?? 0
                if photoStillShown == 0 { removablePhoto = photoRef }
            }
            return (removable, removablePhoto)
        }
        for ref in clipsToRemove {
            ClipTombstone.removeFile(clipRef: ref)
        }
        if let photoToRemove {
            let url = FileLocations.photoURL(id: photoToRemove)
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        return photoToRemove
    }
}

// MARK: - Exemplars

struct ExemplarStore {
    let db: AppDatabase

    /// The single write path for exemplars — the Face ID rule (§2.2). Every
    /// caller is an explicit human confirmation: the Confirm card, the Review
    /// queue, or the Ask flow. Each selected segment becomes one exemplar and
    /// the segment is flagged labelled.
    ///
    /// The segments passed in are treated as a list of ids: each one is
    /// re-fetched inside the transaction so the exemplar carries the
    /// embedding the capture path persisted after the caller's snapshot was
    /// taken, and only `state` / `labelledAt` are written on the segment row.
    /// A segment whose clip has since been deleted (tombstone) is skipped.
    func confirm(segments: [SegmentRecord],
                 intentId: String,
                 device: String,
                 labeller: String,
                 now: Date = Date()) throws -> [ExemplarRecord] {
        try db.dbQueue.write { db in
            var created: [ExemplarRecord] = []
            for snapshot in segments {
                let fresh = try SegmentRecord.fetchOne(db, key: snapshot.id) ?? snapshot
                guard !fresh.isClipDeleted else { continue }

                let context: [String: String] = [
                    "sessionId": fresh.sessionId,
                    "hourOfDay": String(Calendar.current.component(.hour, from: fresh.startedAt)),
                    "station": device,
                ]
                let contextJSON = String(
                    data: try JSONEncoder().encode(context), encoding: .utf8) ?? "{}"
                let exemplar = ExemplarRecord(
                    intentId: intentId,
                    clipRef: fresh.clipRef,
                    embedding: fresh.embedding ?? snapshot.embedding,
                    device: device,
                    contextJSON: contextJSON,
                    labeller: labeller,
                    timestamp: now,
                    sessionId: fresh.sessionId,
                    capturedAt: fresh.startedAt
                )
                try exemplar.insert(db)

                try db.execute(
                    sql: "UPDATE segments SET state = ?, labelledAt = ? WHERE id = ?",
                    arguments: [SegmentState.labelled.rawValue, now, fresh.id]
                )
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
    /// With `deleteClip`, the audio file is removed too (unless another
    /// exemplar still references it) and the segment row that shares the
    /// clip is tombstoned as discarded.
    func delete(id: String, deleteClip: Bool = false, now: Date = Date()) throws {
        let clipToRemove: String? = try db.dbQueue.write { db in
            guard let exemplar = try ExemplarRecord.fetchOne(db, key: id) else { return nil }
            _ = try ExemplarRecord.deleteOne(db, key: id)
            guard deleteClip, !FileLocations.isDeleted(clipRef: exemplar.clipRef) else { return nil }
            let stillReferenced = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM exemplars WHERE clipRef = ?",
                arguments: [exemplar.clipRef]) ?? 0
            guard stillReferenced == 0 else { return nil }
            try ClipTombstone.tombstoneSegments(db, clipRef: exemplar.clipRef, state: .discarded, at: now)
            return exemplar.clipRef
        }
        if let clipToRemove {
            ClipTombstone.removeFile(clipRef: clipToRemove)
        }
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
            try db.execute(
                sql: "UPDATE sessions SET endedAt = ? WHERE id = ?",
                arguments: [date, id]
            )
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

    /// Flips state only (clip kept). For discard / not-him with optional
    /// clip deletion see `SegmentStore.resolve`, which this forwards to.
    func updateSegmentState(id: String, state: SegmentState, at date: Date = Date()) throws {
        try SegmentStore(db: db).resolve(id: id, state: state, deleteClip: false, at: date)
    }

    func updateSegmentEmbedding(id: String, embedding: Data) throws {
        try db.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE segments SET embedding = ? WHERE id = ?",
                arguments: [embedding, id]
            )
        }
    }

    // Conveniences so callers holding a SessionStore need not construct a
    // SegmentStore.

    func discard(id: String, deleteClip: Bool = false, at date: Date = Date()) throws {
        try SegmentStore(db: db).discard(id: id, deleteClip: deleteClip, at: date)
    }

    func markNotHim(id: String, deleteClip: Bool = false, at date: Date = Date()) throws {
        try SegmentStore(db: db).markNotHim(id: id, deleteClip: deleteClip, at: date)
    }
}

/// Segment resolution: discard / not-him / plain state changes, with the
/// option to delete the audio and keep the row as a tombstone.
struct SegmentStore {
    let db: AppDatabase

    func fetch(id: String) throws -> SegmentRecord? {
        try db.dbQueue.read { try SegmentRecord.fetchOne($0, key: id) }
    }

    /// The current rows for these ids, in no particular order; ids with no
    /// row are simply absent. CaptureController.refreshSegmentStates uses
    /// it to drop chips Review has resolved.
    func fetch(ids: [String]) throws -> [SegmentRecord] {
        guard !ids.isEmpty else { return [] }
        return try db.dbQueue.read { db in
            try SegmentRecord.filter(ids.contains(Column("id"))).fetchAll(db)
        }
    }

    /// Review "Discard": noise, TV, etc. With `deleteClip` the file goes
    /// too and `clipRef` becomes `FileLocations.deletedClipRef`.
    func discard(id: String, deleteClip: Bool = false, at date: Date = Date()) throws {
        try resolve(id: id, state: .discarded, deleteClip: deleteClip, at: date)
    }

    /// Review "Not him": someone else's voice. Same deletion option.
    func markNotHim(id: String, deleteClip: Bool = false, at date: Date = Date()) throws {
        try resolve(id: id, state: .notHim, deleteClip: deleteClip, at: date)
    }

    /// Sets `state` (and `labelledAt` for resolved states) with a
    /// column-scoped UPDATE. When `deleteClip` is true and no exemplar still
    /// references the clip, the row is tombstoned and the file removed
    /// after the transaction commits. Nothing else on the row is touched.
    func resolve(id: String, state: SegmentState, deleteClip: Bool, at date: Date = Date()) throws {
        let resolved = state == .labelled || state == .discarded || state == .notHim
        let labelledAt: Date? = resolved ? date : nil
        let clipToRemove: String? = try db.dbQueue.write { db in
            guard let segment = try SegmentRecord.fetchOne(db, key: id) else { return nil }
            try db.execute(
                sql: "UPDATE segments SET state = ?, labelledAt = ? WHERE id = ?",
                arguments: [state.rawValue, labelledAt, id]
            )
            guard deleteClip, !segment.isClipDeleted else { return nil }
            let stillReferenced = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM exemplars WHERE clipRef = ?",
                arguments: [segment.clipRef]) ?? 0
            guard stillReferenced == 0 else { return nil }
            try ClipTombstone.tombstoneSegments(db, clipRef: segment.clipRef, state: state, at: date)
            return segment.clipRef
        }
        if let clipToRemove {
            ClipTombstone.removeFile(clipRef: clipToRemove)
        }
    }
}

/// Shared tombstone mechanics for every deletion path. Rows are kept, the
/// clipRef is replaced by the sentinel, and the file is removed outside
/// the transaction (a failed unlink is retried by Maintenance's orphan
/// sweep, since the row no longer references the file).
enum ClipTombstone {
    /// Marks every segment row sharing `clipRef` as `state` (the caller's
    /// resolution: discarded for prune / delete-forever, the chosen state
    /// for Review) with the clip deleted, and blanks the clipRef on any
    /// exemplar row that still points at it (there should be none; the
    /// callers check first).
    static func tombstoneSegments(_ db: Database, clipRef: String, state: SegmentState, at date: Date) throws {
        guard !FileLocations.isDeleted(clipRef: clipRef) else { return }
        try db.execute(
            sql: """
                UPDATE segments
                SET clipRef = ?, state = ?, labelledAt = ?
                WHERE clipRef = ?
                """,
            arguments: [FileLocations.deletedClipRef, state.rawValue, date, clipRef]
        )
        try db.execute(
            sql: "UPDATE exemplars SET clipRef = ? WHERE clipRef = ?",
            arguments: [FileLocations.deletedClipRef, clipRef]
        )
    }

    static func removeFile(clipRef: String) {
        guard !FileLocations.isDeleted(clipRef: clipRef) else { return }
        let url = FileLocations.clipURL(id: clipRef)
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
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

    /// Also run at launch (Maintenance) and on session open (capture), so
    /// the Confirm card and live guesses never operate on stale segments.
    /// Returns the number of segments flipped.
    @discardableResult
    func sweepExpired(now: Date = Date()) throws -> Int {
        let cutoff = now.addingTimeInterval(-Self.expiryInterval)
        return try db.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE segments SET state = ? WHERE state = ? AND startedAt < ?",
                arguments: [SegmentState.expired.rawValue, SegmentState.pending.rawValue, cutoff]
            )
            return db.changesCount
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

    /// Median ms from exchange open to confirm, per local calendar day —
    /// the §2.9 success metric, shown as a trend in Progress. Bucketing is
    /// done in Swift with `Calendar.current` so an evening confirmation in
    /// North America lands on today, not UTC-tomorrow.
    func confirmLatencies(since: Date, calendar: Calendar = .current) throws -> [(day: Date, medianMs: Int)] {
        let rows = try confirmLatencyRows(since: since)
        var byDay: [Date: [Int]] = [:]
        for row in rows {
            byDay[calendar.startOfDay(for: row.timestamp), default: []].append(row.latencyMs)
        }
        return byDay
            .map { day, values -> (day: Date, medianMs: Int) in
                let sorted = values.sorted()
                return (day: day, medianMs: sorted[sorted.count / 2])
            }
            .sorted { $0.day < $1.day }
    }

    /// The raw (confirmation time, ms from exchange open) pairs behind
    /// `confirmLatencies`, oldest first, for callers that bucket differently
    /// (the SLP report buckets by ISO week and wants a true weekly median,
    /// not a median of daily medians).
    func confirmLatencyRows(since: Date) throws -> [(timestamp: Date, latencyMs: Int)] {
        try db.dbQueue.read { db in
            let fetched = try Row.fetchAll(
                db,
                sql: """
                SELECT timestamp, latencyMs FROM events
                WHERE type = ? AND latencyMs IS NOT NULL AND timestamp >= ?
                ORDER BY timestamp
                """,
                arguments: [EventType.confirm.rawValue, since]
            )
            return fetched.compactMap { row -> (timestamp: Date, latencyMs: Int)? in
                guard let timestamp: Date = row["timestamp"], let ms: Int = row["latencyMs"] else { return nil }
                return (timestamp: timestamp, latencyMs: ms)
            }
        }
    }

    /// True when the exchange reached understanding on a parent or child
    /// surface: a confirm event (Confirm card, Ask flow) or a board tap by
    /// him attached to this exchange id. Capture uses it to avoid logging
    /// an abandon marker for an exchange that was in fact resolved.
    func hasResolution(exchangeId: String) throws -> Bool {
        try db.dbQueue.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS (SELECT 1 FROM events WHERE exchangeId = ? AND type IN (?, ?))",
                arguments: [exchangeId, EventType.confirm.rawValue, EventType.boardTap.rawValue]
            ) ?? false
        }
    }

    /// §2.9 abandoned-exchange rate. Among sessions started since `since`
    /// that captured at least one segment of his, the fraction that never
    /// reached understanding. Resolved: a confirm event or a board tap by
    /// him carries the session id as its exchangeId (he got there through
    /// his AAC, which is understanding), or one of its segments was
    /// labelled within 24 h of the session opening (the Review expiry
    /// window). Abandoned: none of that, and a segment is still pending
    /// past the window, expired, or was labelled only after it. Sessions
    /// younger than 24 h that are still unresolved are undecided, and
    /// sessions whose every segment was discarded or marked "not him"
    /// (TV, a sibling) were never an exchange with him; both are excluded
    /// from both sides. Nil when there is nothing to measure.
    func abandonedRate(since: Date, now: Date = Date()) throws -> Double? {
        let outcomes = try exchangeOutcomes(since: since, now: now)
        let total = outcomes.resolved + outcomes.abandoned
        guard total > 0 else { return nil }
        return Double(outcomes.abandoned) / Double(total)
    }

    /// The counts behind `abandonedRate`, for a positively framed Progress
    /// card ("exchanges that got there: 41 of 48").
    func exchangeOutcomes(since: Date, now: Date = Date()) throws -> (resolved: Int, abandoned: Int) {
        var resolved = 0
        var abandoned = 0
        for session in try sessionOutcomes(since: since, now: now) {
            switch session.outcome {
            case .resolved: resolved += 1
            case .abandoned: abandoned += 1
            case .undecided, .notAnExchange: continue
            }
        }
        return (resolved: resolved, abandoned: abandoned)
    }

    /// How one exchange session ended, by the rules in `abandonedRate`.
    enum ExchangeOutcome: Equatable {
        case resolved
        case abandoned
        /// Still inside the Review window with a segment pending.
        case undecided
        /// Every segment was discarded or "not him": never an exchange with him.
        case notAnExchange
    }

    /// Per-session outcomes for sessions started since `since` that
    /// captured at least one segment, oldest first. `exchangeOutcomes`
    /// totals these; the SLP report buckets them by week.
    func sessionOutcomes(since: Date, now: Date = Date()) throws -> [(sessionId: String, startedAt: Date, outcome: ExchangeOutcome)] {
        try db.dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT s.id AS id, s.startedAt AS startedAt,
                    EXISTS (
                        SELECT 1 FROM events e
                        WHERE e.exchangeId = s.id AND e.type IN (?, ?)
                    ) AS confirmed,
                    (
                        SELECT MIN(g.labelledAt) FROM segments g
                        WHERE g.sessionId = s.id AND g.state = ?
                    ) AS firstLabelledAt,
                    EXISTS (
                        SELECT 1 FROM segments g
                        WHERE g.sessionId = s.id AND g.state = ?
                    ) AS hasPending,
                    EXISTS (
                        SELECT 1 FROM segments g
                        WHERE g.sessionId = s.id AND g.state = ?
                    ) AS hasExpired
                FROM sessions s
                WHERE s.startedAt >= ?
                  AND EXISTS (SELECT 1 FROM segments g WHERE g.sessionId = s.id)
                ORDER BY s.startedAt
                """,
                arguments: [
                    EventType.confirm.rawValue,
                    EventType.boardTap.rawValue,
                    SegmentState.labelled.rawValue,
                    SegmentState.pending.rawValue,
                    SegmentState.expired.rawValue,
                    since,
                ]
            )
            var outcomes: [(sessionId: String, startedAt: Date, outcome: ExchangeOutcome)] = []
            for row in rows {
                guard let id: String = row["id"], let startedAt: Date = row["startedAt"] else { continue }
                let confirmed: Bool = row["confirmed"] ?? false
                let firstLabelledAt: Date? = row["firstLabelledAt"]
                let hasPending: Bool = row["hasPending"] ?? false
                let hasExpired: Bool = row["hasExpired"] ?? false
                let window = startedAt.addingTimeInterval(ReviewQueue.expiryInterval)

                let labelledInTime: Bool
                if let firstLabelledAt {
                    labelledInTime = firstLabelledAt <= window
                } else {
                    labelledInTime = false
                }

                let outcome: ExchangeOutcome
                if confirmed || labelledInTime {
                    outcome = .resolved
                } else if hasPending && now < window {
                    outcome = .undecided // still in the Review window
                } else if hasPending || hasExpired || firstLabelledAt != nil {
                    outcome = .abandoned
                } else {
                    // Every segment was discarded or "not him": not an
                    // exchange with him, so neither side counts it.
                    outcome = .notAnExchange
                }
                outcomes.append((sessionId: id, startedAt: startedAt, outcome: outcome))
            }
            return outcomes
        }
    }
}
