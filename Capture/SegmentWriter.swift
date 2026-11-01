import AVFoundation
import Foundation

/// Persists a captured segment's samples as an m4a (AAC) clip under
/// FileLocations.clips. The file inherits the clips directory's Data
/// Protection class (see FileLocations); nothing is set per file.
///
/// Crash safety: AAC's moov atom is only written when the file closes, so
/// the clip is encoded into `<id>.m4a.tmp`, closed, and then moved onto its
/// final name. A kill mid-write leaves only a `.tmp`, which
/// `sweepTemporaryFiles(in:)` removes at the next launch; the final name is
/// either absent or a complete, playable file.
struct SegmentWriter {
    enum WriteError: Error {
        case bufferAllocationFailed
    }

    /// Extension appended to the final clip name while it is being written.
    static let temporaryExtension = "tmp"

    /// Writes the clip for `segment` and returns its clip ref (the file id).
    @discardableResult
    func write(_ segment: CapturedSegment) throws -> String {
        let clipRef = segment.id
        let finalURL = FileLocations.clipURL(id: clipRef)
        let temporaryURL = finalURL.appendingPathExtension(Self.temporaryExtension)
        let fm = FileManager.default

        if fm.fileExists(atPath: temporaryURL.path) {
            try? fm.removeItem(at: temporaryURL)
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Double(SessionBuffer.sampleRate),
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        // Scoped so the AVAudioFile is released (and therefore closed, with
        // its trailer written) before the move.
        do {
            let file = try AVAudioFile(
                forWriting: temporaryURL,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )

            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: AudioCaptureEngine.targetFormat,
                frameCapacity: AVAudioFrameCount(segment.samples.count)
            ), let channel = buffer.floatChannelData else {
                throw WriteError.bufferAllocationFailed
            }
            segment.samples.withUnsafeBufferPointer { source in
                if let base = source.baseAddress {
                    channel[0].update(from: base, count: segment.samples.count)
                }
            }
            buffer.frameLength = AVAudioFrameCount(segment.samples.count)
            try file.write(from: buffer)
        } catch {
            try? fm.removeItem(at: temporaryURL)
            throw error
        }

        if fm.fileExists(atPath: finalURL.path) {
            try? fm.removeItem(at: finalURL)
        }
        try fm.moveItem(at: temporaryURL, to: finalURL)
        return clipRef
    }

    /// Deletes every `*.tmp` left in `directory` by a write that never
    /// finished. Returns the number of files removed. Run it at launch,
    /// before listening starts (Maintenance does): sweeping while a clip is
    /// mid-write would make that one clip's final move fail.
    @discardableResult
    static func sweepTemporaryFiles(in directory: URL) -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var removed = 0
        for url in entries where url.pathExtension == temporaryExtension {
            if (try? fm.removeItem(at: url)) != nil {
                removed += 1
            }
        }
        return removed
    }
}
