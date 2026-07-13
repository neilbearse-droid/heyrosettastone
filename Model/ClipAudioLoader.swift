import AVFoundation
import Foundation

/// Reads a stored m4a clip back into the pipeline's canonical 16 kHz mono
/// Float32 samples, for embedding backfill and re-encoding.
enum ClipAudioLoader {
    enum LoadError: Error {
        case unreadable
        case conversionFailed
    }

    static func loadSamples(clipRef: String) throws -> [Float] {
        let url = FileLocations.clipURL(id: clipRef)
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))
        else { throw LoadError.unreadable }
        try file.read(into: buffer)

        if format.sampleRate == AudioCaptureEngine.targetFormat.sampleRate,
           format.channelCount == 1,
           format.commonFormat == .pcmFormatFloat32,
           let channel = buffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
        }
        return try convert(buffer, to: AudioCaptureEngine.targetFormat)
    }

    private static func convert(_ input: AVAudioPCMBuffer, to target: AVAudioFormat) throws -> [Float] {
        guard let converter = AVAudioConverter(from: input.format, to: target) else {
            throw LoadError.conversionFailed
        }
        var samples: [Float] = []
        var fed = false
        while true {
            let capacity = AVAudioFrameCount(8192)
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
                throw LoadError.conversionFailed
            }
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, outStatus in
                if fed {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return input
            }
            if let error { throw error }
            if let channel = out.floatChannelData, out.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
            }
            if status == .endOfStream || status == .error || out.frameLength == 0 {
                break
            }
        }
        guard !samples.isEmpty else { throw LoadError.conversionFailed }
        return samples
    }
}
