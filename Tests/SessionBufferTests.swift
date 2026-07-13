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
        // Roughly the 1 s tone, plus pre-roll, minus nothing meaningful.
        XCTAssertEqual(segment.duration, 1.0, accuracy: 0.3)
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
