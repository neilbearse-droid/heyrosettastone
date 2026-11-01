import Foundation
import GRDB

/// Clips that could not be loaded in this process (file missing, deleted
/// tombstone, unreadable). Remembered in memory only: a clip that is gone
/// is not going to reappear during this run, and retrying it on every
/// launch and every reload was wasted encoder time. A relaunch retries,
/// which is what you want after a restore or an import.
final class MissingClipRegistry: @unchecked Sendable {
    static let shared = MissingClipRegistry()

    private let lock = NSLock()
    private var refs: Set<String> = []

    func contains(_ clipRef: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return refs.contains(clipRef)
    }

    func insert(_ clipRef: String) {
        lock.lock()
        refs.insert(clipRef)
        lock.unlock()
    }

    /// For tests and for an import that may have brought clips back.
    func removeAll() {
        lock.lock()
        refs.removeAll()
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return refs.count
    }
}

/// Fills in embeddings for rows that predate the model (all of Phase 1's
/// data) or were captured before the encoder finished loading. Runs in the
/// background at launch; idempotent. Rows whose clip is missing are skipped
/// for the rest of the process (see `MissingClipRegistry`).
///
/// Order of work: first one SQL statement copies every embedding a segment
/// already has onto the exemplar (and negative) rows sharing its clip —
/// confirm used to write nil over them — so only genuinely un-encoded
/// clips reach the encoder.
struct EmbeddingBackfill {
    let db: AppDatabase
    let embedder: EmbeddingProvider
    /// When set, pending segments are embedded through this (the engine's
    /// per-segment cache), so a segment the Confirm card is ranking right
    /// now is encoded once, not once here and once there.
    let embedSegment: (@Sendable (SegmentRecord) async -> Data?)?

    init(db: AppDatabase,
         embedder: EmbeddingProvider,
         embedSegment: (@Sendable (SegmentRecord) async -> Data?)? = nil) {
        self.db = db
        self.embedder = embedder
        self.embedSegment = embedSegment
    }

    /// Returns the number of rows embedded by the encoder (copies excluded).
    @discardableResult
    func run() async -> Int {
        await copyEmbeddingsFromSegments()
        var embedded = 0
        embedded += await backfillExemplars()
        embedded += await backfillSegments()
        embedded += await backfillNegatives()
        return embedded
    }

    /// Exemplar and negative rows share a clip with the segment they came
    /// from; whatever embedding the segment already carries is copied over
    /// in one statement each. Rows with no matching embedded segment stay
    /// NULL (the subquery yields NULL) and are encoded below. The deletion
    /// tombstone (`FileLocations.deletedClipRef`) is shared by every row
    /// whose audio is gone, so it is excluded from the join: it must never
    /// copy some unrelated deleted clip's vector onto a row.
    func copyEmbeddingsFromSegments() async {
        // In async contexts Swift resolves GRDB's read/write to the async
        // overloads, hence the awaits throughout this file.
        let tombstone = FileLocations.deletedClipRef
        try? await db.dbQueue.write { db in
            try db.execute(sql: """
                UPDATE exemplars SET embedding = (
                    SELECT s.embedding FROM segments s
                    WHERE s.clipRef = exemplars.clipRef AND s.embedding IS NOT NULL
                    LIMIT 1
                )
                WHERE embedding IS NULL AND clipRef != ?
                """, arguments: [tombstone])
            try db.execute(sql: """
                UPDATE negatives SET embedding = (
                    SELECT s.embedding FROM segments s
                    WHERE s.clipRef = negatives.clipRef AND s.embedding IS NOT NULL
                    LIMIT 1
                )
                WHERE embedding IS NULL AND clipRef IS NOT NULL AND clipRef != ?
                """, arguments: [tombstone])
        }
    }

    /// Loads and encodes one clip. Nil (and remembered) when the clip is
    /// missing or unreadable; nil (not remembered) when the encoder fails.
    static func embedClip(_ clipRef: String, embedder: EmbeddingProvider) async -> Data? {
        let registry = MissingClipRegistry.shared
        guard !registry.contains(clipRef) else { return nil }
        guard ClipAudioLoader.clipExists(clipRef: clipRef) else {
            registry.insert(clipRef)
            return nil
        }
        let samples: [Float]
        do {
            samples = try ClipAudioLoader.loadSamples(clipRef: clipRef)
        } catch {
            registry.insert(clipRef)
            return nil
        }
        guard let vector = try? await embedder.embed(samples: samples) else { return nil }
        return EmbeddingCodec.encode(vector)
    }

    private func embedClip(_ clipRef: String) async -> Data? {
        await Self.embedClip(clipRef, embedder: embedder)
    }

    private func backfillExemplars() async -> Int {
        let missing = (try? await db.dbQueue.read {
            try ExemplarRecord.filter(Column("embedding") == nil).fetchAll($0)
        }) ?? []
        var count = 0
        for exemplar in missing {
            guard let blob = await embedClip(exemplar.clipRef) else { continue }
            let id = exemplar.id
            let clipRef = exemplar.clipRef
            try? await db.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE exemplars SET embedding = ? WHERE id = ?",
                    arguments: [blob, id]
                )
                // Keep the segment sharing this clip in step so nothing
                // re-encodes it later.
                try db.execute(
                    sql: "UPDATE segments SET embedding = ? WHERE clipRef = ? AND embedding IS NULL",
                    arguments: [blob, clipRef]
                )
            }
            count += 1
        }
        return count
    }

    private func backfillSegments() async -> Int {
        // Only pending segments matter — they may still be labelled, and the
        // Confirm card ranks them. Resolved segments' audio lives on via the
        // exemplar rows.
        let missing = (try? await db.dbQueue.read {
            try SegmentRecord
                .filter(Column("embedding") == nil && Column("state") == SegmentState.pending.rawValue)
                .fetchAll($0)
        }) ?? []
        var count = 0
        for segment in missing {
            if let embedSegment {
                // The engine's cache loads, encodes, and persists.
                if await embedSegment(segment) != nil { count += 1 }
                continue
            }
            guard let blob = await embedClip(segment.clipRef) else { continue }
            try? SessionStore(db: db).updateSegmentEmbedding(id: segment.id, embedding: blob)
            count += 1
        }
        return count
    }

    private func backfillNegatives() async -> Int {
        let missing = (try? await db.dbQueue.read {
            try NegativeRecord
                .filter(Column("embedding") == nil && Column("clipRef") != nil)
                .fetchAll($0)
        }) ?? []
        var count = 0
        for negative in missing {
            guard let clipRef = negative.clipRef,
                  let blob = await embedClip(clipRef) else { continue }
            let id = negative.id
            try? await db.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE negatives SET embedding = ? WHERE id = ?",
                    arguments: [blob, id]
                )
            }
            count += 1
        }
        return count
    }
}
