import XCTest
import GRDB
@testable import Rosetta

/// §6 SLP report: inventory order and counts, context strings, weekly
/// growth buckets, and that `render` produces a PDF. No clip or photo
/// files are needed — the report never reads them.
final class SLPReportTests: XCTestCase {
    private var db: AppDatabase!
    private var utc: Calendar!
    /// Wednesday 28 Oct 2026, 12:00 UTC. ISO weeks (Monday start):
    /// current week starts 26 Oct, previous 19 Oct, and the oldest of
    /// twelve starts 10 Aug.
    private var now: Date!

    private let banana = IntentRecord(label: "banana", respondNote: "Offer the banana from the fruit bowl")
    private let cup = IntentRecord(label: "cup")
    private let outside = IntentRecord(label: "outside")

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        utc = calendar
        now = date(2026, 10, 28, 12)
    }

    // MARK: - Fixture

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return utc.date(from: components)!
    }

    private func insertExemplar(_ intent: IntentRecord,
                                session: String,
                                capturedAt: Date,
                                device: String,
                                labeller: String) throws {
        let exemplar = ExemplarRecord(
            intentId: intent.id,
            clipRef: UUID().uuidString,
            device: device,
            labeller: labeller,
            timestamp: capturedAt.addingTimeInterval(3600), // confirmed an hour later
            sessionId: session,
            capturedAt: capturedAt
        )
        try db.dbQueue.write { try exemplar.insert($0) }
    }

    private func insertFixture() throws {
        let intents = IntentStore(db: db)
        for intent in [banana, cup, outside] { try intents.insert(intent) }
        let sessions = SessionStore(db: db)
        let events = EventLog(db: db)

        // banana: 6 clips from 3 exchanges, all mornings in the kitchen.
        // Five of them in the week of 19 Oct (so it "reaches 5" there),
        // the sixth in the week of 26 Oct.
        let bananaSessions: [(String, Date)] = [
            ("b1", date(2026, 10, 19, 8)),
            ("b2", date(2026, 10, 21, 7)),
            ("b3", date(2026, 10, 27, 8)),
        ]
        for (id, start) in bananaSessions {
            try sessions.insert(SessionRecord(id: id, startedAt: start, endedAt: start.addingTimeInterval(40), device: "Kitchen"))
        }
        try insertExemplar(banana, session: "b1", capturedAt: date(2026, 10, 19, 8), device: "Kitchen", labeller: "Mom")
        try insertExemplar(banana, session: "b1", capturedAt: date(2026, 10, 19, 8).addingTimeInterval(5), device: "Kitchen", labeller: "Mom")
        try insertExemplar(banana, session: "b2", capturedAt: date(2026, 10, 21, 7), device: "Kitchen", labeller: "Dad")
        try insertExemplar(banana, session: "b2", capturedAt: date(2026, 10, 21, 7).addingTimeInterval(5), device: "Kitchen", labeller: "Dad")
        try insertExemplar(banana, session: "b2", capturedAt: date(2026, 10, 21, 7).addingTimeInterval(10), device: "Kitchen", labeller: "Dad")
        try insertExemplar(banana, session: "b3", capturedAt: date(2026, 10, 27, 8), device: "Kitchen", labeller: "Mom")

        // cup: 2 clips, one afternoon, one evening, in the bathroom.
        try sessions.insert(SessionRecord(id: "c1", startedAt: date(2026, 10, 26, 14), device: "Bathroom"))
        try sessions.insert(SessionRecord(id: "c2", startedAt: date(2026, 10, 27, 18), device: "Bathroom"))
        try insertExemplar(cup, session: "c1", capturedAt: date(2026, 10, 26, 14), device: "Bathroom", labeller: "Mom")
        try insertExemplar(cup, session: "c2", capturedAt: date(2026, 10, 27, 18), device: "Bathroom", labeller: "Mom")

        // Confirmations: banana 3 confirms + 2 board taps (5), cup 2.
        try events.log(EventRecord(exchangeId: "b1", type: .confirm, intentId: banana.id, latencyMs: 20_000, device: "Kitchen", timestamp: date(2026, 10, 19, 9)))
        try events.log(EventRecord(exchangeId: "b2", type: .confirm, intentId: banana.id, latencyMs: 40_000, device: "Kitchen", timestamp: date(2026, 10, 21, 8)))
        try events.log(EventRecord(exchangeId: "b2", type: .confirm, intentId: banana.id, latencyMs: 30_000, device: "Kitchen", timestamp: date(2026, 10, 21, 8).addingTimeInterval(1)))
        try events.log(EventRecord(exchangeId: nil, type: .boardTap, intentId: banana.id, device: "Kitchen", timestamp: date(2026, 10, 22, 8)))
        try events.log(EventRecord(exchangeId: nil, type: .boardTap, intentId: banana.id, device: "Kitchen", timestamp: date(2026, 10, 23, 8)))
        try events.log(EventRecord(exchangeId: "c1", type: .confirm, intentId: cup.id, latencyMs: 10_000, device: "Bathroom", timestamp: date(2026, 10, 26, 15)))
        try events.log(EventRecord(exchangeId: "c2", type: .confirm, intentId: cup.id, latencyMs: 60_000, device: "Bathroom", timestamp: date(2026, 10, 27, 19)))

        // Exchange outcomes in the week of 19 Oct: b1 resolved (confirm
        // event), one abandoned session with an expired clip. Sessions
        // need a segment to count at all.
        for (id, start) in bananaSessions {
            try sessions.insertSegment(SegmentRecord(
                id: "seg-\(id)", sessionId: id, clipRef: "seg-\(id)", startedAt: start, durationMs: 800,
                state: .labelled, labelledAt: start.addingTimeInterval(3600)))
        }
        for (id, start) in [("c1", date(2026, 10, 26, 14)), ("c2", date(2026, 10, 27, 18))] {
            try sessions.insertSegment(SegmentRecord(
                id: "seg-\(id)", sessionId: id, clipRef: "seg-\(id)", startedAt: start, durationMs: 600,
                state: .labelled, labelledAt: start.addingTimeInterval(3600)))
        }
        try sessions.insert(SessionRecord(id: "lost", startedAt: date(2026, 10, 22, 16), device: "Kitchen"))
        try sessions.insertSegment(SegmentRecord(
            id: "seg-lost", sessionId: "lost", clipRef: "seg-lost", startedAt: date(2026, 10, 22, 16),
            durationMs: 500, state: .expired))
    }

    // MARK: - Tests

    func testInventoryOrderCountsAndContexts() throws {
        try insertFixture()
        let data = try SLPReportData.build(db: db, labeller: "Mom", maturity: nil, now: now, calendar: utc)

        XCTAssertEqual(data.preparedBy, "Mom")
        XCTAssertEqual(data.generatedAt, now)
        XCTAssertEqual(data.stations, ["Bathroom", "Kitchen"])
        XCTAssertEqual(data.labellers, ["Dad", "Mom"])
        XCTAssertEqual(data.totalClips, 8)
        XCTAssertEqual(data.inventory.map(\.label), ["banana", "cup", "outside"], "most confirmed first")

        let bananaRow = data.inventory[0]
        XCTAssertEqual(bananaRow.id, banana.id)
        XCTAssertEqual(bananaRow.clipCount, 6)
        XCTAssertEqual(bananaRow.exchangeCount, 3)
        XCTAssertEqual(bananaRow.confirmationCount, 5, "confirms plus his own board taps")
        XCTAssertEqual(bananaRow.respondNote, "Offer the banana from the fruit bowl")
        XCTAssertEqual(bananaRow.typicalTimes, ["mornings"])
        XCTAssertEqual(bananaRow.typicalStation, "Kitchen")
        XCTAssertEqual(bananaRow.firstConfirmedAt, date(2026, 10, 19, 9))
        XCTAssertEqual(bananaRow.lastConfirmedAt, date(2026, 10, 27, 9))
        XCTAssertEqual(bananaRow.maturity, "no live guessing on this phone yet")

        let cupRow = data.inventory[1]
        XCTAssertEqual(cupRow.clipCount, 2)
        XCTAssertEqual(cupRow.exchangeCount, 2)
        XCTAssertEqual(cupRow.confirmationCount, 2)
        XCTAssertNil(cupRow.respondNote)
        XCTAssertEqual(cupRow.typicalTimes, ["afternoons", "evenings"], "a tie keeps the order of the day")
        XCTAssertEqual(cupRow.typicalStation, "Bathroom")

        let outsideRow = data.inventory[2]
        XCTAssertEqual(outsideRow.clipCount, 0)
        XCTAssertEqual(outsideRow.exchangeCount, 0)
        XCTAssertEqual(outsideRow.confirmationCount, 0)
        XCTAssertEqual(outsideRow.typicalTimes, [])
        XCTAssertNil(outsideRow.typicalStation)
        XCTAssertNil(outsideRow.firstConfirmedAt)
        XCTAssertNil(outsideRow.lastConfirmedAt)
    }

    func testMaturityTextFromReports() throws {
        try insertFixture()
        let reports = [
            MaturityGate.Report(intentId: banana.id, exemplarCount: 6, sessionCount: 3, looTop3HitRate: 0.8, isSuggestible: true),
            MaturityGate.Report(intentId: cup.id, exemplarCount: 2, sessionCount: 2, looTop3HitRate: nil, isSuggestible: false),
        ]
        let data = try SLPReportData.build(db: db, labeller: "", maturity: reports, now: now, calendar: utc)
        XCTAssertEqual(data.preparedBy, "the family")
        XCTAssertEqual(data.inventory[0].maturity, "guessed live — recognizes 80% of its own clips")
        XCTAssertEqual(data.inventory[1].maturity, "learning — 2 of \(MaturityGate.Config().minExemplars) clips needed")
        XCTAssertEqual(data.inventory[2].maturity, "counting confirmations")
    }

    func testGrowthBucketsByISOWeek() throws {
        try insertFixture()
        let data = try SLPReportData.build(db: db, labeller: "Mom", maturity: nil, now: now, calendar: utc)

        XCTAssertEqual(data.weeks.count, SLPReportData.weeksCovered)
        XCTAssertEqual(data.weeks.first?.weekStart, date(2026, 8, 10), "twelve Monday-start weeks ending with the current one")
        XCTAssertEqual(data.weeks.last?.weekStart, date(2026, 10, 26))
        for pair in zip(data.weeks, data.weeks.dropFirst()) {
            XCTAssertEqual(pair.1.weekStart.timeIntervalSince(pair.0.weekStart), 7 * 86_400)
        }

        let empty = data.weeks[0]
        XCTAssertEqual(empty.newClips, 0)
        XCTAssertEqual(empty.wordsReachingFive, [])
        XCTAssertNil(empty.medianLatencyMs)
        XCTAssertEqual(empty.exchangesResolved, 0)
        XCTAssertEqual(empty.exchangesAbandoned, 0)

        let weekOf19 = data.weeks[10]
        XCTAssertEqual(weekOf19.weekStart, date(2026, 10, 19))
        XCTAssertEqual(weekOf19.newClips, 5)
        XCTAssertEqual(weekOf19.wordsReachingFive, ["banana"])
        XCTAssertEqual(weekOf19.medianLatencyMs, 30_000)
        XCTAssertEqual(weekOf19.exchangesResolved, 2, "b1 by confirm event, b2 by confirm event")
        XCTAssertEqual(weekOf19.exchangesAbandoned, 1, "the expired one")

        let weekOf26 = data.weeks[11]
        XCTAssertEqual(weekOf26.newClips, 3, "one banana, two cup")
        XCTAssertEqual(weekOf26.wordsReachingFive, [])
        XCTAssertEqual(weekOf26.medianLatencyMs, 60_000, "upper median of 10 s and 60 s, as EventLog does it")
        XCTAssertEqual(weekOf26.exchangesResolved, 3, "b3 by its labelled segment, c1 and c2 by confirm events")
        XCTAssertEqual(weekOf26.exchangesAbandoned, 0)
    }

    func testHelpers() {
        XCTAssertEqual(SLPReportData.timeOfDay(date(2026, 10, 28, 5), calendar: utc), "mornings")
        XCTAssertEqual(SLPReportData.timeOfDay(date(2026, 10, 28, 11), calendar: utc), "mornings")
        XCTAssertEqual(SLPReportData.timeOfDay(date(2026, 10, 28, 12), calendar: utc), "afternoons")
        XCTAssertEqual(SLPReportData.timeOfDay(date(2026, 10, 28, 17), calendar: utc), "evenings")
        XCTAssertEqual(SLPReportData.timeOfDay(date(2026, 10, 28, 21), calendar: utc), "nights")
        XCTAssertEqual(SLPReportData.timeOfDay(date(2026, 10, 28, 3), calendar: utc), "nights")

        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = utc.timeZone
        let starts = SLPReportData.weekStarts(endingAt: now, count: 3, calendar: iso)
        XCTAssertEqual(starts, [date(2026, 10, 12), date(2026, 10, 19), date(2026, 10, 26)])
        XCTAssertEqual(SLPReportData.weekStarts(endingAt: now, count: 0, calendar: iso), [])
    }

    func testBuildIsDeterministicAndEquatable() throws {
        try insertFixture()
        let a = try SLPReportData.build(db: db, labeller: "Mom", maturity: nil, now: now, calendar: utc)
        let b = try SLPReportData.build(db: db, labeller: "Mom", maturity: nil, now: now, calendar: utc)
        XCTAssertEqual(a, b)
    }

    func testRenderProducesPDF() throws {
        try insertFixture()
        let data = try SLPReportData.build(db: db, labeller: "Mom", maturity: nil, now: now, calendar: utc)
        let pdf = SLPReport.render(data)
        XCTAssertGreaterThan(pdf.count, 1000)
        XCTAssertEqual(String(decoding: pdf.prefix(4), as: UTF8.self), "%PDF")
        XCTAssertEqual(SLPReport.fileName(for: data), "Rosetta-SLP-report-2026-10-28.pdf")

        let url = try SLPReport.writeTemporaryPDF(data)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(url.lastPathComponent, "Rosetta-SLP-report-2026-10-28.pdf")
        XCTAssertEqual(try Data(contentsOf: url).prefix(4), pdf.prefix(4))
    }

    func testRenderEmptyDatabaseAndManyWordsPaginate() throws {
        // Empty: still a valid one-page PDF.
        let empty = try SLPReportData.build(db: db, labeller: "Mom", maturity: nil, now: now, calendar: utc)
        XCTAssertEqual(empty.inventory, [])
        XCTAssertEqual(empty.totalClips, 0)
        XCTAssertEqual(String(decoding: SLPReport.render(empty).prefix(4), as: UTF8.self), "%PDF")

        // Many words: more rows than fit on one page must not throw and
        // must come out larger than the one-page document.
        let intents = IntentStore(db: db)
        for index in 0..<80 {
            try intents.insert(IntentRecord(label: "word \(index)", respondNote: "Respond note \(index)"))
        }
        let long = try SLPReportData.build(db: db, labeller: "Mom", maturity: nil, now: now, calendar: utc)
        XCTAssertEqual(long.inventory.count, 80)
        let pdf = SLPReport.render(long)
        XCTAssertEqual(String(decoding: pdf.prefix(4), as: UTF8.self), "%PDF")
        XCTAssertGreaterThan(pdf.count, SLPReport.render(empty).count)
    }
}
