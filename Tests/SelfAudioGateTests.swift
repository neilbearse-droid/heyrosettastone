import XCTest
@testable import Rosetta

/// The capture path mutes the microphone while the phone itself is making
/// sound (`CaptureController.handleChunk` reads `selfSpeakingUntil`). The
/// board's voice already used this gate; stored-clip playback (chips on
/// Confirm, Review, Dictionary) must too, or his own clip played back
/// through the speaker becomes a new utterance — and a new session that
/// clears the card the parent is labelling.
final class SelfAudioGateTests: XCTestCase {
    func testClipPlaybackGatesCaptureForTheClipLengthPlusTail() {
        let speech = SpeechOutput.shared
        let before = Date()
        speech.beginSelfPlayback(duration: 2.0)

        let gate = speech.selfSpeakingUntil
        XCTAssertGreaterThanOrEqual(gate.timeIntervalSince(before), 2.0 + SpeechOutput.selfSpeechTail - 0.01)
        XCTAssertLessThan(gate.timeIntervalSince(before), 2.0 + SpeechOutput.selfSpeechTail + 1.0)

        // Stopped early: only the tail remains.
        speech.endSelfPlayback()
        let released = speech.selfSpeakingUntil
        XCTAssertLessThanOrEqual(released.timeIntervalSince(Date()), SpeechOutput.selfSpeechTail + 0.01)
        XCTAssertGreaterThan(released, before)
    }

    func testALongerGateIsNeverShortenedByANewPlayback() {
        let speech = SpeechOutput.shared
        speech.beginSelfPlayback(duration: 5.0)
        let long = speech.selfSpeakingUntil
        speech.beginSelfPlayback(duration: 0.5)
        XCTAssertEqual(speech.selfSpeakingUntil, long, "a second clip inside a longer one keeps the longer gate")
        speech.endSelfPlayback()
    }
}
