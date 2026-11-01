import Foundation
@testable import Rosetta

/// Deterministic fixture audio, generated in code so no binary files live in
/// the repo. "Speech" is a loud tone; "room noise" is a quiet seeded-random
/// signal below the VAD floor; silence is zeros.
enum AudioFixtures {
    static let sampleRate = SessionBuffer.sampleRate

    static func samples(seconds: TimeInterval) -> Int {
        Int(seconds * Double(sampleRate))
    }

    /// Splits samples into whole `SessionBuffer.frameLength` frames, as the
    /// buffer feeds a detector; a trailing partial frame is dropped.
    static func frames(_ samples: [Float]) -> [[Float]] {
        let length = SessionBuffer.frameLength
        return stride(from: 0, to: samples.count - length + 1, by: length).map { start in
            Array(samples[start..<start + length])
        }
    }

    /// Root-mean-square level of a window, as a fake detector would judge it.
    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }

    static func tone(seconds: TimeInterval, amplitude: Float = 0.5, frequency: Double = 330) -> [Float] {
        let count = samples(seconds: seconds)
        return (0..<count).map { i in
            amplitude * Float(sin(2.0 * .pi * frequency * Double(i) / Double(sampleRate)))
        }
    }

    static func silence(seconds: TimeInterval) -> [Float] {
        [Float](repeating: 0, count: samples(seconds: seconds))
    }

    /// A tone that pulses on and off in whole 30 ms frames, frame-aligned
    /// when ingested from a frame boundary. The off frames are short enough
    /// that the hangover never elapses and the on frames are loud enough
    /// that the adaptive noise floor never catches up, so the VAD treats
    /// the whole thing as one continuous utterance. That is what a latched
    /// detector looks like, and what `Tuning.maxUtterance` has to cut.
    static func pulsedTone(seconds: TimeInterval, onFrames: Int = 4, offFrames: Int = 2,
                           amplitude: Float = 0.5, frequency: Double = 330) -> [Float] {
        let frame = SessionBuffer.frameLength
        let count = samples(seconds: seconds)
        let period = (onFrames + offFrames) * frame
        return (0..<count).map { i in
            let inPeriod = i % period
            guard inPeriod < onFrames * frame else { return 0 }
            return amplitude * Float(sin(2.0 * .pi * frequency * Double(i) / Double(sampleRate)))
        }
    }

    /// Background noise, seeded so tests are repeatable. The default
    /// amplitude is well below EnergyVAD's minimum RMS gate; pass a larger
    /// one (0.02 is a TV in the next room) to exercise floor adaptation.
    static func roomNoise(seconds: TimeInterval, amplitude: Float = 0.002, seed: UInt64 = 42) -> [Float] {
        var state = seed
        let count = samples(seconds: seconds)
        return (0..<count).map { _ in
            // xorshift64
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            let unit = Float(state % 20001) / 10000.0 - 1.0
            return amplitude * unit
        }
    }
}

/// Collects SessionBuffer delegate callbacks for assertions.
final class BufferRecorder: SessionBufferDelegate {
    struct Open { let id: String; let time: TimeInterval }
    struct Close { let id: String; let time: TimeInterval; let reason: SessionCloseReason }

    var opens: [Open] = []
    var segments: [CapturedSegment] = []
    var closes: [Close] = []

    func sessionOpened(id: String, atStreamTime time: TimeInterval) {
        opens.append(Open(id: id, time: time))
    }

    func segmentCaptured(_ segment: CapturedSegment) {
        segments.append(segment)
    }

    func sessionClosed(id: String, atStreamTime time: TimeInterval, reason: SessionCloseReason) {
        closes.append(Close(id: id, time: time, reason: reason))
    }
}
