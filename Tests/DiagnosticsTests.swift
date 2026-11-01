import XCTest
import GRDB
@testable import Rosetta

/// `LiveAccuracy`: the Phase 2 acceptance criterion measured on real
/// confirmations. Fixture: four exchanges, plus the rows that must not
/// count (a legacy observation with no exchange id, a confirmation the
/// model was silent on).
final class DiagnosticsTests: XCTestCase {
    private var db: AppDatabase!
    private var banana: IntentRecord!
    private var water: IntentRecord!
    private var outside: IntentRecord!
    private let now = Date(timeIntervalSinceReferenceDate: 3_000_000)
    private var since: Date { now.addingTimeInterval(-30 * 24 * 3600) }

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
        banana = IntentRecord(label: "banana")
        water = IntentRecord(label: "water")
        outside = IntentRecord(label: "outside")
        let intents = IntentStore(db: db)
        for intent in [banana!, water!, outside!] {
            try intents.insert(intent)
        }
    }

    // MARK: - Fixtures

    private func observe(_ intent: IntentRecord, z: Double, exchange: String?, accepted: Bool, at: Date? = nil) throws {
        try CalibrationStore(db: db).record(CalibrationObservationRecord(
            intentId: intent.id,
            score: z,
            accepted: accepted,
            timestamp: at ?? now,
            exchangeId: exchange,
            featureVersion: CalibrationFeature.version
        ))
    }

    private func confirm(_ intent: IntentRecord, exchange: String, at: Date? = nil) throws {
        try EventLog(db: db).log(EventRecord(
            exchangeId: exchange, type: .confirm, intentId: intent.id, latencyMs: 4000,
            device: "Kitchen", timestamp: at ?? now
        ))
    }

    /// e1: banana top, confirmed banana (shown, top).
    /// e2: water top, confirmed banana (shown, not top).
    /// e3: only water shown, confirmed outside (not shown).
    /// e4: banana shown, skipped — no confirmation, not counted.
    private func seedFourExchanges() throws {
        try observe(banana, z: 2.0, exchange: "e1", accepted: true)
        try observe(water, z: 1.0, exchange: "e1", accepted: false)
        try confirm(banana, exchange: "e1")

        try observe(banana, z: 1.5, exchange: "e2", accepted: true)
        try observe(water, z: 1.8, exchange: "e2", accepted: false)
        try confirm(banana, exchange: "e2")

        try observe(water, z: 1.2, exchange: "e3", accepted: false)
        try confirm(outside, exchange: "e3")

        try observe(banana, z: 0.5, exchange: "e4", accepted: false)
        try EventLog(db: db).log(EventRecord(exchangeId: "e4", type: .skip, device: "Kitchen", timestamp: now))
    }

    // MARK: - Tests

    func testSummaryOverFourExchanges() throws {
        try seedFourExchanges()
        // Must not count: a pre-v4 row with no exchange, and a confirmation
        // the model said nothing about.
        try observe(banana, z: 3.0, exchange: nil, accepted: true)
        try confirm(water, exchange: "silent-exchange")

        let summary = try LiveAccuracy.summary(db: db, since: since, now: now)

        XCTAssertEqual(summary.exchangesWithGuesses, 3, "e1, e2, e3; e4 was skipped")
        XCTAssertEqual(summary.confirmedWordShown, 2, "e1 and e2")
        XCTAssertEqual(summary.confirmedWordWasTop, 1, "e1 only")

        let byId = Dictionary(uniqueKeysWithValues: summary.perIntent.map { ($0.intentId, $0) })
        let bananaRow = try XCTUnwrap(byId[banana.id])
        XCTAssertEqual(bananaRow.label, "banana")
        XCTAssertEqual(bananaRow.shown, 2)
        XCTAssertEqual(bananaRow.confirmedWhenShown, 2)
        XCTAssertEqual(bananaRow.confirmedWhenNotShown, 0)

        let waterRow = try XCTUnwrap(byId[water.id])
        XCTAssertEqual(waterRow.shown, 3)
        XCTAssertEqual(waterRow.confirmedWhenShown, 0)
        XCTAssertEqual(waterRow.confirmedWhenNotShown, 0, "the silent exchange is not a miss here")

        let outsideRow = try XCTUnwrap(byId[outside.id])
        XCTAssertEqual(outsideRow.shown, 0)
        XCTAssertEqual(outsideRow.confirmedWhenShown, 0)
        XCTAssertEqual(outsideRow.confirmedWhenNotShown, 1, "e3: the answer, but not offered")

        XCTAssertEqual(summary.perIntent.map(\.intentId), [water.id, banana.id, outside.id],
                       "most shown first, then by label")
    }

    func testEmptyWhenNothingWasGuessed() throws {
        try confirm(banana, exchange: "e1")
        let summary = try LiveAccuracy.summary(db: db, since: since, now: now)
        XCTAssertEqual(summary, .empty)
    }

    func testWindowIsAppliedToObservations() throws {
        let old = since.addingTimeInterval(-60)
        try observe(banana, z: 2.0, exchange: "old", accepted: true, at: old)
        try confirm(banana, exchange: "old", at: old)
        try observe(banana, z: 2.0, exchange: "new", accepted: true)
        try confirm(banana, exchange: "new")

        let summary = try LiveAccuracy.summary(db: db, since: since, now: now)
        XCTAssertEqual(summary.exchangesWithGuesses, 1)
        XCTAssertEqual(summary.confirmedWordShown, 1)
    }

    func testADismissedThenReshownGuessCountsOnceAtItsBestScore() throws {
        // Dismissed at z 0.4 early in the exchange; by the yes moment the
        // engine excluded it, so only the dismissal row exists for water.
        try observe(water, z: 0.4, exchange: "e1", accepted: false)
        try observe(banana, z: 0.3, exchange: "e1", accepted: true)
        try observe(banana, z: 0.9, exchange: "e1", accepted: true)
        try confirm(banana, exchange: "e1")

        let summary = try LiveAccuracy.summary(db: db, since: since, now: now)
        XCTAssertEqual(summary.exchangesWithGuesses, 1)
        XCTAssertEqual(summary.confirmedWordShown, 1)
        XCTAssertEqual(summary.confirmedWordWasTop, 1, "banana's best score (0.9) beats water's (0.4)")
        let bananaRow = try XCTUnwrap(summary.perIntent.first { $0.intentId == banana.id })
        XCTAssertEqual(bananaRow.shown, 1, "two rows, one exchange")
    }

    // MARK: - v4 migration

    func testMigrationV4AddsNullableColumnsWithoutBackfill() throws {
        let queue = DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v3-capture-context")
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO intents (id, label, createdAt) VALUES (?, ?, ?)",
                arguments: ["i", "banana", now])
            // Stamped at the feature cutoff, not at the fixture's 2001 `now`:
            // with a nil version column the timestamp decides, and the
            // assertion below is that such a row still counts as current.
            try db.execute(
                sql: """
                INSERT INTO calibrationObservations (id, intentId, score, accepted, timestamp)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: ["o", "i", 1.2, true, CalibrationFeature.versionCutoff])
        }

        let migrated = try AppDatabase(queue: queue)
        let row = try XCTUnwrap(migrated.dbQueue.read { try CalibrationObservationRecord.fetchOne($0, key: "o") })
        XCTAssertNil(row.exchangeId)
        XCTAssertNil(row.featureVersion)
        XCTAssertTrue(CalibrationFeature.matchesCurrentVersion(row), "nil column: the timestamp cutoff decides")

        // New rows carry both, and the indexes exist.
        try CalibrationStore(db: migrated).record(CalibrationObservationRecord(
            intentId: "i", score: 0.8, accepted: false, timestamp: now,
            exchangeId: "e", featureVersion: CalibrationFeature.version
        ))
        let fresh = try migrated.dbQueue.read { db in
            try CalibrationObservationRecord.filter(Column("exchangeId") == "e").fetchOne(db)
        }
        XCTAssertEqual(fresh?.featureVersion, CalibrationFeature.version)
        let indexNames = try migrated.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'")
        }
        XCTAssertTrue(indexNames.contains("calibration_exchange"))
        XCTAssertTrue(indexNames.contains("negatives_exchange"))
    }
}
