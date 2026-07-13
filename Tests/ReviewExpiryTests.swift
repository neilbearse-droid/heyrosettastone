import XCTest
@testable import Rosetta

/// §4.4: segments leave the Review queue 24 hours after capture because
/// parental memory goes stale — but they are kept, flagged unlabelled,
/// never deleted.
final class ReviewExpiryTests: XCTestCase {
    private var db: AppDatabase!
    private var sessions: SessionStore!
    private var queue: ReviewQueue!
    private let now = Date(timeIntervalSinceReferenceDate: 2_000_000)

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
        sessions = SessionStore(db: db)
        queue = ReviewQueue(db: db)
        try sessions.insert(SessionRecord(id: "s", startedAt: now.addingTimeInterval(-100_000), device: "Kitchen"))
    }

    private func addSegment(id: String, ageHours: Double, state: SegmentState = .pending) throws {
        try sessions.insertSegment(SegmentRecord(
            id: id,
            sessionId: "s",
            clipRef: "clip-\(id)",
            startedAt: now.addingTimeInterval(-ageHours * 3600),
            durationMs: 700,
            state: state
        ))
    }

    func testFreshSegmentsStayInQueueStaleOnesExpire() throws {
        try addSegment(id: "fresh", ageHours: 2)
        try addSegment(id: "yesterday", ageHours: 23)
        try addSegment(id: "stale", ageHours: 25)
        try addSegment(id: "ancient", ageHours: 90)

        let pending = try queue.pending(now: now)

        XCTAssertEqual(Set(pending.map(\.id)), Set(["fresh", "yesterday"]))
        XCTAssertEqual(Set(try queue.expired().map(\.id)), Set(["stale", "ancient"]))
    }

    func testExpiredSegmentsAreKeptNotDeleted() throws {
        try addSegment(id: "stale", ageHours: 30)
        _ = try queue.pending(now: now)

        // Still on disk (in the table), flagged unlabelled — not deleted.
        let all = try db.dbQueue.read { try SegmentRecord.fetchAll($0) }
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].segmentState, .expired)
        XCTAssertNil(all[0].labelledAt)
    }

    func testExpirySweepIgnoresResolvedSegments() throws {
        try addSegment(id: "labelled-old", ageHours: 48, state: .labelled)
        try addSegment(id: "discarded-old", ageHours: 48, state: .discarded)
        try addSegment(id: "notHim-old", ageHours: 48, state: .notHim)

        _ = try queue.pending(now: now)

        let all = try db.dbQueue.read { try SegmentRecord.fetchAll($0) }
        XCTAssertEqual(all.first { $0.id == "labelled-old" }?.segmentState, .labelled)
        XCTAssertEqual(all.first { $0.id == "discarded-old" }?.segmentState, .discarded)
        XCTAssertEqual(all.first { $0.id == "notHim-old" }?.segmentState, .notHim)
        XCTAssertTrue(try queue.expired().isEmpty)
    }

    func testQueueOrdersOldestFirst() throws {
        try addSegment(id: "newer", ageHours: 1)
        try addSegment(id: "older", ageHours: 10)

        let pending = try queue.pending(now: now)
        XCTAssertEqual(pending.map(\.id), ["older", "newer"],
                       "evening batch labelling works oldest-first before memory fades")
    }
}
