import XCTest
@testable import Rosetta

/// Fixture embedder for the engine tests. Segments in these tests carry
/// their embeddings, so the encoder is only reached through the capture
/// path (`embedSamples`); `calls` proves nothing re-encodes behind the
/// cache's back.
final class FakeEmbedder: EmbeddingProvider, @unchecked Sendable {
    let dimension = EmbeddingFixtures.dim
    var vector: [Float] = EmbeddingFixtures.axis(0)

    private let lock = NSLock()
    private var callCount = 0

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }

    func embed(samples: [Float]) async throws -> [Float] {
        lock.lock()
        callCount += 1
        lock.unlock()
        return vector
    }
}

/// Engine-level tests against an in-memory database with fixture
/// embeddings on the segment rows. Everything the Confirm card and Listen
/// strip rely on — exclusion by negatives, per-intent top-3, capture-time
/// priors, outcome recording, the embedding cache — is only visible here.
final class SuggestionEngineTests: XCTestCase {
    private var db: AppDatabase!
    private var embedder: FakeEmbedder!
    private var engine: SuggestionEngine!
    private var banana: IntentRecord!
    private var water: IntentRecord!
    private var outside: IntentRecord!
    private var help: IntentRecord!
    private let station = "Kitchen"
    private let exchange = "exchange-x"

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
        banana = IntentRecord(label: "banana")
        water = IntentRecord(label: "water")
        outside = IntentRecord(label: "outside")
        help = IntentRecord(label: "help")
        let intents = IntentStore(db: db)
        for intent in [banana!, water!, outside!, help!] {
            try intents.insert(intent)
        }
        embedder = FakeEmbedder()
        engine = SuggestionEngine(db: db, embedder: embedder)
        MissingClipRegistry.shared.removeAll()
    }

    // MARK: - Fixtures

    private func localDate(day: Int = 2, hour: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 11
        components.day = day
        components.hour = hour
        components.minute = 0
        components.second = 0
        return Calendar.current.date(from: components)!
    }

    /// The day after the seed data, mid-morning: recency boosts are gone.
    private var queryNow: Date { localDate(day: 3, hour: 9) }

    /// Six ways of saying one word: mostly along `axis`, each leaning a
    /// different way by 0.6, so clips of the same word match each other at
    /// cosine 1/(1+0.36) ≈ 0.735 across exchanges (a realistic spread; a
    /// tighter cluster would make every mixed query fail the word's
    /// self-similarity floor, which is the guard working as intended).
    private func cluster(axis: Int, count: Int = 6) -> [[Float]] {
        (0..<count).map { i in
            EmbeddingFixtures.near(axis, leaning: (axis + i + 1) % EmbeddingFixtures.dim, by: 0.6)
        }
    }

    /// Cross-session self-similarity of a `cluster` word minus the
    /// tolerance: what the engine requires of an utterance before it will
    /// name that word.
    private var clusterFloor: Double {
        1.0 / 1.36 - MaturityGate.Config().selfSimilarityTolerance
    }

    /// "help" sits on axis 3 with a faint lean toward axis 0: a small but
    /// positive similarity to the query, so it is the floor that removes
    /// it, not the zero-similarity drop.
    private var helpVectors: [[Float]] {
        Array(repeating: EmbeddingFixtures.near(3, leaning: 0, by: 0.05), count: 6)
    }

    /// Leans on banana, water and outside in that order (best raw cosine
    /// ≈ 0.857, 0.765, 0.737 against their clusters, all above the 0.715
    /// floor); orthogonal to help except for help's own faint lean.
    private var mixedQuery: [Float] { EmbeddingFixtures.mix([1, 0.95, 0.75]) }

    /// Inserts one exchange session with a segment per vector (embedding
    /// stored on the row) and confirms them all as `intent` at `confirmedAt`.
    @discardableResult
    private func confirmSession(id: String,
                                intent: IntentRecord,
                                vectors: [[Float]],
                                capturedAt: Date,
                                confirmedAt: Date) throws -> [SegmentRecord] {
        let sessions = SessionStore(db: db)
        try sessions.insert(SessionRecord(id: id, startedAt: capturedAt, device: station))
        var segments: [SegmentRecord] = []
        for (i, vector) in vectors.enumerated() {
            let segment = SegmentRecord(
                id: "\(id)-seg\(i)",
                sessionId: id,
                clipRef: "\(id)-clip\(i)",
                startedAt: capturedAt.addingTimeInterval(Double(i) * 3),
                durationMs: 700,
                embedding: EmbeddingCodec.encode(vector)
            )
            try sessions.insertSegment(segment)
            segments.append(segment)
        }
        _ = try ExemplarStore(db: db).confirm(
            segments: segments, intentId: intent.id, device: station, labeller: "Mom", now: confirmedAt
        )
        return segments
    }

    /// Three exchanges of two chips each (§5.6 needs three sessions).
    private func seed(intent: IntentRecord, vectors: [[Float]], capturedHour: Int, confirmedHour: Int = 20) throws {
        for s in 0..<3 {
            let slice = Array(vectors[(s * 2)..<(s * 2 + 2)])
            try confirmSession(
                id: "\(intent.label)-s\(s)",
                intent: intent,
                vectors: slice,
                capturedAt: localDate(hour: capturedHour).addingTimeInterval(Double(s) * 60),
                confirmedAt: localDate(hour: confirmedHour)
            )
        }
    }

    private func seedMatureDictionary() throws {
        try seed(intent: banana, vectors: cluster(axis: 0), capturedHour: 9)
        try seed(intent: water, vectors: cluster(axis: 1), capturedHour: 9)
        try seed(intent: outside, vectors: cluster(axis: 2), capturedHour: 9)
        try seed(intent: help, vectors: helpVectors, capturedHour: 9)
    }

    /// A pending segment of a live exchange, embedding on the record (as
    /// the capture path leaves it). Not inserted: the engine ranks what it
    /// is handed.
    private func querySegment(id: String = "q1", exchange: String? = nil, vector: [Float]? = nil) -> SegmentRecord {
        SegmentRecord(
            id: id,
            sessionId: exchange ?? self.exchange,
            clipRef: "\(id)-clip",
            startedAt: queryNow.addingTimeInterval(-5),
            durationMs: 700,
            embedding: EmbeddingCodec.encode(vector ?? mixedQuery)
        )
    }

    // MARK: - Tests

    func testMatureWordsAreSuggestedInOrderAndTheFloorFilters() async throws {
        try seedMatureDictionary()
        await engine.reload()

        let suggestible = await engine.suggestibleIntentIds
        XCTAssertEqual(suggestible, Set([banana.id, water.id, outside.id, help.id]),
                       "six clips over three exchanges each: every word is mature")
        let available = await engine.isModelAvailable
        XCTAssertTrue(available)

        let guesses = await engine.suggestions(for: [querySegment()], station: station, now: queryNow)
        XCTAssertEqual(guesses.map(\.intent.id), [banana.id, water.id, outside.id],
                       "top-3 is three when three mature words fit; help is mature but the utterance does not resemble it")
        for guess in guesses {
            XCTAssertGreaterThanOrEqual(guess.probability, 0.15)
            XCTAssertGreaterThanOrEqual(guess.bestSimilarity, clusterFloor,
                                        "every shown word cleared its own self-similarity floor")
            XCTAssertEqual(guess.prior, 1.0, accuracy: 0.01, "uniform history → neutral prior")
            XCTAssertGreaterThan(guess.z, -0.5)
        }
        XCTAssertGreaterThan(guesses[0].z, guesses[1].z)
        XCTAssertGreaterThan(guesses[1].z, guesses[2].z)
        XCTAssertEqual(embedder.calls, 0, "segments carried embeddings; nothing was encoded")
    }

    /// The first-moment failure: the family has taught exactly one word
    /// ("football"), he says something unrelated ("Chase"), and the app
    /// must say nothing — not "Maybe: football?". Relative ranking alone
    /// cannot do this (with one word in the store the leader is always
    /// that word); the self-similarity floor can.
    func testOneMatureWordIsNotSuggestedForAnUnrelatedUtterance() async throws {
        try seed(intent: banana, vectors: cluster(axis: 0), capturedHour: 9)
        await engine.reload()
        let suggestible = await engine.suggestibleIntentIds
        XCTAssertEqual(suggestible, [banana.id])

        // Nothing like banana: on axis 5, with a faint lean elsewhere. Its
        // best raw match to banana is ≈ 0.50 (one banana clip leans toward
        // axis 5), well under banana's floor of ≈ 0.715.
        let unrelated = EmbeddingFixtures.near(5, leaning: 6, by: 0.2)
        let guesses = await engine.suggestions(
            for: [querySegment(id: "chase", vector: unrelated)], station: station, now: queryNow
        )
        XCTAssertTrue(guesses.isEmpty, "a one-word dictionary must be able to answer \"nothing\"")

        // Proof that this is the floor's doing and not an accident of the
        // fixture: without it, the same utterance is confidently banana.
        await MainActor.run { engine.usesSimilarityFloor = false }
        let unguarded = await engine.suggestions(
            for: [querySegment(id: "chase2", vector: unrelated)], station: station, now: queryNow
        )
        XCTAssertEqual(unguarded.map(\.intent.id), [banana.id],
                       "relative ranking always has a leader — this is the bug the floor fixes")
        XCTAssertGreaterThanOrEqual(unguarded[0].probability, 0.5, "and it would even have shown two dots")
        await MainActor.run { engine.usesSimilarityFloor = true }

        // A genuine banana still gets through.
        let bananaLike = EmbeddingFixtures.near(0, leaning: 7, by: 0.1)
        let real = await engine.suggestions(
            for: [querySegment(id: "b", vector: bananaLike)], station: station, now: queryNow
        )
        XCTAssertEqual(real.map(\.intent.id), [banana.id])
        XCTAssertGreaterThanOrEqual(real[0].bestSimilarity, clusterFloor)

        // The word's report carries the floor Progress can explain.
        let reports = await engine.maturityReports
        let bananaReport = try XCTUnwrap(reports.first { $0.intentId == banana.id })
        XCTAssertEqual(bananaReport.selfSimilarityFloor ?? .nan, clusterFloor, accuracy: 1e-4)
        XCTAssertEqual(bananaReport.typicalSelfSimilarity ?? .nan, 1.0 / 1.36, accuracy: 1e-4)
    }

    func testRejectionsInTheNegativesTableAreHonouredWhicheverSurfaceAsks() async throws {
        try seedMatureDictionary()
        await engine.reload()

        // The Confirm card wrote the hard negative for this exchange; the
        // engine must exclude it even when the caller passes nothing.
        try ExemplarStore(db: db).recordNegative(NegativeRecord(
            rejectedIntentId: banana.id, clipRef: nil, exchangeId: exchange, timestamp: queryNow
        ))

        let first = await engine.suggestions(for: [querySegment(id: "q1")], station: station, now: queryNow)
        XCTAssertEqual(first.map(\.intent.id), [water.id, outside.id])

        // He says another thing; the card is rebuilt with new segments of
        // the same exchange. Banana must stay gone (§2.4).
        let second = await engine.suggestions(
            for: [querySegment(id: "q1"), querySegment(id: "q2")], station: station, now: queryNow
        )
        XCTAssertFalse(second.contains { $0.intent.id == banana.id })
        XCTAssertEqual(second.first?.intent.id, water.id)

        // A dismissal noted through the engine (no re-read) takes effect too.
        await engine.noteDismissal(intentId: water.id, exchangeId: exchange)
        let third = await engine.suggestions(for: [querySegment(id: "q3")], station: station, now: queryNow)
        XCTAssertEqual(third.map(\.intent.id), [outside.id])

        // Another exchange is unaffected.
        let other = await engine.suggestions(
            for: [querySegment(id: "q9", exchange: "exchange-y")], station: station, now: queryNow
        )
        XCTAssertEqual(other.first?.intent.id, banana.id)
    }

    func testDismissingTheTopGuessYieldsTheNextOne() async throws {
        try seedMatureDictionary()
        await engine.reload()

        let afterOneNo = await engine.suggestions(
            for: [querySegment()], station: station, excluding: [banana.id], now: queryNow
        )
        XCTAssertEqual(afterOneNo.map(\.intent.id), [water.id, outside.id])

        let afterTwoNos = await engine.suggestions(
            for: [querySegment()], station: station, excluding: [banana.id, water.id], now: queryNow
        )
        XCTAssertEqual(afterTwoNos.map(\.intent.id), [outside.id])
        XCTAssertGreaterThan(afterTwoNos[0].z, 0,
                             "standardized against what remains, the next word is now the clear best")
    }

    func testEachSegmentVotesSeparately() async throws {
        try seedMatureDictionary()
        await engine.reload()

        let twoBananaChips = [
            querySegment(id: "a", vector: EmbeddingFixtures.near(0, leaning: 5, by: 0.1)),
            querySegment(id: "b", vector: EmbeddingFixtures.near(0, leaning: 6, by: 0.1)),
        ]
        let guesses = await engine.suggestions(for: twoBananaChips, station: station, now: queryNow)
        XCTAssertEqual(guesses.first?.intent.id, banana.id)
        XCTAssertEqual(guesses.first?.votes, 2, "banana topped both chips")
    }

    func testRecordOutcomesWritesOneObservationPerShownGuess() async throws {
        try seedMatureDictionary()
        await engine.reload()

        let guesses = await engine.suggestions(for: [querySegment()], station: station, now: queryNow)
        XCTAssertEqual(guesses.count, 3)

        // The parent confirmed water from the grid: the shown banana and
        // outside were implicitly wrong, water implicitly right.
        await engine.recordOutcomes(topGuesses: guesses, confirmed: water.id, exchangeId: exchange, now: queryNow)

        let rows = try await db.dbQueue.read { try CalibrationObservationRecord.fetchAll($0) }
        XCTAssertEqual(rows.count, 3)
        for guess in guesses {
            let row = rows.first { $0.intentId == guess.intent.id }
            XCTAssertNotNil(row)
            XCTAssertEqual(row?.accepted, guess.intent.id == water.id)
            XCTAssertEqual(row?.score ?? .nan, guess.rawScore, accuracy: 1e-9,
                           "the stored feature is the z the guess was shown with")
            XCTAssertTrue(CalibrationFeature.isCurrent(row!))
        }
    }

    func testRecordOutcomeRejectionJoinsTheExchangeExclusionSet() async throws {
        try seedMatureDictionary()
        await engine.reload()

        let guesses = await engine.suggestions(for: [querySegment()], station: station, now: queryNow)
        let top = try XCTUnwrap(guesses.first)
        await engine.recordOutcome(
            intentId: top.intent.id, rawScore: top.rawScore, accepted: false, exchangeId: exchange, now: queryNow
        )
        let next = await engine.suggestions(for: [querySegment(id: "q2")], station: station, now: queryNow)
        XCTAssertFalse(next.contains { $0.intent.id == top.intent.id })
        let rejected = await engine.rejectedIntentIds(exchangeId: exchange)
        XCTAssertTrue(rejected.contains(top.intent.id))
    }

    func testPriorsUseCaptureHourNotConfirmHour() async throws {
        // Banana is a 7 am word, water a 7 pm word; both were labelled in
        // the evening Review batch at 8 pm.
        try seed(intent: banana, vectors: cluster(axis: 0), capturedHour: 7, confirmedHour: 20)
        try seed(intent: water, vectors: cluster(axis: 1), capturedHour: 19, confirmedHour: 20)
        await engine.reload()

        let bananaQuery = EmbeddingFixtures.near(0, leaning: 5, by: 0.1)
        let morning = await engine.suggestions(
            for: [querySegment(id: "m", vector: bananaQuery)], station: station, now: localDate(day: 3, hour: 7)
        )
        let evening = await engine.suggestions(
            for: [querySegment(id: "e", vector: bananaQuery)], station: station, now: localDate(day: 3, hour: 20)
        )
        let morningBanana = try XCTUnwrap(morning.first { $0.intent.id == banana.id })
        let eveningBanana = try XCTUnwrap(evening.first { $0.intent.id == banana.id })

        XCTAssertGreaterThan(morningBanana.prior, 1.05, "banana at 7 am is in its routine")
        XCTAssertLessThan(eveningBanana.prior, 0.95, "banana at 8 pm is not — even though that is when it was labelled")
        XCTAssertEqual(morningBanana.probability, eveningBanana.probability, accuracy: 1e-9,
                       "the prior ranks; it never touches the calibrated acoustic probability")
        XCTAssertGreaterThan(morningBanana.rankingScore, eveningBanana.rankingScore)
    }

    func testEmbeddingCacheServesStaleSnapshotsWithoutReencoding() async throws {
        let sessions = SessionStore(db: db)
        try sessions.insert(SessionRecord(id: "live", startedAt: queryNow, device: station))
        let fresh = SegmentRecord(id: "seg-live", sessionId: "live", clipRef: "seg-live", startedAt: queryNow, durationMs: 600)
        try sessions.insertSegment(fresh)

        // Capture path: embeds the samples, persists, registers in the cache.
        embedder.vector = EmbeddingFixtures.near(0, leaning: 4, by: 0.1)
        let blob = await engine.embedSamples([0.1, 0.2, 0.3], segmentId: fresh.id)
        XCTAssertNotNil(blob)
        XCTAssertEqual(embedder.calls, 1)
        let storedRow = try await db.dbQueue.read { try SegmentRecord.fetchOne($0, key: fresh.id) }
        XCTAssertEqual(storedRow?.embedding, blob)

        // The Confirm card's snapshot still says nil: served from the cache,
        // not re-encoded.
        let snapshot = fresh // embedding == nil
        let cached = await engine.embedding(for: snapshot)
        XCTAssertEqual(cached, blob)
        XCTAssertEqual(embedder.calls, 1)
        let cachedCount = await engine.cachedEmbeddingCount
        XCTAssertEqual(cachedCount, 1)

        // A segment with no blob anywhere and no clip file on disk: nil,
        // remembered as missing, encoder untouched.
        let orphan = SegmentRecord(id: "orphan", sessionId: "live", clipRef: "no-such-clip", startedAt: queryNow, durationMs: 600)
        let none = await engine.embedding(for: orphan)
        XCTAssertNil(none)
        XCTAssertEqual(embedder.calls, 1)
        XCTAssertTrue(MissingClipRegistry.shared.contains("no-such-clip"))
    }

    func testBackfillCopiesSegmentEmbeddingsOntoExemplarsWithoutEncoding() async throws {
        let sessions = SessionStore(db: db)
        try sessions.insert(SessionRecord(id: "old", startedAt: localDate(hour: 9), device: station))
        let vector = EmbeddingFixtures.near(0, leaning: 3, by: 0.1)
        let segment = SegmentRecord(
            id: "old-seg", sessionId: "old", clipRef: "old-clip", startedAt: localDate(hour: 9),
            durationMs: 600, state: .labelled, embedding: EmbeddingCodec.encode(vector)
        )
        try sessions.insertSegment(segment)
        // An exemplar that lost its embedding (confirm used to write nil).
        let exemplar = ExemplarRecord(
            intentId: banana.id, clipRef: "old-clip", embedding: nil, device: station,
            labeller: "Mom", timestamp: localDate(hour: 20), sessionId: "old", capturedAt: localDate(hour: 9)
        )
        try await db.dbQueue.write { try exemplar.insert($0) }

        await EmbeddingBackfill(db: db, embedder: embedder).copyEmbeddingsFromSegments()

        let copiedRow = try await db.dbQueue.read { try ExemplarRecord.fetchOne($0, key: exemplar.id) }
        XCTAssertEqual(copiedRow?.embedding, EmbeddingCodec.encode(vector))
        XCTAssertEqual(embedder.calls, 0, "a one-statement copy, no encoder time")

        await engine.reload()
        let indexed = await engine.indexedExemplarCount
        XCTAssertEqual(indexed, 1)
    }
}
