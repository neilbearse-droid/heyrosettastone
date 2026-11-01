import Foundation
import GRDB

/// Launch-time housekeeping. Everything here is idempotent and safe to run
/// before capture starts; call `runAtLaunch` once from the app after the
/// database opens and before `startListening`. Each sweep is also callable
/// on its own (tests, Settings).
enum Maintenance {
    /// Clip files for discarded / not-him segments are kept this long so a
    /// mistaken tap can still be undone from the expired list, then removed
    /// (B5: unbounded storage growth). Expired segments are never swept —
    /// spec §4.4 keeps them on disk.
    static let retentionInterval: TimeInterval = 7 * 24 * 60 * 60

    /// A session can last at most 90 s (§4.2). One left open by a force-quit
    /// or crash is closed at `startedAt + sessionCap`.
    static let sessionCap: TimeInterval = 90

    /// Files in the clips directory newer than this are left alone by the
    /// orphan sweep: the capture path writes the clip before inserting its
    /// row, so a very fresh row-less file may be mid-insert.
    static let orphanGrace: TimeInterval = 60

    struct Report: Equatable {
        var expiredSegments = 0
        var closedSessions = 0
        var temporaryFilesRemoved = 0
        var orphanClipsRemoved = 0
        var retentionClipsRemoved = 0
    }

    /// Runs every sweep in order and finishes with `PRAGMA optimize`:
    /// Review expiry (24 h), open-session close, `.tmp` partial clips,
    /// retention (7 d) for discarded / not-him audio, then row-less clips.
    @discardableResult
    static func runAtLaunch(db: AppDatabase, now: Date = Date()) throws -> Report {
        var report = Report()
        report.expiredSegments = try ReviewQueue(db: db).sweepExpired(now: now)
        report.closedSessions = try closeOpenSessions(db: db, now: now)
        report.temporaryFilesRemoved = sweepTemporaryFiles(in: FileLocations.clips)
        report.retentionClipsRemoved = try retentionSweep(db: db, now: now)
        report.orphanClipsRemoved = try sweepOrphanClips(db: db, now: now)
        try db.dbQueue.write { db in
            try db.execute(sql: "PRAGMA optimize")
        }
        return report
    }

    // MARK: - Sweeps

    /// Closes sessions with no `endedAt` whose cap has passed, at
    /// `startedAt + 90 s`. A session younger than the cap could be the live
    /// one if this is called while listening, so it is left alone.
    @discardableResult
    static func closeOpenSessions(db: AppDatabase, now: Date = Date()) throws -> Int {
        let staleBefore = now.addingTimeInterval(-sessionCap)
        return try db.dbQueue.write { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, startedAt FROM sessions WHERE endedAt IS NULL AND startedAt < ?",
                arguments: [staleBefore]
            )
            var closed = 0
            for row in rows {
                guard let id: String = row["id"], let startedAt: Date = row["startedAt"] else { continue }
                try db.execute(
                    sql: "UPDATE sessions SET endedAt = ? WHERE id = ? AND endedAt IS NULL",
                    arguments: [startedAt.addingTimeInterval(sessionCap), id]
                )
                closed += db.changesCount
            }
            return closed
        }
    }

    /// Removes `*.tmp` partial writes left by a kill mid-clip (A6). The
    /// segment writer stages clips as `<id>.m4a.tmp` then renames, and owns
    /// the sweep; this just delegates so launch housekeeping has one entry
    /// point. Returns the number removed.
    @discardableResult
    static func sweepTemporaryFiles(in directory: URL) -> Int {
        SegmentWriter.sweepTemporaryFiles(in: directory)
    }

    /// Deletes clip files no row references (segments, exemplars or
    /// negatives), skipping files modified within `orphanGrace`. Returns
    /// the number removed.
    @discardableResult
    static func sweepOrphanClips(db: AppDatabase, now: Date = Date()) throws -> Int {
        let referenced: Set<String> = try db.dbQueue.read { db in
            var refs = Set<String>()
            try refs.formUnion(String.fetchAll(db, sql: "SELECT clipRef FROM segments"))
            try refs.formUnion(String.fetchAll(db, sql: "SELECT clipRef FROM exemplars"))
            try refs.formUnion(String.fetchAll(db, sql: "SELECT clipRef FROM negatives WHERE clipRef IS NOT NULL"))
            refs.remove(FileLocations.deletedClipRef)
            return refs
        }

        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: FileLocations.clips, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return 0 }

        let graceCutoff = now.addingTimeInterval(-orphanGrace)
        var removed = 0
        for file in files where file.pathExtension.lowercased() == "m4a" {
            let ref = file.deletingPathExtension().lastPathComponent
            if referenced.contains(ref) { continue }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified > graceCutoff { continue }
            if (try? fm.removeItem(at: file)) != nil { removed += 1 }
        }
        return removed
    }

    /// Retention: segments discarded or marked not-him more than
    /// `retentionInterval` ago lose their audio. The row stays as a
    /// tombstone (`clipRef = FileLocations.deletedClipRef`). A clip an
    /// exemplar still references is never touched. Returns the number of
    /// files removed.
    @discardableResult
    static func retentionSweep(db: AppDatabase, now: Date = Date()) throws -> Int {
        let cutoff = now.addingTimeInterval(-retentionInterval)
        let clipsToRemove: [String] = try db.dbQueue.write { db in
            let refs = try String.fetchAll(
                db,
                sql: """
                SELECT DISTINCT g.clipRef FROM segments g
                WHERE g.state IN (?, ?)
                  AND g.clipRef != ?
                  AND COALESCE(g.labelledAt, g.startedAt) < ?
                  AND NOT EXISTS (SELECT 1 FROM exemplars e WHERE e.clipRef = g.clipRef)
                """,
                arguments: [
                    SegmentState.discarded.rawValue,
                    SegmentState.notHim.rawValue,
                    FileLocations.deletedClipRef,
                    cutoff,
                ]
            )
            for ref in refs {
                // Keep each row's own state; only the clipRef is tombstoned.
                try db.execute(
                    sql: "UPDATE segments SET clipRef = ? WHERE clipRef = ?",
                    arguments: [FileLocations.deletedClipRef, ref]
                )
            }
            return refs
        }
        var removed = 0
        for ref in clipsToRemove {
            let url = FileLocations.clipURL(id: ref)
            if FileManager.default.fileExists(atPath: url.path),
               (try? FileManager.default.removeItem(at: url)) != nil {
                removed += 1
            }
        }
        return removed
    }

    // MARK: - Storage meter

    /// "N clips, X MB" for Settings. Counts `.m4a` files in the clips
    /// directory and sums their sizes; `photoBytes` is the photos directory.
    static func storageSummary() throws -> (clipCount: Int, bytes: Int64, photoBytes: Int64) {
        let clips = try directorySize(FileLocations.clips, pathExtension: "m4a")
        let photos = try directorySize(FileLocations.photos, pathExtension: nil)
        return (clipCount: clips.count, bytes: clips.bytes, photoBytes: photos.bytes)
    }

    private static func directorySize(_ directory: URL, pathExtension: String?) throws -> (count: Int, bytes: Int64) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return (0, 0) }
        let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        var count = 0
        var bytes: Int64 = 0
        for file in files {
            if let pathExtension, file.pathExtension.lowercased() != pathExtension { continue }
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            count += 1
            bytes += Int64(size)
        }
        return (count, bytes)
    }
}
