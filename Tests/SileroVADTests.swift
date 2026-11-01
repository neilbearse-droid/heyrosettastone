import XCTest
@testable import Rosetta

/// Scripted stand-in for the Core ML runner. Records every call so tests
/// can check the rebuffering and the state threading; the state it hands
/// back is recognizable (every element equals the 1-based call number).
final class FakeSileroRunner: SileroModelRunner {
    struct Failure: Error {}

    /// Probability for call n (0-based); the last entry repeats once the
    /// script runs out. Ignored when `decide` is set.
    var script: [Float]
    /// Decides the probability from the audio window itself, like the real
    /// network would (used to drive `SessionBuffer` with fixture audio).
    var decide: (([Float]) -> Float)?
    /// 0-based call indices that throw.
    var failingCalls: Set<Int> = []
    var alwaysFail = false

    private(set) var calls = 0
    private(set) var receivedStates: [[Float]] = []
    private(set) var receivedAudioCounts: [Int] = []

    init(script: [Float] = [0], decide: (([Float]) -> Float)? = nil) {
        self.script = script
        self.decide = decide
    }

    func predict(audio: [Float], state: [Float]) throws -> (probability: Float, state: [Float]) {
        let index = calls
        calls += 1
        receivedStates.append(state)
        receivedAudioCounts.append(audio.count)
        if alwaysFail || failingCalls.contains(index) {
            throw Failure()
        }
        let probability: Float
        if let decide {
            probability = decide(audio)
        } else if script.indices.contains(index) {
            probability = script[index]
        } else {
            probability = script.last ?? 0
        }
        return (probability, [Float](repeating: Float(index + 1), count: SileroVAD.stateCount))
    }
}

final class SileroVADTests: XCTestCase {
    private let frameLength = SessionBuffer.frameLength

    private func silentFrame() -> [Float] {
        [Float](repeating: 0, count: frameLength)
    }

    private func feed(_ vad: inout SileroVAD, frames: Int) -> [Bool] {
        let frame = silentFrame()
        return (0..<frames).map { _ in vad.isSpeech(frame[...]) }
    }

    // MARK: Rebuffering 480 → 512

    func testModelRunsOncePer512SamplesAcross480SampleFrames() {
        let runner = FakeSileroRunner()
        var vad = SileroVAD(runner: runner)

        // One 480-sample frame is short of a window: no call yet.
        _ = feed(&vad, frames: 1)
        XCTAssertEqual(runner.calls, 0)
        // 960 samples: one window, 448 carried over.
        _ = feed(&vad, frames: 1)
        XCTAssertEqual(runner.calls, 1)

        // In general floor(N * 480 / 512) calls after N frames; a frame
        // never yields two (remainder < 512, plus 480, is < 1024).
        _ = feed(&vad, frames: 14)
        XCTAssertEqual(runner.calls, 15, "16 frames = 7680 samples = 15 windows")
        _ = feed(&vad, frames: 84)
        XCTAssertEqual(runner.calls, 93, "100 frames = 48000 samples = 93 full windows")

        XCTAssertTrue(runner.receivedAudioCounts.allSatisfy { $0 == SileroVAD.windowSamples },
                      "every call sees exactly one 512-sample window")
    }

    // MARK: State threading

    func testStateIsThreadedBetweenCallsAndZeroedOnReset() {
        let runner = FakeSileroRunner()
        var vad = SileroVAD(runner: runner)
        let zeros = [Float](repeating: 0, count: SileroVAD.stateCount)

        _ = feed(&vad, frames: 4) // 3 calls
        XCTAssertEqual(runner.calls, 3)
        XCTAssertEqual(runner.receivedStates[0], zeros, "a fresh stream starts from a zero state")
        XCTAssertEqual(runner.receivedStates[1], [Float](repeating: 1, count: SileroVAD.stateCount),
                       "call 2 receives the state call 1 returned")
        XCTAssertEqual(runner.receivedStates[2], [Float](repeating: 2, count: SileroVAD.stateCount))

        vad.reset()
        XCTAssertNil(vad.currentConfidence)
        _ = feed(&vad, frames: 2) // pending was cleared too: exactly one call
        XCTAssertEqual(runner.calls, 4)
        XCTAssertEqual(runner.receivedStates[3], zeros, "reset zeroes the recurrent state")
    }

    // MARK: Hysteresis

    func testHysteresisEntersAtOnsetAndLeavesBelowOffset() {
        let runner = FakeSileroRunner(script: [0.6, 0.4, 0.3, 0.45])
        var vad = SileroVAD(runner: runner)

        XCTAssertFalse(vad.isSpeech(silentFrame()[...]), "no window yet: not speech")
        XCTAssertTrue(vad.isSpeech(silentFrame()[...]), "0.6 ≥ onset 0.5 → speech")
        XCTAssertTrue(vad.isSpeech(silentFrame()[...]), "0.4 is below onset but above offset 0.35 → stays speech")
        XCTAssertFalse(vad.isSpeech(silentFrame()[...]), "0.3 < offset → not speech")
        XCTAssertFalse(vad.isSpeech(silentFrame()[...]), "0.45 < onset while not in speech → still not speech")
    }

    func testHysteresisTuningIsRespected() {
        let runner = FakeSileroRunner(script: [0.7, 0.65])
        var vad = SileroVAD(runner: runner, tuning: SileroVAD.Tuning(onset: 0.8, offset: 0.6))
        _ = feed(&vad, frames: 2)
        XCTAssertFalse(vad.isSpeech(silentFrame()[...]), "0.7 < onset 0.8 never enters speech")
    }

    // MARK: Confidence

    func testCurrentConfidenceReflectsTheLastProbability() {
        let runner = FakeSileroRunner(script: [0.12, 0.87])
        var vad = SileroVAD(runner: runner)

        XCTAssertNil(vad.currentConfidence, "nothing predicted yet")
        _ = feed(&vad, frames: 2)
        XCTAssertEqual(vad.currentConfidence ?? -1, 0.12, accuracy: 0.0001)
        _ = feed(&vad, frames: 1)
        XCTAssertEqual(vad.currentConfidence ?? -1, 0.87, accuracy: 0.0001)
    }

    // MARK: Failure handling

    func testSingleRunnerFailureIsNotSpeechAndRecovers() {
        let runner = FakeSileroRunner(script: [0.9])
        runner.failingCalls = [1]
        var vad = SileroVAD(runner: runner)

        let before = feed(&vad, frames: 2)
        XCTAssertEqual(before, [false, true], "call 0 says 0.9: speech")
        XCTAssertFalse(vad.isSpeech(silentFrame()[...]), "the failed call answers not-speech")
        XCTAssertNotNil(vad.lastError)
        XCTAssertNil(vad.currentConfidence)
        XCTAssertFalse(vad.isDegraded)

        XCTAssertTrue(vad.isSpeech(silentFrame()[...]), "the next successful call is back to the model's answer")
        XCTAssertEqual(vad.currentConfidence ?? -1, 0.9, accuracy: 0.0001)
    }

    func testThreeConsecutiveFailuresDegradeToTheEnergyDetector() {
        let runner = FakeSileroRunner()
        runner.alwaysFail = true
        var vad = SileroVAD(runner: runner)

        let answers = feed(&vad, frames: 4) // 3 calls, all failing
        XCTAssertEqual(answers, [false, false, false, false], "silent frames never read as speech while failing")
        XCTAssertEqual(runner.calls, 3)
        XCTAssertTrue(vad.isDegraded)
        XCTAssertNotNil(vad.lastError)
        XCTAssertNil(vad.currentConfidence, "no probability is reported once degraded")

        // The model is never called again...
        _ = feed(&vad, frames: 20)
        XCTAssertEqual(runner.calls, 3)

        // ...and the embedded energy detector answers: a loud tone frame is
        // speech, silence is not, exactly as EnergyVAD would say.
        let loud = AudioFixtures.frames(AudioFixtures.tone(seconds: 0.03))[0]
        XCTAssertTrue(vad.isSpeech(loud[...]), "degraded detector behaves like EnergyVAD")
        XCTAssertGreaterThan(vad.currentRMS, vad.currentThreshold)
        XCTAssertFalse(vad.isSpeech(silentFrame()[...]))

        vad.reset()
        _ = feed(&vad, frames: 4)
        XCTAssertEqual(runner.calls, 3, "reset does not re-arm an abandoned model")
    }

    func testEnergyReadoutIsMaintainedAlongsideTheModel() {
        let runner = FakeSileroRunner(script: [0.05])
        var vad = SileroVAD(runner: runner)
        let loud = AudioFixtures.frames(AudioFixtures.tone(seconds: 0.03))[0]
        _ = vad.isSpeech(loud[...])
        _ = vad.isSpeech(loud[...])
        // The model says no, the meter still shows the real level.
        let expectedRMS: Float = 0.5 / Float(2).squareRoot()
        XCTAssertEqual(vad.currentRMS, expectedRMS, accuracy: 0.02)
        // The energy threshold is the embedded EnergyVAD's live value: at
        // least its absolute floor, and still well below the tone.
        XCTAssertGreaterThanOrEqual(vad.currentThreshold, EnergyVAD().minimumRMS)
        XCTAssertLessThan(vad.currentThreshold, vad.currentRMS)
        XCTAssertEqual(vad.currentConfidence ?? -1, 0.05, accuracy: 0.0001)
    }

    // MARK: Protocol defaults

    func testEnergyDetectorHasNoConfidence() {
        let vad: VoiceActivityDetector = EnergyVAD()
        XCTAssertNil(vad.currentConfidence)
    }

    func testFactoryClassifiesDetectors() {
        XCTAssertEqual(VoiceActivityDetectorFactory.kind(of: EnergyVAD()), .energy)
        XCTAssertEqual(VoiceActivityDetectorFactory.kind(of: SileroVAD(runner: FakeSileroRunner())), .silero)
    }

    // MARK: Runner helpers

    func testRowMajorOffsetsHonourStrides() {
        // Contiguous (2, 1, 128): offsets are 0..<256.
        let contiguous = CoreMLSileroRunner.rowMajorOffsets(shape: [2, 1, 128], strides: [128, 128, 1])
        XCTAssertEqual(contiguous, Array(0..<256))
        // Padded leading stride (e.g. 160 instead of 128).
        let padded = CoreMLSileroRunner.rowMajorOffsets(shape: [2, 1, 128], strides: [160, 160, 1])
        XCTAssertEqual(padded[0], 0)
        XCTAssertEqual(padded[127], 127)
        XCTAssertEqual(padded[128], 160)
        XCTAssertEqual(padded[255], 287)
        // A scalar.
        XCTAssertEqual(CoreMLSileroRunner.rowMajorOffsets(shape: [], strides: []), [0])
    }
}
