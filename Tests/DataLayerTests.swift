import XCTest
import GRDB
@testable import Rosetta

/// Data-layer guarantees the rest of the app leans on: confirmation keeps
/// the embedding capture wrote after the card's snapshot (B1), deletion
/// really deletes audio (B3), the abandoned-exchange metric (§2.9 / D3),
/// export → wipe → import round trip (B2), the v3 back-fill, and the
/// launch-time sweeps (B5 / B6).
final class DataLayerTests: XCTestCase {
    private var db: AppDatabase!
    private var tempRoot: URL!
    private let now = Date(timeIntervalSinceReferenceDate: 3_000_000)

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RosettaDataLayerTests-\(UUID().uuidString)", isDirectory: true)
        FileLocations.rootOverride = tempRoot
        try FileManager.default.createDirectory(at: FileLocations.clips, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: FileLocations.photos, withIntermediateDirectories: true)
        db = try AppDatabase.inMemory()
    }

    override func tearDownWithError() throws {
        FileLocations.rootOverride = nil
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - Fixtures

    private func writeClip(_ ref: String, byte: UInt8 = 7) throws {
        try Data(repeating: byte, count: 64).write(to: FileLocations.clipURL(id: ref))
    }

    private func clipExists(_ ref: String) -> Bool {
        FileManager.default.fileExists(atPath: FileLocations.clipURL(id: ref).path)
    }

    private func addSession(id: String, startedAt: Date, endedAt: Date? = nil) throws {
        try SessionStore(db: db).insert(
            SessionRecord(id: id, startedAt: startedAt, endedAt: endedAt, device: "Kitchen"))
    }

    @discardableResult
    private func addSegment(id: String,
                            sessionId: String,
                            startedAt: Date,
                            state: SegmentState = .pending,
                            labelledAt: Date? = nil,
                            withClip: Bool = true) throws -> SegmentRecord {
        let record = SegmentRecord(
            id: id,
            sessionId: sessionId,
            clipRef: id,
            startedAt: startedAt,
            durationMs: 700,
            state: state,
            labelledAt: labelledAt
        )
        try SessionStore(db: db).insertSegment(record)
        if withClip { try writeClip(id) }
        return record
    }

    private func segment(_ id: String) throws -> SegmentRecord? {
        try db.dbQueue.read { try SegmentRecord.fetchOne($0, key: id) }
    }

    private func assertSameInstant(_ a: Date, _ b: Date, _ message: String = "",
                                   file: StaticString = #filePath, line: UInt = #line) {
        // GRDB stores millisecond precision; JSON export uses whole seconds.
        XCTAssertEqual(a.timeIntervalSince(b), 0, accuracy: 1.0, message, file: file, line: line)
    }

    // MARK: - B1: confirm keeps the fresh embedding

    func testConfirmPreservesEmbeddingWrittenAfterSnapshot() throws {
        let banana = IntentRecord(label: "banana")
        try IntentStore(db: db).insert(banana)
        try addSession(id: "s", startedAt: now)
        let snapshot = try addSegment(id: "g", sessionId: "s", startedAt: now.addingTimeInterval(2))
        XCTAssertNil(snapshot.embedding)

        // Capture finishes encoding after the card took its snapshot.
        let blob = Data([1, 2, 3, 4])
        try SessionStore(db: db).updateSegmentEmbedding(id: "g", embedding: blob)

        let confirmedAt = now.addingTimeInterval(8 * 3600)
        let created = try ExemplarStore(db: db).confirm(
            segments: [snapshot], intentId: banana.id, device: "Kitchen", labeller: "Mom", now: confirmedAt)

        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(created[0].embedding, blob, "the exemplar carries the embedding, not the stale nil")
        XCTAssertEqual(created[0].sessionId, "s")
        assertSameInstant(created[0].capturedAt, snapshot.startedAt, "capturedAt is capture time, not confirm time")
        assertSameInstant(created[0].timestamp, confirmedAt)

        let row = try XCTUnwrap(segment("g"))
        XCTAssertEqual(row.embedding, blob, "the segment row keeps its embedding")
        XCTAssertEqual(row.segmentState, .labelled)
        let labelledAt = try XCTUnwrap(row.labelledAt)
        assertSameInstant(labelledAt, confirmedAt)

        let stored = try db.dbQueue.read { try ExemplarRecord.fetchAll($0) }
        XCTAssertEqual(stored.first?.embedding, blob)
        XCTAssertEqual(stored.first?.sessionId, "s")
    }

    func testConfirmSkipsSegmentsWhoseClipWasDeleted() throws {
        let banana = IntentRecord(label: "banana")
        try IntentStore(db: db).insert(banana)
        try addSession(id: "s", startedAt: now)
        let snapshot = try addSegment(id: "g", sessionId: "s", startedAt: now)
        try SegmentStore(db: db).discard(id: "g", deleteClip: true, at: now)

        let created = try ExemplarStore(db: db).confirm(
            segments: [snapshot], intentId: banana.id, device: "Kitchen", labeller: "Mom", now: now)
        XCTAssertTrue(created.isEmpty, "no exemplar without audio")
    }

    // MARK: - B3: deletion deletes

    func testDeleteForeverRemovesClipFilesAndTombstonesSegments() throws {
        let banana = IntentRecord(label: "banana")
        let water = IntentRecord(label: "water")
        try IntentStore(db: db).insert(banana)
        try IntentStore(db: db).insert(water)
        try addSession(id: "s", startedAt: now)
        let g1 = try addSegment(id: "g1", sessionId: "s", startedAt: now)
        let g2 = try addSegment(id: "g2", sessionId: "s", startedAt: now.addingTimeInterval(3))
        let other = try addSegment(id: "other", sessionId: "s", startedAt: now.addingTimeInterval(6))

        let store = ExemplarStore(db: db)
        _ = try store.confirm(segments: [g1, g2], intentId: banana.id, device: "Kitchen", labeller: "Mom", now: now)
        _ = try store.confirm(segments: [other], intentId: water.id, device: "Kitchen", labeller: "Mom", now: now)
        XCTAssertTrue(clipExists("g1") && clipExists("g2") && clipExists("other"))

        try IntentStore(db: db).deleteForever(id: banana.id, now: now)

        XCTAssertFalse(clipExists("g1"), "the word's clips are gone from disk")
        XCTAssertFalse(clipExists("g2"))
        XCTAssertTrue(clipExists("other"), "another word's clip is untouched")
        XCTAssertNil(try IntentStore(db: db).fetch(id: banana.id))
        XCTAssertEqual(try store.count(intentId: banana.id), 0)

        let tomb = try XCTUnwrap(segment("g1"))
        XCTAssertEqual(tomb.segmentState, .discarded)
        XCTAssertEqual(tomb.clipRef, FileLocations.deletedClipRef)
        XCTAssertTrue(tomb.isClipDeleted)
        XCTAssertEqual(try segment("other")?.segmentState, .labelled)
    }

    func testDeleteForeverRemovesThePhotoUnlessAnotherWordShowsIt() throws {
        let fm = FileManager.default
        let banana = IntentRecord(label: "banana", photoRef: "photo-banana")
        let snack = IntentRecord(label: "snack", photoRef: "photo-shared")
        let hungry = IntentRecord(label: "hungry", photoRef: "photo-shared")
        for intent in [banana, snack, hungry] { try IntentStore(db: db).insert(intent) }
        try Data([1]).write(to: FileLocations.photoURL(id: "photo-banana"))
        try Data([2]).write(to: FileLocations.photoURL(id: "photo-shared"))

        XCTAssertEqual(try IntentStore(db: db).deleteForever(id: banana.id, now: now), "photo-banana")
        XCTAssertFalse(fm.fileExists(atPath: FileLocations.photoURL(id: "photo-banana").path), "his banana's photo goes with the word (§8)")

        XCTAssertNil(try IntentStore(db: db).deleteForever(id: snack.id, now: now), "hungry still shows that photo")
        XCTAssertTrue(fm.fileExists(atPath: FileLocations.photoURL(id: "photo-shared").path))
    }

    func testOrphanPhotoSweepKeepsReferencedAndFreshFiles() throws {
        let fm = FileManager.default
        try IntentStore(db: db).insert(IntentRecord(label: "banana", photoRef: "kept"))
        try IntentStore(db: db).insert(IntentRecord(label: "old", photoRef: "kept-archived", archivedAt: now))
        for ref in ["kept", "kept-archived", "replaced", "fresh"] {
            try Data([1]).write(to: FileLocations.photoURL(id: ref))
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(-3600)],
                                 ofItemAtPath: FileLocations.photoURL(id: ref).path)
        }
        try fm.setAttributes([.modificationDate: now], ofItemAtPath: FileLocations.photoURL(id: "fresh").path)

        XCTAssertEqual(try Maintenance.sweepOrphanPhotos(db: db, now: now), 1)
        XCTAssertFalse(fm.fileExists(atPath: FileLocations.photoURL(id: "replaced").path))
        XCTAssertTrue(fm.fileExists(atPath: FileLocations.photoURL(id: "kept").path))
        XCTAssertTrue(fm.fileExists(atPath: FileLocations.photoURL(id: "kept-archived").path), "an archived word keeps its photo")
        XCTAssertTrue(fm.fileExists(atPath: FileLocations.photoURL(id: "fresh").path), "may be a photo taken for a word still being typed")
    }

    func testDiscardWithDeleteClipRemovesFileAndTombstones() throws {
        try addSession(id: "s", startedAt: now)
        try addSegment(id: "keep", sessionId: "s", startedAt: now)
        try addSegment(id: "gone", sessionId: "s", startedAt: now)

        try SegmentStore(db: db).discard(id: "keep", deleteClip: false, at: now)
        try SegmentStore(db: db).discard(id: "gone", deleteClip: true, at: now)

        XCTAssertTrue(clipExists("keep"))
        XCTAssertEqual(try segment("keep")?.segmentState, .discarded)
        XCTAssertEqual(try segment("keep")?.clipRef, "keep")

        XCTAssertFalse(clipExists("gone"))
        let tomb = try XCTUnwrap(segment("gone"))
        XCTAssertEqual(tomb.segmentState, .discarded)
        XCTAssertEqual(tomb.clipRef, FileLocations.deletedClipRef)
        let tombLabelledAt = try XCTUnwrap(tomb.labelledAt)
        assertSameInstant(tombLabelledAt, now)
        XCTAssertNil(FileLocations.existingClipURL(id: tomb.clipRef))
    }

    func testMarkNotHimKeepsRowAsTombstone() throws {
        try addSession(id: "s", startedAt: now)
        try addSegment(id: "sister", sessionId: "s", startedAt: now)
        try SessionStore(db: db).markNotHim(id: "sister", deleteClip: true, at: now)

        XCTAssertFalse(clipExists("sister"))
        XCTAssertEqual(try segment("sister")?.segmentState, .notHim)
        XCTAssertEqual(try segment("sister")?.clipRef, FileLocations.deletedClipRef)
        XCTAssertEqual(try db.dbQueue.read { try SegmentRecord.fetchCount($0) }, 1, "the row survives")
    }

    func testExemplarPruneWithDeleteClipRemovesFileUnlessShared() throws {
        let banana = IntentRecord(label: "banana")
        try IntentStore(db: db).insert(banana)
        try addSession(id: "s", startedAt: now)
        let g = try addSegment(id: "g", sessionId: "s", startedAt: now)
        let store = ExemplarStore(db: db)
        let first = try store.confirm(segments: [g], intentId: banana.id, device: "Kitchen", labeller: "Mom", now: now)
        // A second exemplar over the same clip (Ask flow after Confirm).
        let second = try store.confirm(segments: [g], intentId: banana.id, device: "Kitchen", labeller: "Dad", now: now)

        try store.delete(id: first[0].id, deleteClip: true, now: now)
        XCTAssertTrue(clipExists("g"), "still referenced by another exemplar")

        try store.delete(id: second[0].id, deleteClip: true, now: now)
        XCTAssertFalse(clipExists("g"))
        XCTAssertEqual(try segment("g")?.clipRef, FileLocations.deletedClipRef)
        XCTAssertEqual(try store.totalCount(), 0)
    }

    func testWipeAllEmptiesEverythingAndResetsSetupFlag() throws {
        let banana = IntentRecord(label: "banana")
        try IntentStore(db: db).insert(banana)
        try addSession(id: "s", startedAt: now)
        try addSegment(id: "g", sessionId: "s", startedAt: now)
        UserDefaults.standard.set(true, forKey: "hasCompletedSetupInterview")

        try RosettaExporter(db: db).wipeAll()

        XCTAssertFalse(UserDefaults.standard.bool(forKey: "hasCompletedSetupInterview"))
        XCTAssertFalse(clipExists("g"))
        XCTAssertEqual(try db.dbQueue.read { try SegmentRecord.fetchCount($0) }, 0)
        XCTAssertEqual(try db.dbQueue.read { try IntentRecord.fetchCount($0) }, 0)
    }

    // MARK: - D3: abandoned-exchange rate

    func testAbandonedRateOnOneConfirmedAndOneAbandonedSession() throws {
        let banana = IntentRecord(label: "banana")
        try IntentStore(db: db).insert(banana)
        let twoDaysAgo = now.addingTimeInterval(-2 * 24 * 3600)

        // Session A: confirmed on the card.
        try addSession(id: "a", startedAt: twoDaysAgo, endedAt: twoDaysAgo.addingTimeInterval(20))
        let ga = try addSegment(id: "ga", sessionId: "a", startedAt: twoDaysAgo.addingTimeInterval(1), withClip: false)
        _ = try ExemplarStore(db: db).confirm(
            segments: [ga], intentId: banana.id, device: "Kitchen", labeller: "Mom",
            now: twoDaysAgo.addingTimeInterval(15))
        try EventLog(db: db).log(EventRecord(
            exchangeId: "a", type: .confirm, intentId: banana.id, latencyMs: 15_000,
            device: "Kitchen", timestamp: twoDaysAgo.addingTimeInterval(15)))

        // Session B: never resolved; its segment expired in Review.
        try addSession(id: "b", startedAt: twoDaysAgo.addingTimeInterval(600), endedAt: twoDaysAgo.addingTimeInterval(640))
        try addSegment(id: "gb", sessionId: "b", startedAt: twoDaysAgo.addingTimeInterval(601),
                       state: .expired, withClip: false)

        // Session C: no segments at all (noise never cut an utterance) — not an exchange.
        try addSession(id: "c", startedAt: twoDaysAgo.addingTimeInterval(1200))

        let log = EventLog(db: db)
        let since = now.addingTimeInterval(-7 * 24 * 3600)
        let outcomes = try log.exchangeOutcomes(since: since, now: now)
        XCTAssertEqual(outcomes.resolved, 1)
        XCTAssertEqual(outcomes.abandoned, 1)
        let rate = try XCTUnwrap(log.abandonedRate(since: since, now: now))
        XCTAssertEqual(rate, 0.5, accuracy: 1e-9)
    }

    func testAbandonedRateCountsReviewLabellingAsResolvedAndExcludesUndecided() throws {
        let banana = IntentRecord(label: "banana")
        try IntentStore(db: db).insert(banana)
        let twoDaysAgo = now.addingTimeInterval(-2 * 24 * 3600)

        // Labelled in Review that evening, no confirm event with the exchange id.
        try addSession(id: "r", startedAt: twoDaysAgo)
        try addSegment(id: "gr", sessionId: "r", startedAt: twoDaysAgo, state: .labelled,
                       labelledAt: twoDaysAgo.addingTimeInterval(6 * 3600), withClip: false)

        // Opened an hour ago, still pending: undecided, not abandoned.
        try addSession(id: "fresh", startedAt: now.addingTimeInterval(-3600))
        try addSegment(id: "gf", sessionId: "fresh", startedAt: now.addingTimeInterval(-3600), withClip: false)

        let outcomes = try EventLog(db: db).exchangeOutcomes(since: now.addingTimeInterval(-7 * 24 * 3600), now: now)
        XCTAssertEqual(outcomes.resolved, 1)
        XCTAssertEqual(outcomes.abandoned, 0)
    }

    func testAbandonedRateTreatsHisBoardTapAsResolvedAndIgnoresSessionsThatWereNotHim() throws {
        let banana = IntentRecord(label: "banana")
        try IntentStore(db: db).insert(banana)
        let twoDaysAgo = now.addingTimeInterval(-2 * 24 * 3600)

        // He walked to the board and tapped banana mid-exchange; nobody
        // confirmed on the card and the chip expired. Understanding was
        // reached through his AAC: resolved.
        try addSession(id: "tap", startedAt: twoDaysAgo, endedAt: twoDaysAgo.addingTimeInterval(30))
        try addSegment(id: "gt", sessionId: "tap", startedAt: twoDaysAgo, state: .expired, withClip: false)
        try EventLog(db: db).log(EventRecord(
            exchangeId: "tap", type: .boardTap, intentId: banana.id, device: "Kitchen",
            timestamp: twoDaysAgo.addingTimeInterval(10)))

        // The TV, discarded in Review; his sister, marked not him. Neither
        // was an exchange with him, so neither counts on either side.
        try addSession(id: "tv", startedAt: twoDaysAgo.addingTimeInterval(600))
        try addSegment(id: "g-tv", sessionId: "tv", startedAt: twoDaysAgo.addingTimeInterval(600),
                       state: .discarded, labelledAt: twoDaysAgo.addingTimeInterval(7200), withClip: false)
        try addSession(id: "sis", startedAt: twoDaysAgo.addingTimeInterval(1200))
        try addSegment(id: "g-sis", sessionId: "sis", startedAt: twoDaysAgo.addingTimeInterval(1200),
                       state: .notHim, labelledAt: twoDaysAgo.addingTimeInterval(7200), withClip: false)

        // Labelled only after the 24 h window (the sweep had not run): abandoned.
        try addSession(id: "late", startedAt: twoDaysAgo.addingTimeInterval(1800))
        try addSegment(id: "g-late", sessionId: "late", startedAt: twoDaysAgo.addingTimeInterval(1800),
                       state: .labelled, labelledAt: twoDaysAgo.addingTimeInterval(26 * 3600), withClip: false)

        let log = EventLog(db: db)
        let since = now.addingTimeInterval(-7 * 24 * 3600)
        XCTAssertTrue(try log.hasResolution(exchangeId: "tap"))
        XCTAssertFalse(try log.hasResolution(exchangeId: "late"))
        let outcomes = try log.exchangeOutcomes(since: since, now: now)
        XCTAssertEqual(outcomes.resolved, 1)
        XCTAssertEqual(outcomes.abandoned, 1)
        XCTAssertEqual(try XCTUnwrap(log.abandonedRate(since: since, now: now)), 0.5, accuracy: 1e-9)
    }

    func testAbandonedRateIsNilWithNoSessions() throws {
        XCTAssertNil(try EventLog(db: db).abandonedRate(since: now.addingTimeInterval(-86_400), now: now))
    }

    // MARK: - B6: latency buckets by local day

    func testConfirmLatenciesBucketByLocalCalendarDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!
        let lateEvening = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 23, minute: 30)))
        let afterMidnight = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 11, hour: 0, minute: 30)))

        let log = EventLog(db: db)
        try log.log(EventRecord(exchangeId: "a", type: .confirm, intentId: "i", latencyMs: 10_000, device: "Kitchen", timestamp: lateEvening))
        try log.log(EventRecord(exchangeId: "b", type: .confirm, intentId: "i", latencyMs: 30_000, device: "Kitchen", timestamp: lateEvening.addingTimeInterval(60)))
        try log.log(EventRecord(exchangeId: "c", type: .confirm, intentId: "i", latencyMs: 20_000, device: "Kitchen", timestamp: afterMidnight))

        let trend = try log.confirmLatencies(since: lateEvening.addingTimeInterval(-86_400), calendar: calendar)
        XCTAssertEqual(trend.count, 2, "23:30 and 00:30 local are different days")
        XCTAssertEqual(trend[0].day, calendar.startOfDay(for: lateEvening))
        XCTAssertEqual(trend[0].medianMs, 30_000)
        XCTAssertEqual(trend[1].day, calendar.startOfDay(for: afterMidnight))
        XCTAssertEqual(trend[1].medianMs, 20_000)
    }

    // MARK: - B2: export → wipe → import

    func testExportWipeImportRoundTrip() throws {
        let banana = IntentRecord(label: "banana", photoRef: "photo-banana", boardSlot: 0)
        let water = IntentRecord(label: "water")
        try IntentStore(db: db).insert(banana)
        try IntentStore(db: db).insert(water)
        try Data(repeating: 9, count: 32).write(to: FileLocations.photoURL(id: "photo-banana"))

        try addSession(id: "s", startedAt: now, endedAt: now.addingTimeInterval(30))
        let g1 = try addSegment(id: "g1", sessionId: "s", startedAt: now.addingTimeInterval(1))
        let g2 = try addSegment(id: "g2", sessionId: "s", startedAt: now.addingTimeInterval(4))
        try addSegment(id: "g3", sessionId: "s", startedAt: now.addingTimeInterval(7))
        try SessionStore(db: db).updateSegmentEmbedding(id: "g1", embedding: Data([5, 6, 7]))

        let store = ExemplarStore(db: db)
        _ = try store.confirm(segments: [g1, g2], intentId: banana.id, device: "Kitchen", labeller: "Mom", now: now.addingTimeInterval(20))
        try store.recordNegative(NegativeRecord(rejectedIntentId: water.id, clipRef: "g1", exchangeId: "s", timestamp: now))
        try EventLog(db: db).log(EventRecord(exchangeId: "s", type: .confirm, intentId: banana.id, latencyMs: 20_000, device: "Kitchen", timestamp: now))
        try EventLog(db: db).log(EventRecord(exchangeId: "s", type: .reject, intentId: water.id, device: "Kitchen", timestamp: now))
        try CalibrationStore(db: db).record(CalibrationObservationRecord(intentId: banana.id, score: 0.9, accepted: true, timestamp: now))

        let before = try counts()
        XCTAssertEqual(before, [2, 2, 1, 2, 1, 3, 1])

        // Export (staged folder, exactly what the zip contains).
        let staging = tempRoot.appendingPathComponent("export", isDirectory: true)
        var progress: [Double] = []
        try RosettaExporter(db: db).stage(into: staging) { progress.append($0) }
        XCTAssertEqual(progress.last, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.appendingPathComponent("rosetta.json").path))

        // Wipe.
        try RosettaExporter(db: db).wipeAll()
        XCTAssertEqual(try counts(), [0, 0, 0, 0, 0, 0, 0])
        XCTAssertFalse(clipExists("g1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: FileLocations.photoURL(id: "photo-banana").path))
        // The staged (hard-linked) files survive the wipe.
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.appendingPathComponent("clips/g1.m4a").path))

        // Import.
        let summary = try RosettaImporter.importSync(from: staging, into: db)
        XCTAssertEqual(summary.intents, 2)
        XCTAssertEqual(summary.sessions, 1)
        XCTAssertEqual(summary.segments, 3)
        XCTAssertEqual(summary.exemplars, 2)
        XCTAssertEqual(summary.negatives, 1)
        XCTAssertEqual(summary.events, 2)
        XCTAssertEqual(summary.calibrationObservations, 1)
        XCTAssertEqual(summary.skippedRows, 0)
        XCTAssertEqual(summary.clipsCopied, 3)
        XCTAssertEqual(summary.photosCopied, 1)

        XCTAssertEqual(try counts(), before)
        XCTAssertTrue(clipExists("g1") && clipExists("g2") && clipExists("g3"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: FileLocations.photoURL(id: "photo-banana").path))
        XCTAssertEqual(try Data(contentsOf: FileLocations.clipURL(id: "g1")), Data(repeating: 7, count: 64))

        let restored = try db.dbQueue.read { try ExemplarRecord.order(Column("clipRef")).fetchAll($0) }
        XCTAssertEqual(restored.map(\.clipRef), ["g1", "g2"])
        XCTAssertEqual(restored[0].embedding, Data([5, 6, 7]))
        XCTAssertEqual(restored[0].sessionId, "s")
        assertSameInstant(restored[0].capturedAt, g1.startedAt)
        XCTAssertEqual(try IntentStore(db: db).fetch(id: banana.id)?.boardSlot, 0, "board positions survive a restore (§2.3)")
        XCTAssertEqual(try segment("g1")?.segmentState, .labelled)
        XCTAssertEqual(try segment("g3")?.segmentState, .pending)

        // Importing again is a no-op: existing rows and files win.
        let again = try RosettaImporter.importSync(from: staging, into: db)
        XCTAssertEqual(again.rowsInserted, 0)
        XCTAssertEqual(again.clipsCopied, 0)
        XCTAssertEqual(try counts(), before)
    }

    func testImportMovesCollidingBoardSlotsToFreeOnesWithoutTouchingLocalButtons() throws {
        // This phone: water on slot 0, outside on slot 2 (slot 1 is a gap).
        let water = IntentRecord(label: "water", boardSlot: 0)
        let outside = IntentRecord(label: "outside", boardSlot: 2)
        try IntentStore(db: db).insert(water)
        try IntentStore(db: db).insert(outside)

        // The other phone's export: banana on slot 0 (collides with water),
        // juice on slot 1 (free here, but banana will take it first), water
        // itself (same id, slot 3 there), and an archived word.
        var exportedWater = water
        exportedWater.boardSlot = 3
        let banana = IntentRecord(label: "banana", boardSlot: 0)
        let juice = IntentRecord(label: "juice", boardSlot: 1)
        let old = IntentRecord(label: "old", boardSlot: 5, archivedAt: now)
        let manifest = RosettaExporter.ExportManifest(
            exportedAt: now, intents: [banana, juice, exportedWater, old],
            exemplars: [], negatives: [], events: [], sessions: [], segments: [])

        let summary = try RosettaImporter.mergeRows(manifest, into: db)
        XCTAssertEqual(summary.intents, 3)
        XCTAssertEqual(summary.skippedRows, 0)

        let slots = Dictionary(uniqueKeysWithValues: try IntentStore(db: db).all(includeArchived: true).map { ($0.id, $0.boardSlot) })
        XCTAssertEqual(slots[water.id], 0, "a local button never moves (§2.3), even if the export had it elsewhere")
        XCTAssertEqual(slots[outside.id], 2)
        XCTAssertEqual(slots[banana.id], 1, "collided with water: lowest free slot")
        XCTAssertEqual(slots[juice.id], 3, "its slot went to banana a moment earlier: next free slot")
        XCTAssertEqual(slots[old.id], .some(nil), "archived words hold no slot")

        // Every placed button renders in its own cell; nothing was dropped.
        let cells = BoardLayout.cells(for: try IntentStore(db: db).all())
        XCTAssertEqual(cells.compactMap { $0?.label }, ["water", "banana", "outside", "juice"])
    }

    func testImportAcceptsManifestFileAndWrapperFolder() throws {
        let banana = IntentRecord(label: "banana")
        try IntentStore(db: db).insert(banana)
        let wrapper = tempRoot.appendingPathComponent("Rosetta-export-2026-11-01", isDirectory: true)
        let staging = wrapper.appendingPathComponent("RosettaExport-abc", isDirectory: true)
        try RosettaExporter(db: db).stage(into: staging)
        try RosettaExporter(db: db).wipeAll()

        XCTAssertEqual(try RosettaImporter.importSync(from: wrapper, into: db).intents, 1)
        try RosettaExporter(db: db).wipeAll()
        XCTAssertEqual(try RosettaImporter.importSync(
            from: staging.appendingPathComponent("rosetta.json"), into: db).intents, 1)
    }

    func testImportOfPreV3ExportBackfillsSessionAndCaptureTimeFromItsSegments() throws {
        let banana = IntentRecord(label: "banana")
        let captured = now.addingTimeInterval(-13 * 3600)
        let confirmed = now
        let session = SessionRecord(id: "s", startedAt: captured, endedAt: captured.addingTimeInterval(20), device: "Kitchen")
        let segment = SegmentRecord(id: "g", sessionId: "s", clipRef: "clip-g", startedAt: captured,
                                    durationMs: 700, state: .labelled, labelledAt: confirmed)
        // What a format-1 manifest decodes to: no sessionId, capturedAt == timestamp.
        let json = """
        {"id":"e","intentId":"\(banana.id)","clipRef":"clip-g","device":"Kitchen","contextJSON":"{}",
         "labeller":"Mom","timestamp":"\(ISO8601DateFormatter().string(from: confirmed))","decayExempt":false}
        """
        let old = try RosettaExporter.makeJSONDecoder().decode(ExemplarRecord.self, from: Data(json.utf8))
        let orphan = ExemplarRecord(id: "orphan", intentId: banana.id, clipRef: "clip-gone",
                                    device: "Kitchen", labeller: "Mom", timestamp: confirmed)
        var manifest = RosettaExporter.ExportManifest(
            exportedAt: now, intents: [banana], exemplars: [old, orphan], negatives: [], events: [],
            sessions: [session], segments: [segment])
        manifest.formatVersion = 1

        let summary = try RosettaImporter.mergeRows(manifest, into: db)
        XCTAssertEqual(summary.exemplars, 2)

        let restored = try XCTUnwrap(db.dbQueue.read { try ExemplarRecord.fetchOne($0, key: "e") })
        XCTAssertEqual(restored.sessionId, "s", "maturity can hold out the whole exchange")
        assertSameInstant(restored.capturedAt, captured, "hour-of-day prior sees when he said it, not the evening label")
        assertSameInstant(restored.timestamp, confirmed)

        let restoredOrphan = try XCTUnwrap(db.dbQueue.read { try ExemplarRecord.fetchOne($0, key: "orphan") })
        XCTAssertNil(restoredOrphan.sessionId, "no segment in the export: left as it was")
        assertSameInstant(restoredOrphan.capturedAt, confirmed)
    }

    func testZipImportIsRefusedWithPlainLanguage() throws {
        let zip = tempRoot.appendingPathComponent("Rosetta-export-2026-11-01.zip")
        try Data([0x50, 0x4B]).write(to: zip)
        XCTAssertThrowsError(try RosettaImporter.importSync(from: zip, into: db)) { error in
            XCTAssertEqual(error as? RosettaImporter.ImportError, .zipNotSupportedUnzipInFiles)
            XCTAssertTrue((error.localizedDescription).contains("Files"))
        }
        let empty = tempRoot.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertThrowsError(try RosettaImporter.importSync(from: empty, into: db)) { error in
            XCTAssertEqual(error as? RosettaImporter.ImportError, .manifestMissing)
        }
    }

    private func counts() throws -> [Int] {
        try db.dbQueue.read { db in
            [
                try IntentRecord.fetchCount(db),
                try ExemplarRecord.fetchCount(db),
                try NegativeRecord.fetchCount(db),
                try EventRecord.fetchCount(db),
                try SessionRecord.fetchCount(db),
                try SegmentRecord.fetchCount(db),
                try CalibrationObservationRecord.fetchCount(db),
            ]
        }
    }

    // MARK: - v3 migration

    func testMigrationV3BackfillsCapturedAtAndSessionIdFromSegments() throws {
        let queue = DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v2-ranking")

        let captured = now.addingTimeInterval(-13 * 3600) // 07:00-ish
        let confirmed = now                               // the evening batch
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO intents (id, label, createdAt) VALUES (?, ?, ?)",
                arguments: ["i", "banana", captured])
            try db.execute(
                sql: "INSERT INTO sessions (id, startedAt, device) VALUES (?, ?, ?)",
                arguments: ["s", captured, "Kitchen"])
            try db.execute(
                sql: """
                INSERT INTO segments (id, sessionId, clipRef, startedAt, durationMs, state, labelledAt)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: ["g", "s", "clip-g", captured, 700, "labelled", confirmed])
            try db.execute(
                sql: """
                INSERT INTO exemplars (id, intentId, clipRef, device, contextJSON, labeller, timestamp, decayExempt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: ["e-with-segment", "i", "clip-g", "Kitchen", "{}", "Mom", confirmed, false])
            try db.execute(
                sql: """
                INSERT INTO exemplars (id, intentId, clipRef, device, contextJSON, labeller, timestamp, decayExempt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: ["e-orphan", "i", "clip-gone", "Kitchen", "{}", "Mom", confirmed, false])
        }

        let migrated = try AppDatabase(queue: queue)
        let exemplars = try migrated.dbQueue.read { db in
            try ExemplarRecord.fetchAll(db)
        }
        let withSegment = try XCTUnwrap(exemplars.first { $0.id == "e-with-segment" })
        assertSameInstant(withSegment.capturedAt, captured, "capturedAt comes from segments.startedAt")
        XCTAssertEqual(withSegment.sessionId, "s")
        assertSameInstant(withSegment.timestamp, confirmed)

        let orphan = try XCTUnwrap(exemplars.first { $0.id == "e-orphan" })
        assertSameInstant(orphan.capturedAt, confirmed, "no segment: falls back to the confirmation time")
        XCTAssertNil(orphan.sessionId)

        // The indexes exist.
        let indexes = try migrated.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'")
        }
        for name in ["segments_session", "segments_clip", "exemplars_clip", "negatives_intent"] {
            XCTAssertTrue(indexes.contains(name), "missing index \(name)")
        }
    }

    func testOldExportWithoutV3FieldsStillDecodes() throws {
        let json = """
        {"id":"e","intentId":"i","clipRef":"c","device":"Kitchen","contextJSON":"{}",
         "labeller":"Mom","timestamp":"2026-03-10T20:00:00Z","decayExempt":false}
        """
        let record = try RosettaExporter.makeJSONDecoder().decode(ExemplarRecord.self, from: Data(json.utf8))
        XCTAssertNil(record.sessionId)
        XCTAssertEqual(record.capturedAt, record.timestamp)
    }

    // MARK: - B5 / B6: launch sweeps and storage meter

    func testRunAtLaunchSweepsExpiryOpenSessionsTempFilesOrphansAndRetention() throws {
        let fm = FileManager.default
        let banana = IntentRecord(label: "banana")
        try IntentStore(db: db).insert(banana)

        // Stale pending segment in a session that was never closed.
        let yesterday = now.addingTimeInterval(-30 * 3600)
        try addSession(id: "open", startedAt: yesterday)
        try addSegment(id: "stale", sessionId: "open", startedAt: yesterday)

        // Discarded 8 days ago (past retention), not-him 2 days ago (kept),
        // expired 20 days ago (kept forever per §4.4).
        let eightDaysAgo = now.addingTimeInterval(-8 * 24 * 3600)
        try addSession(id: "old", startedAt: eightDaysAgo, endedAt: eightDaysAgo.addingTimeInterval(10))
        try addSegment(id: "junk", sessionId: "old", startedAt: eightDaysAgo, state: .discarded, labelledAt: eightDaysAgo)
        try addSegment(id: "sister", sessionId: "old", startedAt: eightDaysAgo, state: .notHim,
                       labelledAt: now.addingTimeInterval(-2 * 24 * 3600))
        try addSegment(id: "expired", sessionId: "old", startedAt: now.addingTimeInterval(-20 * 24 * 3600), state: .expired)

        // A labelled clip and its exemplar: never touched.
        let g = try addSegment(id: "banana1", sessionId: "old", startedAt: eightDaysAgo)
        _ = try ExemplarStore(db: db).confirm(segments: [g], intentId: banana.id, device: "Kitchen", labeller: "Mom", now: eightDaysAgo)

        // Row-less files: an old orphan (swept), a fresh one (grace), a .tmp.
        try writeClip("orphan-old")
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-3600)],
                             ofItemAtPath: FileLocations.clipURL(id: "orphan-old").path)
        try writeClip("orphan-fresh")
        try fm.setAttributes([.modificationDate: now],
                             ofItemAtPath: FileLocations.clipURL(id: "orphan-fresh").path)
        try Data([1]).write(to: FileLocations.clips.appendingPathComponent("partial.m4a.tmp"))

        let report = try Maintenance.runAtLaunch(db: db, now: now)

        XCTAssertEqual(report.expiredSegments, 1)
        XCTAssertEqual(try segment("stale")?.segmentState, .expired)

        XCTAssertEqual(report.closedSessions, 1)
        let open = try XCTUnwrap(db.dbQueue.read { try SessionRecord.fetchOne($0, key: "open") })
        let endedAt = try XCTUnwrap(open.endedAt)
        assertSameInstant(endedAt, yesterday.addingTimeInterval(90))

        XCTAssertEqual(report.temporaryFilesRemoved, 1)
        XCTAssertFalse(fm.fileExists(atPath: FileLocations.clips.appendingPathComponent("partial.m4a.tmp").path))

        XCTAssertEqual(report.retentionClipsRemoved, 1)
        XCTAssertFalse(clipExists("junk"))
        XCTAssertEqual(try segment("junk")?.clipRef, FileLocations.deletedClipRef)
        XCTAssertEqual(try segment("junk")?.segmentState, .discarded, "the row stays as a tombstone")
        XCTAssertTrue(clipExists("sister"), "inside the 7-day retention window")
        XCTAssertTrue(clipExists("expired"), "expired segments are kept on disk (§4.4)")
        XCTAssertTrue(clipExists("banana1"))
        XCTAssertTrue(clipExists("stale"))

        XCTAssertEqual(report.orphanClipsRemoved, 1)
        XCTAssertFalse(clipExists("orphan-old"))
        XCTAssertTrue(clipExists("orphan-fresh"), "a file newer than the grace period may be mid-insert")

        let storage = try Maintenance.storageSummary()
        XCTAssertEqual(storage.clipCount, 5) // stale, sister, expired, banana1, orphan-fresh
        XCTAssertEqual(storage.bytes, 5 * 64)
        XCTAssertEqual(storage.photoBytes, 0)
    }

    func testCloseOpenSessionsLeavesALiveSessionAlone() throws {
        try addSession(id: "live", startedAt: now.addingTimeInterval(-30))
        XCTAssertEqual(try Maintenance.closeOpenSessions(db: db, now: now), 0)
        XCTAssertNil(try db.dbQueue.read { try SessionRecord.fetchOne($0, key: "live") }?.endedAt)
    }
}
