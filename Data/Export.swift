import Foundation
import GRDB

/// Backup / device-migration export (§6): a zip of all audio plus a JSON dump
/// of the structured tables, produced for the share sheet. Zipping uses
/// NSFileCoordinator's `.forUploading` option so no compression library is
/// linked. Also owns wipe-all. The inverse is `RosettaImporter`.
///
/// Nothing here is main-actor state: call `makeExportZip` from
/// `Task.detached` and hand the returned URL back to the UI. The optional
/// progress callback is invoked on the calling thread.
struct RosettaExporter {
    let db: AppDatabase

    typealias Progress = (Double) -> Void

    /// Layout of an export, shared with the importer.
    static let manifestFileName = "rosetta.json"
    static let clipsDirectoryName = "clips"
    static let photosDirectoryName = "photos"
    /// 1: original Phase 1/2 layout. 2: exemplars carry `sessionId` and
    /// `capturedAt` (v3 schema). The importer reads both.
    static let formatVersion = 2

    struct ExportManifest: Codable {
        var formatVersion = RosettaExporter.formatVersion
        var exportedAt: Date
        var intents: [IntentRecord]
        var exemplars: [ExemplarRecord]
        var negatives: [NegativeRecord]
        var events: [EventRecord]
        var sessions: [SessionRecord]
        var segments: [SegmentRecord]
        var calibrationObservations: [CalibrationObservationRecord] = []
    }

    static func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func makeJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Snapshot of every table, in one read transaction.
    func manifest(now: Date = Date()) throws -> ExportManifest {
        try db.dbQueue.read { db in
            ExportManifest(
                exportedAt: now,
                intents: try IntentRecord.fetchAll(db),
                exemplars: try ExemplarRecord.fetchAll(db),
                negatives: try NegativeRecord.fetchAll(db),
                events: try EventRecord.fetchAll(db),
                sessions: try SessionRecord.fetchAll(db),
                segments: try SegmentRecord.fetchAll(db),
                calibrationObservations: try CalibrationObservationRecord.fetchAll(db)
            )
        }
    }

    /// Builds the export tree (`rosetta.json`, `clips/`, `photos/`) inside
    /// `staging`, which must not exist yet. Clips and photos are staged as
    /// hard links so the export does not double disk use; a link that
    /// fails (different volume, unsupported) falls back to a copy.
    /// `progress` runs from 0 to 1 over the files staged. The caller owns
    /// `staging` and removes it when done.
    func stage(into staging: URL, progress: Progress? = nil) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let snapshot = try manifest()
        try Self.makeJSONEncoder().encode(snapshot)
            .write(to: staging.appendingPathComponent(Self.manifestFileName))

        let sources: [(URL, String, String)] = [
            (FileLocations.clips, Self.clipsDirectoryName, "m4a"),
            (FileLocations.photos, Self.photosDirectoryName, "jpg"),
        ]
        var files: [(URL, URL)] = []
        for (source, name, ext) in sources {
            let dest = staging.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            guard fm.fileExists(atPath: source.path) else { continue }
            let contents = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            for file in contents where file.pathExtension.lowercased() == ext {
                // Skips `.tmp` partial writes and anything else stray.
                files.append((file, dest.appendingPathComponent(file.lastPathComponent)))
            }
        }

        let total = max(files.count, 1)
        for (index, (from, to)) in files.enumerated() {
            do {
                try fm.linkItem(at: from, to: to)
            } catch {
                try fm.copyItem(at: from, to: to)
            }
            progress?(Double(index + 1) / Double(total))
        }
        progress?(1)
    }

    /// Builds `Rosetta-export-<date>.zip` in a temporary directory and
    /// returns its URL for the share sheet. Contains rosetta.json plus a
    /// clips/ and photos/ directory. Progress reports 0 to 0.8 for staging
    /// and 1 once the zip is written.
    func makeExportZip(progress: Progress? = nil) throws -> URL {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory
            .appendingPathComponent("RosettaExport-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }

        try stage(into: staging) { fraction in progress?(fraction * 0.8) }

        // NSFileCoordinator zips a directory when reading it for upload.
        var coordinatorError: NSError?
        var zipURL: URL?
        var copyError: Error?
        let dateStamp = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let finalURL = fm.temporaryDirectory.appendingPathComponent("Rosetta-export-\(dateStamp).zip")
        NSFileCoordinator().coordinate(
            readingItemAt: staging, options: .forUploading, error: &coordinatorError
        ) { coordinated in
            do {
                try? fm.removeItem(at: finalURL)
                try fm.copyItem(at: coordinated, to: finalURL)
                zipURL = finalURL
            } catch {
                copyError = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let copyError { throw copyError }
        guard let zipURL else {
            throw NSError(domain: "RosettaExport", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not create the export archive.",
            ])
        }
        progress?(1)
        return zipURL
    }

    /// Full local deletion (§8): every table emptied, every clip and photo
    /// removed, the database file vacuumed so freed pages do not keep the
    /// old rows, and the setup-interview flag reset so the app returns to
    /// setup. Callers must have shown an explicit confirmation first, and
    /// must then clear in-memory capture state and reload the suggestion
    /// engine (both still hold the deleted rows).
    func wipeAll() throws {
        try db.dbQueue.write { db in
            // Order respects foreign keys.
            try db.execute(sql: "DELETE FROM calibrationObservations")
            try db.execute(sql: "DELETE FROM exemplars")
            try db.execute(sql: "DELETE FROM negatives")
            try db.execute(sql: "DELETE FROM segments")
            try db.execute(sql: "DELETE FROM events")
            try db.execute(sql: "DELETE FROM sessions")
            try db.execute(sql: "DELETE FROM intents")
        }
        let fm = FileManager.default
        for dir in [FileLocations.clips, FileLocations.photos] {
            if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for file in files { try? fm.removeItem(at: file) }
            }
        }
        UserDefaults.standard.set(false, forKey: "hasCompletedSetupInterview")
        // VACUUM cannot run inside a transaction.
        try db.dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
        }
    }
}
