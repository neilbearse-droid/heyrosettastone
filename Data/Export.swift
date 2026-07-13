import Foundation
import GRDB

/// Backup / device-migration export (§6): a zip of all audio plus a JSON dump
/// of the structured tables, produced for the share sheet. Zipping uses
/// NSFileCoordinator's `.forUploading` option so no compression library is
/// linked. Also owns wipe-all.
struct RosettaExporter {
    let db: AppDatabase

    struct ExportManifest: Codable {
        var formatVersion = 1
        var exportedAt: Date
        var intents: [IntentRecord]
        var exemplars: [ExemplarRecord]
        var negatives: [NegativeRecord]
        var events: [EventRecord]
        var sessions: [SessionRecord]
        var segments: [SegmentRecord]
        var calibrationObservations: [CalibrationObservationRecord] = []
    }

    /// Builds `Rosetta-export-<date>.zip` in a temporary directory and
    /// returns its URL for the share sheet. Contains rosetta.json plus a
    /// clips/ and photos/ directory.
    func makeExportZip() throws -> URL {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory
            .appendingPathComponent("RosettaExport-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let manifest = try db.dbQueue.read { db in
            ExportManifest(
                exportedAt: Date(),
                intents: try IntentRecord.fetchAll(db),
                exemplars: try ExemplarRecord.fetchAll(db),
                negatives: try NegativeRecord.fetchAll(db),
                events: try EventRecord.fetchAll(db),
                sessions: try SessionRecord.fetchAll(db),
                segments: try SegmentRecord.fetchAll(db),
                calibrationObservations: try CalibrationObservationRecord.fetchAll(db)
            )
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: staging.appendingPathComponent("rosetta.json"))

        for (source, name) in [(FileLocations.clips, "clips"), (FileLocations.photos, "photos")] {
            let dest = staging.appendingPathComponent(name, isDirectory: true)
            if fm.fileExists(atPath: source.path) {
                try fm.copyItem(at: source, to: dest)
            } else {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            }
        }

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
        return zipURL
    }

    /// Full local deletion (§8): every table emptied, every clip and photo
    /// removed. Callers must have shown an explicit confirmation first.
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
    }
}
