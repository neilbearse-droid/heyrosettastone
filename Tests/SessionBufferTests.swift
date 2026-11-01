import XCTest
@testable import Rosetta

/// The spec's most important test (§10): across a long, noisy exchange, the
/// buffer cuts the right segments at the right times, so a later label
/// attaches to the correct audio.
final class SessionBufferTests: XCTestCase {
    private func makeBuffer(recorder: BufferRecorder) -> SessionBuffer {
        let buffer = SessionBuffer()
        buffer.delegate = recorder
        return buffer
    }

    func testSingleUtteranceOpensSessionAndClosesOnSilence() {
        let recorder = BufferRecorder()
        let buffer = makeBuffer(recorder: recorder)

        buffer.ingest(AudioFixtures.silence(seconds: 0.5))
        buffer.ingest(AudioFixtures.tone(seconds: 1.0))
        buffer.ingest(AudioFixtures.silence(seconds: 11))

        XCTAssertEqual(recorder.opens.count, 1)
        XCTAssertEqual(recorder.segments.count, 1)
        XCTAssertEqual(recorder.closes.count, 1)
        XCTAssertEqual(recorder.closes[0].reason, .silence)

        let segment = recorder.segments[0]
        // Started near the 0.5 s mark (pre-roll reaches slightly earlier).
        XCTAssertEqual(segment.startTime, 0.5, accuracy: 0.2)
        // The 1 s tone plus ~0.15 s pre-roll and ~0.15 s post-roll
        // (Tuning.preRoll / Tuning.postRoll), so ~1.3 s.
        XCTAssertEqual(segment.duration, 1.3, accuracy: 0.3)
        // The session closed ~10 s after speech ended.
        XCTAssertEqual(recorder.closes[0].time, 11.5, accuracy: 0.6)
    }

    func testStampingAcrossLongNoisyExchange() {
        let recorder = BufferRecorder()
        let buffer = makeBuffer(recorder: recorder)

        // A realistic exchange: room noise throughout the gaps, three
        // utterances at known offsets, then the room goes quiet.
        buffer.ingest(AudioFixtures.roomNoise(seconds: 2.0))          // 0–2
        buffer.ingest(AudioFixtures.tone(seconds: 0.8))                // 2–2.8  utterance 1
        buffer.ingest(AudioFixtures.roomNoise(seconds: 3.0, seed: 7))  // 2.8–5.8
        buffer.ingest(AudioFixtures.tone(seconds: 1.2, frequency: 250)) // 5.8–7  utterance 2
        buffer.ingest(AudioFixtures.roomNoise(seconds: 6.0, seed: 9))  // 7–13
        buffer.ingest(AudioFixtures.tone(seconds: 0.6, frequency: 400)) // 13–13.6 utterance 3
        buffer.ingest(AudioFixtures.roomNoise(seconds: 11.0, seed: 3)) // 13.6–24.6 closes it

        XCTAssertEqual(recorder.opens.count, 1, "one exchange session for the whole back-and-forth")
        XCTAssertEqual(recorder.closes.count, 1)
        XCTAssertEqual(recorder.closes[0].reason, .silence)
        XCTAssertEqual(recorder.segments.count, 3)

        // Every segment carries the session id — the stamp labels rely on.
        let sessionId = recorder.opens[0].id
        XCTAssertTrue(recorder.segments.allSatisfy { $0.sessionId == sessionId })

        // Segment timing pins each chip to the utterance it came from.
        XCTAssertEqual(recorder.segments[0].startTime, 2.0, accuracy: 0.25)
        XCTAssertEqual(recorder.segments[1].startTime, 5.8, accuracy: 0.25)
        XCTAssertEqual(recorder.segments[2].startTime, 13.0, accuracy: 0.25)

        // And the cut audio is the loud part, not the noise floor: every
        // captured segment should contain high-energy samples.
        for segment in recorder.segments {
            let peak = segment.samples.map(abs).max() ?? 0
            XCTAssertGreaterThan(peak, 0.3, "segment should contain the utterance audio")
        }
    }

    func testSessionClosesAtNinetySecondCap() {
        let recorder = BufferRecorder()
        let buffer = makeBuffer(recorder: recorder)

        // Talkative exchange: 2 s speech / 5 s gap, forever. Gaps never
        // reach the 10 s silence close, so only the cap can end it.
        for _ in 0..<15 {
            buffer.ingest(AudioFixtures.tone(seconds: 2.0))
            buffer.ingest(AudioFixtures.silence(seconds: 5.0))
        }

        XCTAssertEqual(recorder.closes.first?.reason, .maxDuration)
        // The cap counts from session open (~0 s), so close lands at ~90 s.
        XCTAssertEqual(recorder.closes.first?.time ?? 0, 90, accuracy: 1.0)
        // The exchange keeps capturing right up to the cap.
        XCTAssertGreaterThanOrEqual(recorder.segments.count, 12)
        // A second session opens for speech after the cap.
        XCTAssertEqual(recorder.opens.count, 2)
    }

    func testBlipTooShortForOnsetIsIgnored() {
        let recorder = BufferRecorder()
        let buffer = makeBuffer(recorder: recorder)

        // 30 ms click: a single speech frame, below the onset debounce.
        buffer.ingest(AudioFixtures.silence(seconds: 1))
        buffer.ingest(AudioFixtures.tone(seconds: 0.03))
        buffer.ingest(AudioFixtures.silence(seconds: 12))

        XCTAssertTrue(recorder.opens.isEmpty, "a click must not open an exchange")
        XCTAssertTrue(recorder.segments.isEmpty)
    }

    func testInterruptClosesSessionWithoutLosingCapturedSegments() {
        let recorder = BufferRecorder()
        let buffer = makeBuffer(recorder: recorder)

        buffer.ingest(AudioFixtures.tone(seconds: 1.0))
        buffer.ingest(AudioFixtures.silence(seconds: 1.0))  // utterance ends, session open
        buffer.interrupt()                                   // pause tapped

        XCTAssertEqual(recorder.segments.count, 1)
        XCTAssertEqual(recorder.closes.count, 1)
        XCTAssertEqual(recorder.closes[0].reason, .interrupted)
    }

    func testSustainedNoiseUnlatchesAndNeverExceedsMaxUtterance() {
        let recorder = BufferRecorder()
        let buffer = makeBuffer(recorder: recorder)

        // A TV comes on in the next room: steady noise just above the
        // cold-start threshold (RMS ~0.0115 vs minimumRMS 0.01), for a long
        // time. The old floor only adapted in silence, so this was "speech"
        // forever and the session ran to the 90 s cap.
        buffer.ingest(AudioFixtures.roomNoise(seconds: 15.0, amplitude: 0.02, seed: 11))

        XCTAssertEqual(recorder.opens.count, 1, "the onset is still detected (over-detection is the chosen bias)")
        // The floor absorbs the noise within a couple of seconds, so the
        // session closes on silence ~10 s after that, well inside 15 s.
        XCTAssertEqual(recorder.closes.count, 1, "the VAD must un-latch on sustained noise")
        XCTAssertEqual(recorder.closes.first?.reason, .silence)
        XCTAssertLessThan(recorder.closes.first?.time ?? .infinity, 13.0)
        // Nothing but a short burst at the start was cut.
        XCTAssertLessThanOrEqual(recorder.segments.count, 2)
        for segment in recorder.segments {
            XCTAssertLessThanOrEqual(segment.duration, buffer.tuning.maxUtterance + 0.1)
        }
    }

    func testLatchedDetectorIsCutAtMaxUtterance() {
        let recorder = BufferRecorder()
        let buffer = makeBuffer(recorder: recorder)

        // Loud frames interleaved with short gaps: the hangover never
        // elapses and the floor never catches up, so without a cap this
        // would be one 20 s utterance.
        buffer.ingest(AudioFixtures.pulsedTone(seconds: 20.0))
        buffer.ingest(AudioFixtures.silence(seconds: 11.0))

        XCTAssertEqual(recorder.opens.count, 1)
        XCTAssertEqual(recorder.closes.count, 1)
        XCTAssertEqual(recorder.closes.first?.reason, .silence)
        XCTAssertGreaterThanOrEqual(recorder.segments.count, 3, "20 s of speech is cut into 8 s pieces")
        for segment in recorder.segments {
            XCTAssertLessThanOrEqual(segment.duration, buffer.tuning.maxUtterance + 0.05,
                                     "no segment may exceed Tuning.maxUtterance")
        }
        // The pieces are cut mid-speech, so the first ones are full length.
        XCTAssertEqual(recorder.segments[0].duration, buffer.tuning.maxUtterance, accuracy: 0.05)
    }

    func testSubOnsetBlipDoesNotExtendSession() {
        let recorder = BufferRecorder()
        let buffer = makeBuffer(recorder: recorder)

        buffer.ingest(AudioFixtures.tone(seconds: 1.0))      // 0–1    utterance
        buffer.ingest(AudioFixtures.silence(seconds: 5.0))   // 1–6
        buffer.ingest(AudioFixtures.tone(seconds: 0.03))     // 6–6.03 a dropped spoon: one frame
        buffer.ingest(AudioFixtures.silence(seconds: 6.0))   // 6.03–12.03

        XCTAssertEqual(recorder.opens.count, 1)
        XCTAssertEqual(recorder.segments.count, 1, "the blip is below the onset debounce")
        // Speech ended at ~1 s, so the 10 s silence close lands at ~11 s.
        // If the blip had reset the silence timer the session would still
        // be open at 12 s (close at ~16 s).
        XCTAssertEqual(recorder.closes.count, 1, "a sub-onset blip must not keep the exchange open")
        XCTAssertEqual(recorder.closes.first?.reason, .silence)
        XCTAssertEqual(recorder.closes.first?.time ?? 0, 11.0, accuracy: 0.5)
    }

    func testPostRollPreservesQuietWordEnding() {
        let recorder = BufferRecorder()
        let buffer = makeBuffer(recorder: recorder)

        // A loud vowel followed by a 100 ms low-energy consonant tail that
        // the energy VAD classes as silence (RMS ~0.003, below the gate).
        buffer.ingest(AudioFixtures.tone(seconds: 1.0))                        // 0–1
        buffer.ingest(AudioFixtures.tone(seconds: 0.1, amplitude: 0.004))      // 1–1.1 the tail
        buffer.ingest(AudioFixtures.silence(seconds: 11.0))

        XCTAssertEqual(recorder.segments.count, 1)
        let segment = recorder.segments[0]
        let end = segment.startTime + segment.duration
        // The segment must run past the end of the tail: trimming the full
        // hangover used to cut it at ~1.02 s.
        XCTAssertGreaterThanOrEqual(end, 1.1, "the quiet tail must survive the post-roll")
        // And the tail audio is actually in the clip, not just its duration.
        let tailStart = AudioFixtures.samples(seconds: 1.0 - segment.startTime)
        let tailEnd = min(segment.samples.count, tailStart + AudioFixtures.samples(seconds: 0.1))
        XCTAssertLessThan(tailStart, tailEnd)
        let tailPeak = segment.samples[tailStart..<tailEnd].map(abs).max() ?? 0
        XCTAssertGreaterThan(tailPeak, 0.001, "the tail samples should be present in the segment")
        XCTAssertLessThan(tailPeak, 0.01, "and should be the quiet tail, not the vowel")
    }

    func testMutedChunksAdvanceTheClockWithoutTrainingTheDetector() {
        // The board speaks mid-exchange. Capture feeds zeros flagged muted:
        // the open utterance must still end, the session must still close
        // on time, but the detector must not learn "the room is silent"
        // from synthetic zeros and come back hair-trigger.
        let recorder = BufferRecorder()
        let buffer = makeBuffer(recorder: recorder)
        buffer.ingest(AudioFixtures.tone(seconds: 1.0))
        let thresholdAfterSpeech = buffer.liveLevel.threshold

        buffer.ingest(AudioFixtures.silence(seconds: 1.0), muted: true)
        XCTAssertEqual(buffer.streamTime, 2.0, accuracy: 0.03, "muted audio still advances the clock")
        XCTAssertEqual(recorder.segments.count, 1, "the utterance ends through the normal hangover")
        XCTAssertEqual(recorder.segments[0].duration, 1.3, accuracy: 0.3)
        XCTAssertEqual(buffer.liveLevel.threshold, thresholdAfterSpeech,
                       "the detector was neither consulted nor trained while muted")

        buffer.ingest(AudioFixtures.silence(seconds: 10.0), muted: true)
        XCTAssertEqual(recorder.closes.count, 1, "the 10 s silence close still fires on muted time")
        XCTAssertEqual(recorder.closes[0].reason, .silence)

        // Control: the same zeros unmuted collapse the floor.
        let control = makeBuffer(recorder: BufferRecorder())
        control.ingest(AudioFixtures.tone(seconds: 1.0))
        control.ingest(AudioFixtures.silence(seconds: 1.0))
        XCTAssertLessThan(control.liveLevel.threshold, thresholdAfterSpeech)
    }

    func testSileroDetectorDrivesTheSameExchangeSemantics() {
        // Same exchange as testSingleUtteranceOpensSessionAndClosesOnSilence,
        // detected by SileroVAD over a fake runner that calls a window
        // "speech" (0.9) while the tone is in it and silent (0.05) after:
        // the buffer's debounce, hangover, pre/post-roll and the 10 s close
        // must come out identical, because the detector only changes
        // detection quality, never exchange semantics.
        let runner = FakeSileroRunner(decide: { window in
            AudioFixtures.rms(window) > 0.1 ? 0.9 : 0.05
        })
        let recorder = BufferRecorder()
        let buffer = SessionBuffer(vad: SileroVAD(runner: runner))
        buffer.delegate = recorder

        buffer.ingest(AudioFixtures.silence(seconds: 0.5))
        buffer.ingest(AudioFixtures.tone(seconds: 1.0))
        buffer.ingest(AudioFixtures.silence(seconds: 11))

        XCTAssertEqual(recorder.opens.count, 1)
        XCTAssertEqual(recorder.segments.count, 1)
        XCTAssertEqual(recorder.closes.count, 1)
        XCTAssertEqual(recorder.closes[0].reason, .silence)

        let segment = recorder.segments[0]
        XCTAssertEqual(segment.startTime, 0.5, accuracy: 0.2)
        // The 1 s tone plus pre-roll and post-roll; the Silero window lag
        // (≤ 32 ms) is inside the tolerance.
        XCTAssertEqual(segment.duration, 1.3, accuracy: 0.3)
        XCTAssertEqual(recorder.closes[0].time, 11.5, accuracy: 0.6)

        // The model ran once per 512 samples over every whole 480-sample
        // frame of the 12.5 s: 416 frames = 199 680 samples = 390 windows.
        let wholeFrames = AudioFixtures.samples(seconds: 12.5) / SessionBuffer.frameLength
        XCTAssertEqual(runner.calls, wholeFrames * SessionBuffer.frameLength / SileroVAD.windowSamples)

        // The detector reports the model's probability and the energy
        // readout: silence at the end, so low confidence and low RMS.
        let detector = buffer.detector
        XCTAssertEqual(detector.currentConfidence ?? -1, 0.05, accuracy: 0.0001)
        XCTAssertEqual(detector.currentRMS, 0, accuracy: 0.0001)
        XCTAssertGreaterThan(detector.currentThreshold, 0)
    }

    func testLabelAttachesToCorrectSegments() throws {
        // End-to-end stamping: buffer output → database rows → confirm →
        // exemplars carry exactly the selected segments' clips.
        let recorder = BufferRecorder()
        let buffer = makeBuffer(recorder: recorder)

        buffer.ingest(AudioFixtures.roomNoise(seconds: 1.0))
        buffer.ingest(AudioFixtures.tone(seconds: 0.7))
        buffer.ingest(AudioFixtures.roomNoise(seconds: 2.0, seed: 5))
        buffer.ingest(AudioFixtures.tone(seconds: 0.7, frequency: 260))
        buffer.ingest(AudioFixtures.roomNoise(seconds: 2.0, seed: 6))
        buffer.ingest(AudioFixtures.tone(seconds: 0.7, frequency: 500))
        buffer.ingest(AudioFixtures.roomNoise(seconds: 11.0, seed: 8))

        XCTAssertEqual(recorder.segments.count, 3)

        let db = try AppDatabase.inMemory()
        let sessionStore = SessionStore(db: db)
        let intentStore = IntentStore(db: db)

        let sessionId = recorder.opens[0].id
        try sessionStore.insert(SessionRecord(id: sessionId, startedAt: Date(), device: "Kitchen"))
        var records: [SegmentRecord] = []
        for captured in recorder.segments {
            let record = SegmentRecord(
                id: captured.id,
                sessionId: sessionId,
                clipRef: captured.id,
                startedAt: Date().addingTimeInterval(captured.startTime),
                durationMs: Int(captured.duration * 1000)
            )
            try sessionStore.insertSegment(record)
            records.append(record)
        }

        let banana = IntentRecord(label: "banana")
        try intentStore.insert(banana)

        // The parent deselects the middle chip (someone else's voice) and
        // confirms. The label must attach to segments 1 and 3 only.
        let model = ConfirmViewModel(
            segments: records,
            exchangeId: sessionId,
            exchangeOpenedAt: Date(),
            device: "Kitchen",
            labeller: "Mom",
            db: db
        )
        model.toggleSegment(records[1].id)
        let created = try model.confirm(intentId: banana.id)

        XCTAssertEqual(created.count, 2)
        XCTAssertEqual(
            Set(created.map(\.clipRef)),
            Set([records[0].clipRef, records[2].clipRef]),
            "exemplars must reference exactly the selected segments' audio"
        )

        // The deselected segment stays pending for Review; the others are
        // flagged labelled.
        let after = try sessionStore.segments(sessionId: sessionId)
        XCTAssertEqual(after.first { $0.id == records[1].id }?.segmentState, .pending)
        XCTAssertEqual(after.first { $0.id == records[0].id }?.segmentState, .labelled)
        XCTAssertEqual(after.first { $0.id == records[2].id }?.segmentState, .labelled)
    }
}
