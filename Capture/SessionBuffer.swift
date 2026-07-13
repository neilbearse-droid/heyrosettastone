import Foundation

/// One VAD-detected utterance, with its audio, cut from the stream.
struct CapturedSegment: Equatable {
    let id: String
    let sessionId: String
    /// 16 kHz mono samples, including pre-roll.
    let samples: [Float]
    /// Seconds from stream start to segment start.
    let startTime: TimeInterval
    let duration: TimeInterval
}

enum SessionCloseReason: Equatable {
    /// 10 s with no detected speech (§4.2).
    case silence
    /// 90 s total (§4.2).
    case maxDuration
    /// Listening was paused or stopped mid-session.
    case interrupted
}

protocol SessionBufferDelegate: AnyObject {
    func sessionOpened(id: String, atStreamTime time: TimeInterval)
    func segmentCaptured(_ segment: CapturedSegment)
    func sessionClosed(id: String, atStreamTime time: TimeInterval, reason: SessionCloseReason)
}

/// The exchange session state machine (§4.2), pure logic over a sample
/// stream. Time is the sample counter — there is no wall clock in here —
/// so tests drive it deterministically with fixture audio and the engine
/// drives it with live microphone frames. Silence advances time too, because
/// the microphone keeps delivering frames; that is what closes sessions.
///
/// Rules implemented:
///   - a session opens at the first detected utterance
///   - it closes after 10 s without speech, or at 90 s total, whichever first
///   - every detected utterance within the session is retained
final class SessionBuffer {
    static let sampleRate = 16_000
    /// 30 ms frames.
    static let frameLength = 480

    struct Tuning {
        /// Session closes after this much silence.
        var silenceClose: TimeInterval = 10
        /// Session closes at this total length regardless.
        var maxSessionLength: TimeInterval = 90
        /// Speech frames required to open an utterance (debounce).
        var onsetFrames = 3
        /// Non-speech run that ends an utterance.
        var hangover: TimeInterval = 0.5
        /// Utterances shorter than this are dropped as blips.
        var minUtterance: TimeInterval = 0.25
        /// Audio kept before the detected onset so word starts aren't clipped.
        var preRoll: TimeInterval = 0.15
    }

    weak var delegate: SessionBufferDelegate?
    let tuning: Tuning
    private var vad: VoiceActivityDetector

    private(set) var activeSessionId: String?

    // Stream clock, in samples since start.
    private var streamPosition = 0
    private var pendingSamples: [Float] = []

    // Rolling pre-roll buffer of the most recent samples.
    private var preRollBuffer: [Float] = []
    private var preRollCapacity: Int { Int(tuning.preRoll * Double(Self.sampleRate)) }

    // Utterance state.
    private var speechRun = 0
    private var silenceRun = 0
    private var utteranceSamples: [Float]?
    private var utteranceStartSample = 0

    // Session state.
    private var sessionStartSample = 0
    private var lastSpeechSample = 0

    init(vad: VoiceActivityDetector = EnergyVAD(), tuning: Tuning = Tuning()) {
        self.vad = vad
        self.tuning = tuning
    }

    var streamTime: TimeInterval { Double(streamPosition) / Double(Self.sampleRate) }

    /// Feed any number of 16 kHz mono samples; internally processed in
    /// 30 ms frames, remainder carried to the next call.
    func ingest(_ samples: [Float]) {
        pendingSamples.append(contentsOf: samples)
        while pendingSamples.count >= Self.frameLength {
            let frame = Array(pendingSamples.prefix(Self.frameLength))
            pendingSamples.removeFirst(Self.frameLength)
            process(frame: frame)
        }
    }

    /// Force-close any open utterance and session (pause tapped, engine
    /// stopped). Nothing captured is lost.
    func interrupt() {
        endUtteranceIfOpen()
        closeSessionIfOpen(reason: .interrupted)
        pendingSamples.removeAll()
        speechRun = 0
        silenceRun = 0
        vad.reset()
    }

    // MARK: - Internals

    private func process(frame: [Float]) {
        streamPosition += frame.count

        // Maintain the rolling recent-audio buffer. It must hold enough to
        // recover both the pre-roll and the onset-debounce frames when an
        // utterance is confirmed.
        preRollBuffer.append(contentsOf: frame)
        let ringCapacity = preRollCapacity + tuning.onsetFrames * Self.frameLength
        if preRollBuffer.count > ringCapacity {
            preRollBuffer.removeFirst(preRollBuffer.count - ringCapacity)
        }

        let speech = vad.isSpeech(frame[...])
        if speech {
            speechRun += 1
            silenceRun = 0
            lastSpeechSample = streamPosition
        } else {
            silenceRun += 1
            speechRun = 0
        }

        if utteranceSamples != nil {
            utteranceSamples?.append(contentsOf: frame)
            let hangoverFrames = Int(tuning.hangover * Double(Self.sampleRate)) / Self.frameLength
            if silenceRun >= hangoverFrames {
                endUtteranceIfOpen()
            }
        } else if speechRun >= tuning.onsetFrames {
            // Utterance began onsetFrames ago; recover those frames plus
            // pre-roll from the ring buffer.
            let onsetSamples = tuning.onsetFrames * Self.frameLength
            let rollback = min(preRollBuffer.count, onsetSamples + preRollCapacity)
            utteranceStartSample = max(0, streamPosition - rollback)
            utteranceSamples = Array(preRollBuffer.suffix(rollback))

            if activeSessionId == nil {
                openSession(atSample: utteranceStartSample)
            }
        }

        checkSessionTimeouts()
    }

    private func openSession(atSample sample: Int) {
        let id = UUID().uuidString
        activeSessionId = id
        sessionStartSample = sample
        lastSpeechSample = sample
        delegate?.sessionOpened(id: id, atStreamTime: Double(sample) / Double(Self.sampleRate))
    }

    private func endUtteranceIfOpen() {
        guard var samples = utteranceSamples, let sessionId = activeSessionId else {
            utteranceSamples = nil
            return
        }
        utteranceSamples = nil

        // Trim the trailing silence that was counted while waiting out the
        // hangover (zero when the utterance was cut mid-speech).
        let trailingSilence = min(samples.count, silenceRun * Self.frameLength)
        samples.removeLast(trailingSilence)

        let duration = Double(samples.count) / Double(Self.sampleRate)
        guard duration >= tuning.minUtterance else { return }

        delegate?.segmentCaptured(CapturedSegment(
            id: UUID().uuidString,
            sessionId: sessionId,
            samples: samples,
            startTime: Double(utteranceStartSample) / Double(Self.sampleRate),
            duration: duration
        ))
    }

    private func checkSessionTimeouts() {
        guard activeSessionId != nil else { return }

        let sessionLength = Double(streamPosition - sessionStartSample) / Double(Self.sampleRate)
        if sessionLength >= tuning.maxSessionLength {
            endUtteranceIfOpen()
            closeSessionIfOpen(reason: .maxDuration)
            return
        }

        let silence = Double(streamPosition - lastSpeechSample) / Double(Self.sampleRate)
        if utteranceSamples == nil, silence >= tuning.silenceClose {
            closeSessionIfOpen(reason: .silence)
        }
    }

    private func closeSessionIfOpen(reason: SessionCloseReason) {
        guard let id = activeSessionId else { return }
        activeSessionId = nil
        delegate?.sessionClosed(id: id, atStreamTime: streamTime, reason: reason)
    }
}
