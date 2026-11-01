import Foundation

/// Canonical on-disk locations. Everything lives under Application Support;
/// audio is excluded from iCloud/iTunes backup by default (spec §6). The
/// backup exclusion is family-toggleable from Settings; the default is off.
///
/// Data Protection: this is a deliberate deviation from spec §6, which asks
/// for class Complete. Rosetta's whole job is always-on capture from a
/// counter-top phone that locks within minutes, and class Complete files
/// cannot be created, read or written while the device is locked: the
/// SQLite file could not even be opened, `AVAudioFile(forWriting:)` would
/// throw for every clip, and every utterance captured while locked would be
/// silently dropped. So:
///
/// - root (database, journal) and photos: `.completeUntilFirstUserAuthentication`
///   (encrypted at rest, readable once the phone has been unlocked once
///   since boot, which is the normal state of a listening station).
/// - clips: `.completeUnlessOpen` (a clip being written while locked stays
///   writable until closed; once closed it is locked until the next unlock).
///
/// New files inherit the class of their directory, so SegmentWriter must
/// not set a per-file class. Directories from an older install were created
/// with `.complete`; `prepare` re-classes them and their files once.
enum FileLocations {
    /// Test hook: redirects the whole tree to a temporary directory so tests
    /// that write clips and photos never touch the app's real data. Nil in
    /// the app.
    static var rootOverride: URL?

    static var root: URL {
        if let rootOverride { return rootOverride }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Rosetta", isDirectory: true)
    }

    /// m4a utterance clips. One file per detected segment.
    static var clips: URL { root.appendingPathComponent("clips", isDirectory: true) }

    /// Intent photos taken during setup or in Dictionary.
    static var photos: URL { root.appendingPathComponent("photos", isDirectory: true) }

    static var databaseURL: URL { root.appendingPathComponent("rosetta.sqlite") }

    /// Sentinel stored in `segments.clipRef` / `exemplars.clipRef` once the
    /// audio file has been deleted (Review discard, Dictionary prune,
    /// retention sweep, delete-forever). The row survives as a tombstone so
    /// counts, events and history stay consistent. Anything that opens a
    /// clip must check `isDeleted(clipRef:)` first, or use
    /// `existingClipURL(id:)`, which returns nil for tombstones.
    static let deletedClipRef = ""

    static func isDeleted(clipRef: String) -> Bool {
        clipRef == deletedClipRef
    }

    /// UserDefaults flag: the one-time re-classing of directories and files
    /// created by builds that used class Complete has run.
    static let protectionMigrationKey = "protectionClassMigrated"

    /// Creates the directory tree with the protection classes described
    /// above, re-classes anything left over from a class-Complete install
    /// (once), and excludes the audio directory from backup unless the
    /// family has opted in. Call once at launch before touching the
    /// database.
    static func prepare(includeAudioInBackup: Bool = false) throws {
        let fm = FileManager.default
        for (dir, protection) in directoryProtection {
            // No-op for an existing directory: attributes are not re-applied,
            // hence the explicit migration below.
            try fm.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: protection]
            )
        }
        migrateProtectionClassesIfNeeded()
        try setAudioBackupInclusion(includeAudioInBackup)
    }

    private static var directoryProtection: [(URL, FileProtectionType)] {
        [
            (root, .completeUntilFirstUserAuthentication),
            (clips, .completeUnlessOpen),
            (photos, .completeUntilFirstUserAuthentication),
        ]
    }

    /// Re-classes directories and existing files from `.complete` to the
    /// classes above. Guarded by a UserDefaults flag so it runs once; any
    /// individual failure is ignored (a file that cannot be re-classed is
    /// still readable once unlocked, which is where it was before).
    private static func migrateProtectionClassesIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: protectionMigrationKey) else { return }
        let fm = FileManager.default
        var directoriesOK = true

        for (dir, protection) in directoryProtection {
            do {
                try fm.setAttributes([.protectionKey: protection], ofItemAtPath: dir.path)
            } catch {
                directoriesOK = false
            }
            if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for file in files {
                    let isDirectory = (try? file.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                    if isDirectory { continue }
                    try? fm.setAttributes([.protectionKey: protection], ofItemAtPath: file.path)
                }
            }
        }
        // The database and its sidecar files live directly under root and
        // were already covered by the loop above (root is first), but be
        // explicit for the ones that matter most.
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let path = databaseURL.path + suffix
            if fm.fileExists(atPath: path) {
                try? fm.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: path
                )
            }
        }
        if directoriesOK {
            defaults.set(true, forKey: protectionMigrationKey)
        }
    }

    /// Spec §6: no iCloud backup of audio by default, toggleable with a
    /// plain-language explanation in Settings.
    static func setAudioBackupInclusion(_ included: Bool) throws {
        var url = clips
        var values = URLResourceValues()
        values.isExcludedFromBackup = !included
        try url.setResourceValues(values)
    }

    /// The path a clip would live at. For a tombstoned ref this is a path
    /// that does not exist; prefer `existingClipURL(id:)` when opening.
    static func clipURL(id: String) -> URL {
        clips.appendingPathComponent("\(id).m4a")
    }

    /// The clip's URL if the ref is not a tombstone and the file is on disk,
    /// otherwise nil. ClipPlayer, ClipAudioLoader and the backfill should
    /// use this rather than `clipURL(id:)`.
    static func existingClipURL(id: String) -> URL? {
        guard !isDeleted(clipRef: id) else { return nil }
        let url = clipURL(id: id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func photoURL(id: String) -> URL {
        photos.appendingPathComponent("\(id).jpg")
    }
}
