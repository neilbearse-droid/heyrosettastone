import Foundation
import GRDB
import Observation

/// One tentative guess for the parent surface. Copy is always phrased as a
/// maybe (§2.6); the dots communicate confidence without pretending to
/// certainty.
struct Suggestion: Identifiable, Equatable {
    let intent: IntentRecord
    /// The calibration feature: the standardized acoustic score `z` from
    /// `IntentRanker` (prior NOT applied), echoed back on accept/reject so
    /// the intent's threshold learns. Named `rawScore` for compatibility
    /// with existing callers.
    let rawScore: Double
    /// Calibrated acoustic acceptance probability (prior NOT applied).
    let probability: Double
    /// Context prior multiplier (§5.3), applied for ranking only.
    let prior: Double
    /// `probability × prior` — the ranking key.
    let rankingScore: Double
    /// Number of the exchange's segments in whose top-3 this intent appeared.
    let votes: Int

    var id: String { intent.id }
    var z: Double { rawScore }
    var confidenceDots: Int { probability > 0.75 ? 3 : probability > 0.5 ? 2 : 1 }
}

/// Orchestrates §5: owns the in-memory exemplar index, per-intent
/// calibrators, context priors, and maturity reports; answers "top-3 for
/// these segments" for the Confirm card and live parent view. Absent a
/// bundled encoder model, everything returns empty and the app behaves as
/// Phase 1 (§2.1: the model earns its way in).
///
/// Also owns two caches the views used to re-derive on every render:
/// - embeddings in flight or completed, keyed by segment id, so a segment
///   is encoded at most once no matter how many surfaces ask;
/// - the intents rejected in each exchange (read from the negatives table),
///   so "his rejection is final" (§2.4) holds for Listen and Confirm alike,
///   regardless of view lifecycle.
@MainActor
@Observable
final class SuggestionEngine {
    private let db: AppDatabase
    @ObservationIgnored private var embedder: EmbeddingProvider?

    private(set) var isModelAvailable = false
    private(set) var maturityReports: [MaturityGate.Report] = []

    @ObservationIgnored private var index: [ExemplarVector] = []
    @ObservationIgnored private var calibrators: [String: LogisticCalibrator] = [:]
    @ObservationIgnored private var priors: ContextPriors?
    @ObservationIgnored private var suggestibleIntents: Set<String> = []
    @ObservationIgnored private var maturityCache = MaturityGate.Cache()
    @ObservationIgnored private var isEmbeddingMissingExemplars = false

    // Embedding cache: in-flight or completed tasks keyed by segment id.
    @ObservationIgnored private var embeddingTasks: [String: Task<Data?, Never>] = [:]
    @ObservationIgnored private var embeddingTaskOrder: [String] = []
    @ObservationIgnored private let embeddingCacheLimit = 256

    // Rejected intents per exchange id, from the negatives table.
    @ObservationIgnored private var rejectedByExchange: [String: Set<String>] = [:]
    @ObservationIgnored private var rejectedExchangeOrder: [String] = []
    @ObservationIgnored private let rejectedCacheLimit = 32

    /// Skip guesses whose calibrated acoustic probability is below this.
    /// On the uncalibrated default (slope 1, intercept −1.5) this filters
    /// intents whose best match sits more than ~0.23 std below the mean
    /// similarity of the store — a word none of whose exemplars resembles
    /// the query more than the average exemplar does.
    @ObservationIgnored var probabilityFloor = 0.15
    /// Tunables. `maturityConfig.ranker` is kept in step with `rankerConfig`.
    @ObservationIgnored var rankerConfig = IntentRanker.Config()
    @ObservationIgnored var maturityConfig = MaturityGate.Config()
    @ObservationIgnored var priorConfig = ContextPriors.Config()

    // nonisolated: only stores the reference, so it can be called from
    // AppEnvironment's nonisolated init; all state-touching work happens in
    // the MainActor-isolated methods.
    nonisolated init(db: AppDatabase) {
        self.db = db
    }

    /// Test seam: inject an embedder (a fake returning fixture vectors)
    /// instead of loading WhisperKit. `reload()` marks the model available.
    nonisolated init(db: AppDatabase, embedder: EmbeddingProvider?) {
        self.db = db
        self.embedder = embedder
    }

    // MARK: - Lifecycle

    /// Call once at launch. Order matters for a counter phone that may not
    /// be relaunched for weeks: load the encoder, build the index from what
    /// is already embedded (suggestions work immediately), hand control
    /// back via `onReady` so the app can wire capture's `embedSamples`,
    /// THEN backfill the rest and rebuild.
    ///
    /// - Parameters:
    ///   - runBackfill: false in tests that have no clip files.
    ///   - onReady: called on the main actor after the first `reload()`,
    ///     before the backfill starts.
    func start(runBackfill: Bool = true, onReady: (() -> Void)? = nil) async {
        if embedder == nil {
            embedder = await WhisperKitEmbedder.loadIfAvailable()
        }
        isModelAvailable = embedder != nil
        await reload()
        onReady?()

        guard runBackfill, let embedder else { return }
        let backfill = EmbeddingBackfill(db: db, embedder: embedder, embedSegment: { [weak self] segment in
            guard let self else { return nil }
            return await self.embedding(for: segment)
        })
        await backfill.run()
        await reload()
    }

    /// Rebuilds index, calibrators, priors, and maturity from the database.
    /// Call after anything that confirms, rejects, or prunes. Exemplars
    /// still missing a vector are embedded (through the cache) and the
    /// index rebuilt once more when that finishes.
    func reload() async {
        await reload(embedMissing: true)
    }

    private func reload(embedMissing: Bool) async {
        isModelAvailable = embedder != nil
        let db = self.db
        let cache = maturityCache
        // Copied into a `let` before the detached task: a captured `var`
        // is rejected inside a @Sendable closure.
        var pendingMaturityConfig = self.maturityConfig
        pendingMaturityConfig.ranker = rankerConfig
        let maturityConfig = pendingMaturityConfig
        let priorConfig = self.priorConfig
        let built = await Task.detached(priority: .utility) {
            Self.buildState(db: db, maturityCache: cache, maturityConfig: maturityConfig, priorConfig: priorConfig)
        }.value

        self.index = built.index
        self.calibrators = built.calibrators
        self.priors = built.priors
        self.maturityCache = built.maturityCache
        self.maturityReports = built.reports
        self.suggestibleIntents = Set(built.reports.filter(\.isSuggestible).map(\.intentId))

        if embedMissing, embedder != nil, !built.exemplarsMissingEmbedding.isEmpty {
            embedMissingExemplars(built.exemplarsMissingEmbedding)
        }
    }

    struct BuiltState {
        var index: [ExemplarVector] = []
        var calibrators: [String: LogisticCalibrator] = [:]
        var priors: ContextPriors?
        var reports: [MaturityGate.Report] = []
        var maturityCache = MaturityGate.Cache()
        var exemplarsMissingEmbedding: [(exemplarId: String, clipRef: String)] = []
    }

    nonisolated static func buildState(db: AppDatabase,
                                       maturityCache: MaturityGate.Cache,
                                       maturityConfig: MaturityGate.Config,
                                       priorConfig: ContextPriors.Config) -> BuiltState {
        var state = BuiltState()
        let exemplars = (try? db.dbQueue.read { try ExemplarRecord.fetchAll($0) }) ?? []
        let intents = (try? db.dbQueue.read {
            try IntentRecord.filter(Column("archivedAt") == nil).fetchAll($0)
        }) ?? []
        let allObservations = (try? db.dbQueue.read {
            try CalibrationObservationRecord.fetchAll($0)
        }) ?? []
        // Observations recorded under the previous feature definition are
        // not comparable; see CalibrationFeature.
        let observations = allObservations.filter(CalibrationFeature.isCurrent)

        // Decode, then drop vectors whose dimension differs from the modal
        // one (a checkpoint change leaves mixed rows behind; cosine would
        // silently score them 0 and they would still vote).
        var decoded: [(record: ExemplarRecord, vector: [Float])] = []
        for exemplar in exemplars {
            guard let blob = exemplar.embedding else { continue }
            let vector = EmbeddingCodec.decode(blob)
            if !vector.isEmpty { decoded.append((exemplar, vector)) }
        }
        var dimensionCounts: [Int: Int] = [:]
        for entry in decoded { dimensionCounts[entry.vector.count, default: 0] += 1 }
        let modalDimension = dimensionCounts.max { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key < rhs.key
        }?.key ?? 0

        state.index = decoded
            .filter { $0.vector.count == modalDimension }
            .map { entry in
                ExemplarVector(
                    exemplarId: entry.record.id,
                    intentId: entry.record.intentId,
                    vector: entry.vector,
                    timestamp: entry.record.timestamp,
                    decayExempt: entry.record.decayExempt,
                    sessionId: entry.record.sessionId
                )
            }

        for intentId in Set(observations.map(\.intentId)) {
            let history = observations
                .filter { $0.intentId == intentId }
                .map { (score: $0.score, accepted: $0.accepted) }
            state.calibrators[intentId] = LogisticCalibrator.fit(observations: history)
        }

        // Priors bucket on CAPTURE time, never on confirmation time: evening
        // Review labelling must not make every word an 8 pm word, and the
        // "just happened" recency boost is about when he said it.
        let priorObservations = exemplars.map { exemplar in
            ContextPriors.Observation(
                intentId: exemplar.intentId,
                hourOfDay: Calendar.current.component(.hour, from: exemplar.capturedAt),
                station: exemplar.device,
                timestamp: exemplar.capturedAt
            )
        }
        state.priors = ContextPriors(
            observations: priorObservations,
            intentIds: intents.map(\.id),
            config: priorConfig
        )

        var cache = maturityCache
        let reportsById = MaturityGate.reports(
            intentIds: intents.map(\.id),
            index: state.index,
            now: Date(),
            config: maturityConfig,
            cache: &cache
        )
        state.maturityCache = cache
        state.reports = intents.map { reportsById[$0.id] ?? .empty(intentId: $0.id) }

        state.exemplarsMissingEmbedding = exemplars
            .filter { $0.embedding == nil && !FileLocations.isDeleted(clipRef: $0.clipRef) }
            .map { (exemplarId: $0.id, clipRef: $0.clipRef) }
        return state
    }

    /// Embeds exemplars whose row has no vector (e.g. confirmed before the
    /// encoder finished loading), then rebuilds once. One pass at a time.
    private func embedMissingExemplars(_ missing: [(exemplarId: String, clipRef: String)]) {
        guard !isEmbeddingMissingExemplars else { return }
        isEmbeddingMissingExemplars = true
        Task { [weak self] in
            guard let self else { return }
            var embedded = 0
            for item in missing {
                guard let blob = await self.embedding(forClipRef: item.clipRef) else { continue }
                let exemplarId = item.exemplarId
                let db = self.db
                try? await db.dbQueue.write { db in
                    try db.execute(
                        sql: "UPDATE exemplars SET embedding = ? WHERE id = ? AND embedding IS NULL",
                        arguments: [blob, exemplarId]
                    )
                }
                embedded += 1
            }
            self.isEmbeddingMissingExemplars = false
            if embedded > 0 {
                await self.reload(embedMissing: false)
            }
        }
    }

    // MARK: - Embedding cache

    /// The segment's embedding: the stored blob if the record carries one,
    /// else the in-flight task for this segment id if any, else a new task
    /// that re-checks the database (the capture path may have persisted a
    /// blob after the caller's snapshot was taken), loads the clip off the
    /// main actor, encodes, persists via `SessionStore.updateSegmentEmbedding`
    /// and returns. Completed results stay cached (bounded) so a Confirm
    /// card holding a stale snapshot never re-encodes on every chip toggle.
    func embedding(for segment: SegmentRecord) async -> Data? {
        if let blob = segment.embedding { return blob }
        if let task = embeddingTasks[segment.id] { return await task.value }
        guard let embedder,
              !FileLocations.isDeleted(clipRef: segment.clipRef),
              !MissingClipRegistry.shared.contains(segment.clipRef)
        else { return nil }

        let db = self.db
        let id = segment.id
        let clipRef = segment.clipRef
        let task = Task.detached(priority: .userInitiated) { () -> Data? in
            if let stored = try? await db.dbQueue.read({ db in
                try Data.fetchOne(
                    db,
                    sql: "SELECT embedding FROM segments WHERE id = ? AND embedding IS NOT NULL",
                    arguments: [id]
                )
            }) {
                return stored
            }
            guard let blob = await EmbeddingBackfill.embedClip(clipRef, embedder: embedder) else { return nil }
            try? SessionStore(db: db).updateSegmentEmbedding(id: id, embedding: blob)
            return blob
        }
        remember(task, for: id)
        let result = await task.value
        if result == nil {
            // Not cached: a transient failure may succeed later.
            forgetEmbeddingTask(for: id)
        }
        return result
    }

    /// Embedding for a clip that may or may not have a segment row (an
    /// exemplar's clip). Goes through the segment cache when it can.
    func embedding(forClipRef clipRef: String) async -> Data? {
        guard !FileLocations.isDeleted(clipRef: clipRef) else { return nil }
        let db = self.db
        let segment = try? await db.dbQueue.read { db in
            try SegmentRecord.filter(Column("clipRef") == clipRef).fetchOne(db)
        }
        if let segment {
            return await embedding(for: segment)
        }
        guard let embedder else { return nil }
        return await Task.detached(priority: .utility) {
            await EmbeddingBackfill.embedClip(clipRef, embedder: embedder)
        }.value
    }

    /// Embeds raw samples for freshly-captured segments (§5.7: embed near
    /// capture so ranking is instant later). Nil when no model is bundled.
    /// Prefer `embedSamples(_:segmentId:)`, which also registers the work
    /// in the per-segment cache and persists the result.
    func embedSamples(_ samples: [Float]) async -> Data? {
        guard let embedder else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> Data? in
            guard let vector = try? await embedder.embed(samples: samples) else { return nil }
            return EmbeddingCodec.encode(vector)
        }.value
    }

    /// Capture-path embedding keyed by segment id: a concurrent
    /// `suggestions(for:)` for the same segment joins this task instead of
    /// loading the clip and encoding again. Persists the blob on the
    /// segment row (the row must already exist).
    func embedSamples(_ samples: [Float], segmentId: String) async -> Data? {
        if let task = embeddingTasks[segmentId] { return await task.value }
        guard let embedder else { return nil }
        let db = self.db
        let task = Task.detached(priority: .userInitiated) { () -> Data? in
            guard let vector = try? await embedder.embed(samples: samples) else { return nil }
            let blob = EmbeddingCodec.encode(vector)
            try? SessionStore(db: db).updateSegmentEmbedding(id: segmentId, embedding: blob)
            return blob
        }
        remember(task, for: segmentId)
        let result = await task.value
        if result == nil {
            forgetEmbeddingTask(for: segmentId)
        }
        return result
    }

    private func remember(_ task: Task<Data?, Never>, for segmentId: String) {
        if embeddingTasks[segmentId] == nil {
            embeddingTaskOrder.append(segmentId)
        }
        embeddingTasks[segmentId] = task
        while embeddingTaskOrder.count > embeddingCacheLimit {
            let oldest = embeddingTaskOrder.removeFirst()
            embeddingTasks[oldest] = nil
        }
    }

    private func forgetEmbeddingTask(for segmentId: String) {
        embeddingTasks[segmentId] = nil
        embeddingTaskOrder.removeAll { $0 == segmentId }
    }

    // MARK: - Exchange rejections

    /// Intents rejected in this exchange, from the negatives table (one
    /// query per exchange id, cached). `noteDismissal` keeps the entry
    /// coherent when a dismissal is written elsewhere.
    func rejectedIntentIds(exchangeId: String) async -> Set<String> {
        if let cached = rejectedByExchange[exchangeId] { return cached }
        let db = self.db
        let ids = (try? await db.dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT DISTINCT rejectedIntentId FROM negatives WHERE exchangeId = ?",
                arguments: [exchangeId]
            )
        }) ?? []
        // Merge rather than overwrite: a dismissal may have been noted while
        // the read was in flight.
        let merged = Set(ids).union(rejectedByExchange[exchangeId] ?? [])
        rememberRejected(merged, for: exchangeId)
        return merged
    }

    /// A guess was dismissed in this exchange (the negative row is written
    /// by ConfirmViewModel). Keeps the exchange's exclusion set coherent
    /// without a re-read; rejection is final (§2.4).
    func noteDismissal(intentId: String, exchangeId: String?) {
        guard let exchangeId else { return }
        var set = rejectedByExchange[exchangeId] ?? []
        set.insert(intentId)
        rememberRejected(set, for: exchangeId)
    }

    /// Drops the cached exclusion set so the next call re-reads negatives.
    func invalidateRejections(exchangeId: String) {
        rejectedByExchange[exchangeId] = nil
        rejectedExchangeOrder.removeAll { $0 == exchangeId }
    }

    private func rememberRejected(_ set: Set<String>, for exchangeId: String) {
        if rejectedByExchange[exchangeId] == nil {
            rejectedExchangeOrder.append(exchangeId)
        }
        rejectedByExchange[exchangeId] = set
        while rejectedExchangeOrder.count > rejectedCacheLimit {
            let oldest = rejectedExchangeOrder.removeFirst()
            rejectedByExchange[oldest] = nil
        }
    }

    // MARK: - Ranking

    /// Top-3 tentative guesses for an exchange's segments (§4.5). Only
    /// mature intents may be suggested (§5.6). `excluding` carries the
    /// caller's dismissed guesses; it is unioned with the intents rejected
    /// in the segments' exchange (`segments.first?.sessionId`) from the
    /// negatives table — rejection is final (§2.4) whichever surface asks.
    ///
    /// Each segment is ranked separately and the per-segment standardized
    /// scores are averaged per intent (§5.2: no prototype averaging, not
    /// even of the query), with a vote count as tie-break.
    func suggestions(for segments: [SegmentRecord],
                     station: String,
                     excluding dismissed: Set<String> = [],
                     now: Date = Date()) async -> [Suggestion] {
        guard isModelAvailable, !index.isEmpty, !suggestibleIntents.isEmpty, !segments.isEmpty else { return [] }

        var excluded = dismissed
        if let exchangeId = segments.first?.sessionId {
            excluded.formUnion(await rejectedIntentIds(exchangeId: exchangeId))
        }

        var queries: [[Float]] = []
        for segment in segments {
            if let blob = await embedding(for: segment) {
                let vector = EmbeddingCodec.decode(blob)
                if !vector.isEmpty { queries.append(vector) }
            }
        }
        guard !queries.isEmpty else { return [] }

        let index = self.index
        let config = rankerConfig
        var rankings: [IntentRanker.Ranking] = []
        var seen: Set<String> = []
        var votes: [String: Int] = [:]
        for query in queries {
            let ranking = IntentRanker.rankDetailed(
                query: query, exemplars: index, excluding: excluded, now: now, config: config
            )
            rankings.append(ranking)
            for (position, ranked) in ranking.intents.enumerated() {
                seen.insert(ranked.intentId)
                if position < 3 { votes[ranked.intentId, default: 0] += 1 }
            }
        }

        // Mean of per-segment z; where an intent had no positive match for
        // a segment it contributes the z of a zero similarity there.
        var meanZ: [String: Double] = [:]
        for intentId in seen {
            var total = 0.0
            for ranking in rankings {
                if let ranked = ranking.intents.first(where: { $0.intentId == intentId }) {
                    total += ranked.z
                } else {
                    total += ranking.z(forWeightedSimilarity: 0, config: config)
                }
            }
            meanZ[intentId] = total / Double(rankings.count)
        }

        let context = ContextPriors.Snapshot(
            hourOfDay: Calendar.current.component(.hour, from: now),
            station: station,
            now: now
        )
        let db = self.db
        let activeIntents = (try? await db.dbQueue.read {
            try IntentRecord.filter(Column("archivedAt") == nil).fetchAll($0)
        }) ?? []
        let intentById = Dictionary(uniqueKeysWithValues: activeIntents.map { ($0.id, $0) })
        let floor = probabilityFloor

        return meanZ
            .filter { suggestibleIntents.contains($0.key) && !excluded.contains($0.key) }
            .compactMap { entry -> Suggestion? in
                let intentId = entry.key
                let z = entry.value
                guard let intent = intentById[intentId] else { return nil }
                let calibrator = calibrators[intentId] ?? .uncalibrated
                let probability = calibrator.probability(of: z)
                guard probability >= floor else { return nil }
                let prior = priors?.prior(for: intentId, context: context) ?? 1
                return Suggestion(
                    intent: intent,
                    rawScore: z,
                    probability: probability,
                    prior: prior,
                    rankingScore: probability * prior,
                    votes: votes[intentId] ?? 0
                )
            }
            .sorted { lhs, rhs in
                if lhs.rankingScore != rhs.rankingScore { return lhs.rankingScore > rhs.rankingScore }
                if lhs.votes != rhs.votes { return lhs.votes > rhs.votes }
                return lhs.intent.label.localizedCaseInsensitiveCompare(rhs.intent.label) == .orderedAscending
            }
            .prefix(3)
            .map { $0 }
    }

    // MARK: - Outcomes

    /// A shown guess was accepted or rejected: store the observation and
    /// refit that word's calibrator. A rejection at a given z lowers the
    /// probability the calibrator assigns near that z — the threshold
    /// tightens (§5.2, phase 2 acceptance criterion). Pass `exchangeId` so
    /// a rejection also lands in the exchange's exclusion set.
    func recordOutcome(intentId: String,
                       rawScore: Double,
                       accepted: Bool,
                       exchangeId: String? = nil,
                       now: Date = Date()) {
        try? CalibrationStore(db: db).record(CalibrationObservationRecord(
            intentId: intentId,
            score: rawScore,
            accepted: accepted,
            timestamp: now
        ))
        if !accepted {
            noteDismissal(intentId: intentId, exchangeId: exchangeId)
        }
        refitCalibrator(intentId: intentId)
    }

    /// The yes moment with guesses on screen: every shown guess is an
    /// observation — accepted if it is the confirmed intent, rejected
    /// otherwise (§4.5: the model was wrong, and the shown-but-not-chosen
    /// guesses say how). One transaction. Hard negatives for explicit
    /// dismissals are still ConfirmViewModel's job.
    func recordOutcomes(topGuesses: [Suggestion],
                        confirmed confirmedIntentId: String,
                        exchangeId: String?,
                        now: Date = Date()) {
        guard !topGuesses.isEmpty else { return }
        let records = topGuesses.map { guess in
            CalibrationObservationRecord(
                intentId: guess.intent.id,
                score: guess.rawScore,
                accepted: guess.intent.id == confirmedIntentId,
                timestamp: now
            )
        }
        try? db.dbQueue.write { db in
            for record in records {
                try record.insert(db)
            }
        }
        for intentId in Set(records.map(\.intentId)) {
            refitCalibrator(intentId: intentId)
        }
    }

    private func refitCalibrator(intentId: String) {
        let history = ((try? CalibrationStore(db: db).observations(intentId: intentId)) ?? [])
            .filter(CalibrationFeature.isCurrent)
            .map { (score: $0.score, accepted: $0.accepted) }
        calibrators[intentId] = LogisticCalibrator.fit(observations: history)
    }

    // MARK: - Introspection (tests, Progress)

    /// The calibrator currently used for an intent (`.uncalibrated` until
    /// it has history).
    func calibrator(for intentId: String) -> LogisticCalibrator {
        calibrators[intentId] ?? .uncalibrated
    }

    var indexedExemplarCount: Int { index.count }
    var suggestibleIntentIds: Set<String> { suggestibleIntents }
    var cachedEmbeddingCount: Int { embeddingTasks.count }
}
