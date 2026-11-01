import Foundation
import GRDB

/// Restore / device-migration import: the inverse of `RosettaExporter`.
/// Reads an export's `rosetta.json`, merges every table by id with
/// `INSERT OR IGNORE` in one transaction, and copies clips and photos that
/// are not already on disk. Existing rows and files always win, so
/// importing the same export twice, or importing an old backup over newer
/// data, never overwrites anything the family did since.
///
/// Input is a folder: either the unzipped export (what the Files app
/// produces when the zip is tapped), the `rosetta.json` inside it, or a
/// folder that contains the export folder one level down. A `.zip` is
/// refused with a plain-language message, because Foundation has no public
/// unzip API and the app links no compression library.
enum RosettaImporter {
    enum ImportError: LocalizedError, Equatable {
        case zipNotSupportedUnzipInFiles
        case manifestMissing
        case unsupportedFormat(Int)
        case notAFolder

        var errorDescription: String? {
            switch self {
            case .zipNotSupportedUnzipInFiles:
                return "Tap the zip in Files to unzip it, then choose the folder it creates."
            case .manifestMissing:
                return "That folder is not a Rosetta export: it has no rosetta.json."
            case .unsupportedFormat(let version):
                return "This export (format \(version)) was made by a newer version of Rosetta. Update the app, then try again."
            case .notAFolder:
                return "Choose the unzipped export folder."
            }
        }
    }

    struct ImportSummary: Equatable {
        var intents = 0
        var exemplars = 0
        var negatives = 0
        var events = 0
        var sessions = 0
        var segments = 0
        var calibrationObservations = 0
        /// Rows the database refused (missing parent row, bad data). The
        /// rest of the import still lands.
        var skippedRows = 0
        var clipsCopied = 0
        var photosCopied = 0

        var rowsInserted: Int {
            intents + exemplars + negatives + events + sessions + segments + calibrationObservations
        }
    }

    /// Imports an unzipped export folder (see the type comment) into `db`.
    /// Handles security-scoped URLs from `.fileImporter`. Runs off the
    /// caller's actor; the database write is one transaction.
    static func `import`(from zipOrFolderURL: URL, into db: AppDatabase) async throws -> ImportSummary {
        let url = zipOrFolderURL
        return try await Task.detached(priority: .userInitiated) {
            try Self.importSync(from: url, into: db)
        }.value
    }

    /// Same as `import(from:into:)` without the keyword-named call site.
    static func restore(from folderURL: URL, into db: AppDatabase) async throws -> ImportSummary {
        try await `import`(from: folderURL, into: db)
    }

    /// Synchronous worker; also what tests call directly.
    static func importSync(from zipOrFolderURL: URL, into db: AppDatabase) throws -> ImportSummary {
        let accessing = zipOrFolderURL.startAccessingSecurityScopedResource()
        defer { if accessing { zipOrFolderURL.stopAccessingSecurityScopedResource() } }

        if zipOrFolderURL.pathExtension.lowercased() == "zip" {
            throw ImportError.zipNotSupportedUnzipInFiles
        }
        let exportRoot = try locateExportRoot(at: zipOrFolderURL)
        let manifestURL = exportRoot.appendingPathComponent(RosettaExporter.manifestFileName)
        let data = try Data(contentsOf: manifestURL)
        let manifest = try RosettaExporter.makeJSONDecoder().decode(RosettaExporter.ExportManifest.self, from: data)
        guard manifest.formatVersion <= RosettaExporter.formatVersion else {
            throw ImportError.unsupportedFormat(manifest.formatVersion)
        }

        var summary = try mergeRows(manifest, into: db)
        summary.clipsCopied = try copyMissingFiles(
            from: exportRoot.appendingPathComponent(RosettaExporter.clipsDirectoryName, isDirectory: true),
            to: FileLocations.clips,
            pathExtension: "m4a"
        )
        summary.photosCopied = try copyMissingFiles(
            from: exportRoot.appendingPathComponent(RosettaExporter.photosDirectoryName, isDirectory: true),
            to: FileLocations.photos,
            pathExtension: "jpg"
        )
        return summary
    }

    // MARK: - Pieces

    /// The folder that directly contains `rosetta.json`: the URL itself, the
    /// parent of a chosen `rosetta.json`, or one immediate subfolder (Files
    /// sometimes unzips into a wrapper folder named after the archive).
    static func locateExportRoot(at url: URL) throws -> URL {
        let fm = FileManager.default
        let manifest = RosettaExporter.manifestFileName

        if url.lastPathComponent == manifest, fm.fileExists(atPath: url.path) {
            return url.deletingLastPathComponent()
        }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ImportError.notAFolder
        }
        if fm.fileExists(atPath: url.appendingPathComponent(manifest).path) {
            return url
        }
        let children = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])
        for child in children {
            let childIsDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if childIsDirectory, fm.fileExists(atPath: child.appendingPathComponent(manifest).path) {
                return child
            }
        }
        throw ImportError.manifestMissing
    }

    /// One transaction, parents before children so foreign keys resolve.
    /// `INSERT OR IGNORE` by primary key; a row the database still refuses
    /// (for example a segment whose session is absent from the export) is
    /// counted in `skippedRows` and the import continues.
    ///
    /// Board slots are unique. An imported intent whose slot is already
    /// taken by a different intent on this phone is placed on the lowest
    /// free slot instead (`BoardLayout.slotForNewIntent`): his existing
    /// buttons never move (§2.3), and the imported word still reaches his
    /// board rather than being dropped by the uniqueness constraint or
    /// overwriting a cell.
    static func mergeRows(_ manifest: RosettaExporter.ExportManifest, into db: AppDatabase) throws -> ImportSummary {
        try db.dbQueue.write { db in
            var summary = ImportSummary()
            var skipped = 0

            let intents = try Self.resolvingBoardSlots(manifest.intents, db)
            summary.intents = Self.insertIgnoring(intents, db, skipped: &skipped)
            summary.sessions = Self.insertIgnoring(manifest.sessions, db, skipped: &skipped)
            summary.segments = Self.insertIgnoring(manifest.segments, db, skipped: &skipped)
            summary.exemplars = Self.insertIgnoring(manifest.exemplars, db, skipped: &skipped)
            summary.negatives = Self.insertIgnoring(manifest.negatives, db, skipped: &skipped)
            summary.events = Self.insertIgnoring(manifest.events, db, skipped: &skipped)
            summary.calibrationObservations = Self.insertIgnoring(
                manifest.calibrationObservations, db, skipped: &skipped)

            summary.skippedRows = skipped
            return summary
        }
    }

    /// Imported intents with their board slots made consistent with this
    /// phone's board: an intent already present keeps the local row (its
    /// slot is irrelevant, the insert is ignored); a new intent whose slot
    /// is occupied by another id, locally or earlier in this import, moves
    /// to the lowest free slot. Archived intents hold no slot.
    static func resolvingBoardSlots(_ incoming: [IntentRecord], _ db: Database) throws -> [IntentRecord] {
        let existingIds = Set(try String.fetchAll(db, sql: "SELECT id FROM intents"))
        var occupied: [Int: String] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT id, boardSlot FROM intents WHERE boardSlot IS NOT NULL") {
            if let id: String = row["id"], let slot: Int = row["boardSlot"] { occupied[slot] = id }
        }
        return incoming.map { intent in
            guard !existingIds.contains(intent.id), let slot = intent.boardSlot else { return intent }
            var placed = intent
            if placed.archivedAt != nil {
                placed.boardSlot = nil
                return placed
            }
            if let holder = occupied[slot], holder != intent.id {
                placed.boardSlot = BoardLayout.slotForNewIntent(occupiedSlots: Array(occupied.keys))
            }
            if let final = placed.boardSlot { occupied[final] = intent.id }
            return placed
        }
    }

    /// Inserts each record with OR IGNORE and returns how many rows were
    /// actually added (an ignored duplicate changes nothing).
    private static func insertIgnoring<R: PersistableRecord>(_ records: [R], _ db: Database, skipped: inout Int) -> Int {
        var inserted = 0
        for record in records {
            do {
                try record.insert(db, onConflict: .ignore)
                if db.changesCount > 0 { inserted += 1 }
            } catch {
                skipped += 1
            }
        }
        return inserted
    }

    /// Copies files with the given extension that are not already present
    /// in `destination`. Never overwrites. Returns the number copied.
    static func copyMissingFiles(from source: URL, to destination: URL, pathExtension: String) throws -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return 0 }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let files = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        var copied = 0
        for file in files where file.pathExtension.lowercased() == pathExtension {
            let target = destination.appendingPathComponent(file.lastPathComponent)
            if fm.fileExists(atPath: target.path) { continue }
            try fm.copyItem(at: file, to: target)
            copied += 1
        }
        return copied
    }
}
