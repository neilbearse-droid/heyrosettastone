import Foundation
import GRDB

/// Fills in embeddings for rows that predate the model (all of Phase 1's
/// data) or were captured before the encoder finished loading. Runs in the
/// background at launch; idempotent; failures are skipped and retried on
/// the next run.
struct EmbeddingBackfill {
    let db: AppDatabase
    let embedder: EmbeddingProvider

    /// Returns the number of rows embedded.
    @discardableResult
    func run() async -> Int {
        var embedded = 0
        embedded += await backfillExemplars()
        embedded += await backfillSegments()
        embedded += await backfillNegatives()
        return embedded
    }

    private func embedClip(_ clipRef: String) async -> Data? {
        guard let samples = try? ClipAudioLoader.loadSamples(clipRef: clipRef),
              let vector = try? await embedder.embed(samples: samples)
        else { return nil }
        return EmbeddingCodec.encode(vector)
    }

    private func backfillExemplars() async -> Int {
        let missing = (try? db.dbQueue.read {
            try ExemplarRecord.filter(Column("embedding") == nil).fetchAll($0)
        }) ?? []
        var count = 0
        for exemplar in missing {
            guard let blob = await embedClip(exemplar.clipRef) else { continue }
            try? db.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE exemplars SET embedding = ? WHERE id = ?",
                    arguments: [blob, exemplar.id]
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
        let missing = (try? db.dbQueue.read {
            try SegmentRecord
                .filter(Column("embedding") == nil && Column("state") == SegmentState.pending.rawValue)
                .fetchAll($0)
        }) ?? []
        var count = 0
        for segment in missing {
            guard let blob = await embedClip(segment.clipRef) else { continue }
            try? SessionStore(db: db).updateSegmentEmbedding(id: segment.id, embedding: blob)
            count += 1
        }
        return count
    }

    private func backfillNegatives() async -> Int {
        let missing = (try? db.dbQueue.read {
            try NegativeRecord
                .filter(Column("embedding") == nil && Column("clipRef") != nil)
                .fetchAll($0)
        }) ?? []
        var count = 0
        for negative in missing {
            guard let clipRef = negative.clipRef,
                  let blob = await embedClip(clipRef) else { continue }
            try? db.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE negatives SET embedding = ? WHERE id = ?",
                    arguments: [blob, negative.id]
                )
            }
            count += 1
        }
        return count
    }
}
