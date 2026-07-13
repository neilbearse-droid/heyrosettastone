import Foundation

/// Frame-level voice activity decision over 16 kHz mono audio.
///
/// Phase 1 ships `EnergyVAD` below. Phase 2 replaces it with Silero VAD
/// behind this same protocol (see docs/silero-vad-conversion.md for the
/// ONNX → Core ML conversion step); Apple SoundAnalysis speech
/// classification is the documented coarse fallback. Nothing upstream or
/// downstream changes when the implementation is swapped.
protocol VoiceActivityDetector {
    /// One frame (SessionBuffer.frameLength samples) of 16 kHz mono audio.
    mutating func isSpeech(_ frame: ArraySlice<Float>) -> Bool
    mutating func reset()
}

/// Adaptive-threshold RMS energy gate. Deliberately biased toward
/// over-detection: a false segment costs one swipe in Review, a missed
/// utterance costs training data.
struct EnergyVAD: VoiceActivityDetector {
    /// Estimated ambient level, tracked slowly while no speech is detected.
    private var noiseFloor: Float
    /// Speech must exceed the noise floor by this factor.
    let activationRatio: Float
    /// Absolute floor so a dead-quiet room doesn't fire on breathing.
    let minimumRMS: Float

    private let initialNoiseFloor: Float

    init(activationRatio: Float = 3.0, minimumRMS: Float = 0.01, initialNoiseFloor: Float = 0.003) {
        self.activationRatio = activationRatio
        self.minimumRMS = minimumRMS
        self.initialNoiseFloor = initialNoiseFloor
        self.noiseFloor = initialNoiseFloor
    }

    mutating func isSpeech(_ frame: ArraySlice<Float>) -> Bool {
        guard !frame.isEmpty else { return false }
        var sum: Float = 0
        for sample in frame { sum += sample * sample }
        let rms = (sum / Float(frame.count)).squareRoot()

        let speech = rms > max(minimumRMS, noiseFloor * activationRatio)
        if !speech {
            noiseFloor = 0.95 * noiseFloor + 0.05 * rms
        }
        return speech
    }

    mutating func reset() {
        noiseFloor = initialNoiseFloor
    }
}
