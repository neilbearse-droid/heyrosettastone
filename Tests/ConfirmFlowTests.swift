import XCTest
@testable import Rosetta

/// §2.8 / §4.2: the common case is two taps — chips arrive pre-selected
/// (zero taps), one tap picks the intent. §2.4: a dismissed guess is gone
/// for good, including when he keeps talking and new chips land (C3). D6:
/// a clip labelled in Review leaves the card. C9: every guess on screen at
/// the yes moment is reported as an outcome.
final class ConfirmFlowTests: XCTestCase {
    private var db: AppDatabase!
    private var segments: [SegmentRecord] = []
    private var banana: IntentRecord!
    private var outside: IntentRecord!
    private let sessionId = "session-1"
    private let openedAt = Date(timeIntervalSinceReferenceDate: 1_000_000)

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
        let intents = IntentStore(db: db)
        let sessions = SessionStore(db: db)

        banana = IntentRecord(label: "banana")
        outside = IntentRecord(label: "outside")
        try intents.insert(banana)
        try intents.insert(outside)

        try sessions.insert(SessionRecord(id: sessionId, startedAt: openedAt, device: "Kitchen"))
        segments = (0..<3).map { i in
            SegmentRecord(
                sessionId: sessionId,
                clipRef: "clip-\(i)",
                startedAt: openedAt.addingTimeInterval(Double(i) * 5),
                durationMs: 800
            )
        }
        for segment in segments {
            try sessions.insertSegment(segment)
        }
    }

    private func makeModel() -> ConfirmViewModel {
        ConfirmViewModel(
            segments: segments,
            exchangeId: sessionId,
            exchangeOpenedAt: openedAt,
            device: "Kitchen",
            labeller: "Mom",
            db: db
        )
    }

    private func suggestion(_ intent: IntentRecord, z: Double) -> Suggestion {
        Suggestion(
            intent: intent,
            rawScore: z,
            probability: 0.6,
            prior: 1,
            rankingScore: 0.6,
            votes: 1
        )
    }

    // MARK: - Two-tap path

    func testTwoTapPathSavesEverySegmentWithOneIntentTap() throws {
        let model = makeModel()

        // Tap zero: nothing — every chip is pre-selected by default.
        XCTAssertEqual(model.selectedSegmentIds, Set(segments.map(\.id)))

        // The single intent tap.
        let created = try model.confirm(intentId: banana.id, now: openedAt.addingTimeInterval(20))

        XCTAssertEqual(created.count, 3, "one tap saves every selected segment as an exemplar")
        XCTAssertTrue(created.allSatisfy { $0.intentId == banana.id })
        XCTAssertEqual(Set(created.map(\.clipRef)), Set(segments.map(\.clipRef)))
        XCTAssertTrue(created.allSatisfy { $0.labeller == "Mom" && $0.device == "Kitchen" })

        // The confirm event carries the exchange latency (§2.9 metric).
        let events = try db.dbQueue.read { try EventRecord.fetchAll($0) }
        let confirmEvent = events.first { $0.eventType == .confirm }
        XCTAssertEqual(confirmEvent?.latencyMs, 20_000)
        XCTAssertEqual(confirmEvent?.exchangeId, sessionId)
    }

    func testDismissedGuessIsFinalAndStoredAsHardNegative() throws {
        let model = makeModel()

        model.dismiss(intentId: outside.id)

        // One negative per selected segment (§4.2.3).
        let negatives = try db.dbQueue.read { try NegativeRecord.fetchAll($0) }
        XCTAssertEqual(negatives.count, 3)
        XCTAssertTrue(negatives.allSatisfy { $0.rejectedIntentId == outside.id })
        XCTAssertEqual(Set(negatives.compactMap(\.clipRef)), Set(segments.map(\.clipRef)))
        XCTAssertTrue(negatives.allSatisfy { $0.exchangeId == sessionId }, "negatives carry the exchange so the engine can exclude them")

        // Gone from the candidate grid for the rest of the exchange.
        let intents = try IntentStore(db: db).all()
        let candidates = model.candidates(from: intents, counts: [:])
        XCTAssertFalse(candidates.contains { $0.id == outside.id })

        // And confirming it anyway is refused — rejection is final (§2.4).
        let created = try model.confirm(intentId: outside.id)
        XCTAssertTrue(created.isEmpty)
        XCTAssertEqual(try ExemplarStore(db: db).totalCount(), 0)

        // The exchange can still resolve to a different intent.
        let saved = try model.confirm(intentId: banana.id)
        XCTAssertEqual(saved.count, 3)
    }

    func testDeselectedChipStaysOutOfTheSave() throws {
        let model = makeModel()
        model.toggleSegment(segments[2].id)

        let created = try model.confirm(intentId: banana.id)
        XCTAssertEqual(created.count, 2)
        XCTAssertFalse(created.contains { $0.clipRef == segments[2].clipRef })
    }

    func testSkippedExchangeLandsInReview() throws {
        let model = makeModel()
        model.skip()

        XCTAssertEqual(try ExemplarStore(db: db).totalCount(), 0)
        let pending = try ReviewQueue(db: db).pending(now: openedAt.addingTimeInterval(3600))
        XCTAssertEqual(pending.count, 3, "skipped segments stay pending for the evening queue")
    }

    func testConfirmIsIdempotentPerExchange() throws {
        let model = makeModel()
        _ = try model.confirm(intentId: banana.id)
        let second = try model.confirm(intentId: banana.id)
        XCTAssertTrue(second.isEmpty, "a resolved exchange must not double-save")
        XCTAssertEqual(try ExemplarStore(db: db).totalCount(), 3)
    }

    // MARK: - C3: the exchange keeps going after a no

    func testDismissalAndDeselectionSurviveANewSegmentMidExchange() throws {
        let model = makeModel()
        model.dismiss(intentId: outside.id)
        model.toggleSegment(segments[1].id) // "that one was his sister"

        // He says it again: capture appends a fourth chip to the same session.
        let late = SegmentRecord(
            sessionId: sessionId,
            clipRef: "clip-late",
            startedAt: openedAt.addingTimeInterval(30),
            durationMs: 600
        )
        try SessionStore(db: db).insertSegment(late)
        model.absorb(newSegments: segments + [late])

        XCTAssertEqual(model.segments.map(\.id), segments.map(\.id) + [late.id])
        XCTAssertTrue(model.selectedSegmentIds.contains(late.id), "a new chip arrives selected")
        XCTAssertFalse(model.selectedSegmentIds.contains(segments[1].id), "an unticked chip stays unticked")
        XCTAssertTrue(model.selectedSegmentIds.contains(segments[0].id))

        let candidates = model.candidates(from: try IntentStore(db: db).all(), counts: [:])
        XCTAssertFalse(candidates.contains { $0.id == outside.id }, "the dismissed guess does not come back")
        XCTAssertTrue(try model.confirm(intentId: outside.id).isEmpty)

        let created = try model.confirm(intentId: banana.id)
        XCTAssertEqual(Set(created.map(\.clipRef)), ["clip-0", "clip-2", "clip-late"])
    }

    func testAbsorbIsIdempotentAndRefreshesEmbeddings() throws {
        let model = makeModel()
        model.absorb(newSegments: segments)
        XCTAssertEqual(model.segments.count, 3, "known segments are not duplicated")

        // Capture persisted the embedding after the card's snapshot.
        var embedded = segments[0]
        embedded.embedding = Data([1, 2, 3, 4])
        model.absorb(newSegments: [embedded])

        XCTAssertEqual(model.segments.count, 3)
        XCTAssertEqual(model.segments.first?.embedding, Data([1, 2, 3, 4]))

        // The hard negative written on dismiss carries that embedding.
        model.dismiss(intentId: outside.id)
        let negatives = try db.dbQueue.read { try NegativeRecord.fetchAll($0) }
        let forFirst = negatives.first { $0.clipRef == segments[0].clipRef }
        XCTAssertEqual(forFirst?.embedding, Data([1, 2, 3, 4]))
    }

    // MARK: - D6: a clip resolved elsewhere leaves the card

    func testSegmentLabelledInReviewCannotBeLabelledTwice() throws {
        let model = makeModel()

        // Dad labels the third clip in Review while the card is still up.
        _ = try ExemplarStore(db: db).confirm(
            segments: [segments[2]], intentId: banana.id, device: "Kitchen", labeller: "Dad")
        model.syncWithDatabase()

        XCTAssertEqual(model.segments.map(\.id), [segments[0].id, segments[1].id])
        XCTAssertFalse(model.selectedSegmentIds.contains(segments[2].id))

        let created = try model.confirm(intentId: banana.id)
        XCTAssertEqual(created.count, 2)
        XCTAssertEqual(try ExemplarStore(db: db).totalCount(), 3, "the Review exemplar plus two from the card")
    }

    func testSegmentDiscardedInReviewLeavesTheCard() throws {
        let model = makeModel()
        try SessionStore(db: db).discard(id: segments[0].id)
        model.syncWithDatabase()
        XCTAssertEqual(model.segments.map(\.id), [segments[1].id, segments[2].id])
        XCTAssertEqual(model.selectedSegmentIds, [segments[1].id, segments[2].id])
    }

    // MARK: - C9: every shown guess is an outcome

    func testConfirmReportsEveryShownGuessAsAnOutcome() throws {
        let model = makeModel()
        model.topGuesses = [suggestion(banana, z: 1.2), suggestion(outside, z: 0.4)]

        var recorded: (shown: [Suggestion], confirmed: String, exchange: String?)?
        model.outcomeRecorder = { shown, confirmed, exchange in
            recorded = (shown: shown, confirmed: confirmed, exchange: exchange)
        }

        _ = try model.confirm(intentId: banana.id)

        let outcome = try XCTUnwrap(recorded)
        XCTAssertEqual(outcome.shown.map(\.id), [banana.id, outside.id], "both guesses on screen are reported")
        XCTAssertEqual(outcome.confirmed, banana.id)
        XCTAssertEqual(outcome.exchange, sessionId)
    }

    func testConfirmFromTheGridStillReportsTheShownGuessesAsRejected() throws {
        let model = makeModel()
        model.topGuesses = [suggestion(outside, z: 0.9)]

        var recorded: (shown: [Suggestion], confirmed: String)?
        model.outcomeRecorder = { shown, confirmed, _ in recorded = (shown: shown, confirmed: confirmed) }

        // Parent ignores the guess and picks banana from the grid (§4.5:
        // the model was wrong; that is the extra-valuable signal).
        _ = try model.confirm(intentId: banana.id)

        let outcome = try XCTUnwrap(recorded)
        XCTAssertEqual(outcome.shown.map(\.id), [outside.id])
        XCTAssertNotEqual(outcome.confirmed, outside.id)
    }

    func testDismissedGuessLeavesTheDisplayedGuessesAndTheOutcomeReport() throws {
        let model = makeModel()
        model.topGuesses = [suggestion(outside, z: 0.9), suggestion(banana, z: 0.8)]
        XCTAssertEqual(model.displayedGuesses.map(\.id), [outside.id, banana.id])

        model.dismiss(intentId: outside.id)
        XCTAssertEqual(model.displayedGuesses.map(\.id), [banana.id], "a dismissed guess is off screen immediately")

        var shownAtConfirm: [String]?
        model.outcomeRecorder = { shown, _, _ in shownAtConfirm = shown.map(\.id) }
        _ = try model.confirm(intentId: banana.id)
        XCTAssertEqual(shownAtConfirm, [banana.id], "the dismissed guess already had its rejection recorded; it is not reported twice")
    }

    func testRecorderIsStillInvokedWhenNoGuessWasShown() throws {
        let model = makeModel()
        var called = false
        model.outcomeRecorder = { _, _, _ in called = true }
        _ = try model.confirm(intentId: banana.id)
        XCTAssertTrue(called, "the recorder is still invoked; the engine ignores an empty list")
    }

    // MARK: - D5: his own board tap is pinned

    func testBoardTapInThisExchangeIsPinnedUntilDismissed() throws {
        let log = EventLog(db: db)
        try log.log(EventRecord(exchangeId: sessionId, type: .boardTap, intentId: outside.id,
                                device: "Kitchen", timestamp: openedAt.addingTimeInterval(8)))
        try log.log(EventRecord(exchangeId: sessionId, type: .boardTap, intentId: banana.id,
                                device: "Kitchen", timestamp: openedAt.addingTimeInterval(12)))
        try log.log(EventRecord(exchangeId: sessionId, type: .boardTap, intentId: banana.id,
                                device: "Kitchen", timestamp: openedAt.addingTimeInterval(13)))
        try log.log(EventRecord(exchangeId: "another-session", type: .boardTap, intentId: outside.id,
                                device: "Kitchen", timestamp: openedAt.addingTimeInterval(14)))

        let model = makeModel()
        XCTAssertEqual(model.boardTappedIntentIds(), [banana.id, outside.id], "most recent first, de-duplicated, this exchange only")

        model.dismiss(intentId: banana.id)
        XCTAssertEqual(model.boardTappedIntentIds(), [outside.id])
    }
}
