import XCTest
@testable import Rosetta

/// §2.8 / §4.2: the common case is two taps — chips arrive pre-selected
/// (zero taps), one tap picks the intent. And §2.4: a dismissed guess is
/// gone for good.
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
}
