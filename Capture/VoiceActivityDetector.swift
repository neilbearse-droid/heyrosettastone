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

    /// Diagnostics for the Listen tab's level readout: the energy of the
    /// most recent frame and the threshold it was judged against. A
    /// probability-based detector (Silero) reports its probability and
    /// decision threshold here instead.
    var currentRMS: Float { get }
    var currentThreshold: Float { get }
}

/// Adaptive-threshold RMS energy gate. Deliberately biased toward
/// over-detection: a false segment costs one swipe in Review, a missed
/// utterance costs training data.
struct EnergyVAD: VoiceActivityDetector {
    /// Estimated ambient level. Tracked quickly while no speech is detected
    /// and slowly while speech is detected, so a sustained rise in ambient
    /// level (TV, dishwasher) is absorbed in a few seconds instead of
    /// latching "speech" forever.
    private var noiseFloor: Float
    /// Speech must exceed the noise floor by this factor.
    let activationRatio: Float
    /// Absolute floor so a dead-quiet room doesn't fire on breathing.
    let minimumRMS: Float

    private let initialNoiseFloor: Float

    private(set) var currentRMS: Float = 0
    private(set) var currentThreshold: Float

    init(activationRatio: Float = 3.0, minimumRMS: Float = 0.01, initialNoiseFloor: Float = 0.003) {
        self.activationRatio = activationRatio
        self.minimumRMS = minimumRMS
        self.initialNoiseFloor = initialNoiseFloor
        self.noiseFloor = initialNoiseFloor
        self.currentThreshold = max(minimumRMS, initialNoiseFloor * activationRatio)
    }

    mutating func isSpeech(_ frame: ArraySlice<Float>) -> Bool {
        guard !frame.isEmpty else { return false }
        var sum: Float = 0
        for sample in frame { sum += sample * sample }
        let rms = (sum / Float(frame.count)).squareRoot()

        let threshold = max(minimumRMS, noiseFloor * activationRatio)
        let speech = rms > threshold
        currentRMS = rms
        currentThreshold = threshold

        if speech {
            // Slow upward tracking: a constant-level sound stops being
            // "speech" once the floor has absorbed it (time constant
            // ~6 s at 30 ms frames; a level 3x above the old floor
            // un-latches in ~2.5 s).
            noiseFloor = 0.995 * noiseFloor + 0.005 * rms
        } else {
            noiseFloor = 0.95 * noiseFloor + 0.05 * rms
        }
        return speech
    }

    /// Back to the cold-start floor. Tests use this; the capture path keeps
    /// the learned floor across pause/resume within one process.
    mutating func reset() {
        noiseFloor = initialNoiseFloor
        currentRMS = 0
        currentThreshold = max(minimumRMS, initialNoiseFloor * activationRatio)
    }
}
