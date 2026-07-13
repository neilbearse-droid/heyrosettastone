import AVFoundation
import Foundation

/// Persists a captured segment's samples as an m4a (AAC) clip under
/// FileLocations.clips, protected with Data Protection class Complete.
struct SegmentWriter {
    enum WriteError: Error {
        case bufferAllocationFailed
    }

    /// Writes the clip for `segment` and returns its clip ref (the file id).
    @discardableResult
    func write(_ segment: CapturedSegment) throws -> String {
        let clipRef = segment.id
        let url = FileLocations.clipURL(id: clipRef)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Double(SessionBuffer.sampleRate),
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let file = try AVAudioFile(
            forWriting: url,
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
            channel[0].update(from: source.baseAddress!, count: segment.samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(segment.samples.count)
        try file.write(from: buffer)

        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        return clipRef
    }
}
