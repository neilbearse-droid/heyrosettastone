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

    static func tone(seconds: TimeInterval, amplitude: Float = 0.5, frequency: Double = 330) -> [Float] {
        let count = samples(seconds: seconds)
        return (0..<count).map { i in
            amplitude * Float(sin(2.0 * .pi * frequency * Double(i) / Double(sampleRate)))
        }
    }

    static func silence(seconds: TimeInterval) -> [Float] {
        [Float](repeating: 0, count: samples(seconds: seconds))
    }

    /// Quiet background noise, seeded so tests are repeatable. Amplitude is
    /// well below EnergyVAD's minimum RMS gate.
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
