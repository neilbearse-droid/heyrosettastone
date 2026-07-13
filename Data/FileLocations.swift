import Foundation

/// Canonical on-disk locations. Everything lives under Application Support,
/// protected with iOS Data Protection class Complete, and audio is excluded
/// from iCloud/iTunes backup by default (spec §6). The backup exclusion is
/// family-toggleable from Settings; the default is off.
enum FileLocations {
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Rosetta", isDirectory: true)
    }

    /// m4a utterance clips. One file per detected segment.
    static var clips: URL { root.appendingPathComponent("clips", isDirectory: true) }

    /// Intent photos taken during setup or in Dictionary.
    static var photos: URL { root.appendingPathComponent("photos", isDirectory: true) }

    static var databaseURL: URL { root.appendingPathComponent("rosetta.sqlite") }

    /// Creates the directory tree, applies Data Protection class Complete,
    /// and excludes the audio directory from backup unless the family has
    /// opted in. Call once at launch before touching the database.
    static func prepare(includeAudioInBackup: Bool = false) throws {
        let fm = FileManager.default
        for dir in [root, clips, photos] {
            try fm.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
        }
        try setAudioBackupInclusion(includeAudioInBackup)
    }

    /// Spec §6: no iCloud backup of audio by default, toggleable with a
    /// plain-language explanation in Settings.
    static func setAudioBackupInclusion(_ included: Bool) throws {
        var url = clips
        var values = URLResourceValues()
        values.isExcludedFromBackup = !included
        try url.setResourceValues(values)
    }

    static func clipURL(id: String) -> URL {
        clips.appendingPathComponent("\(id).m4a")
    }

    static func photoURL(id: String) -> URL {
        photos.appendingPathComponent("\(id).jpg")
    }
}
