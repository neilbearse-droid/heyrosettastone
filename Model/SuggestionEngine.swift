import Foundation
import GRDB
import Observation

/// One tentative guess for the parent surface. Copy is always phrased as a
/// maybe (§2.6); the dots communicate confidence without pretending to
/// certainty.
struct Suggestion: Identifiable, Equatable {
    let intent: IntentRecord
    /// kNN score × context prior — the calibration feature, echoed back on
    /// accept/reject so the intent's threshold learns.
    let rawScore: Double
    /// Calibrated acceptance probability.
    let probability: Double

    var id: String { intent.id }
    var confidenceDots: Int { probability > 0.75 ? 3 : probability > 0.5 ? 2 : 1 }
}

/// Orchestrates §5: owns the in-memory exemplar index, per-intent
/// calibrators, context priors, and maturity reports; answers "top-3 for
/// these segments" for the Confirm card and live parent view. Absent a
/// bundled encoder model, everything returns empty and the app behaves as
/// Phase 1 (§2.1: the model earns its way in).
@MainActor
@Observable
final class SuggestionEngine {
    private let db: AppDatabase
    private var embedder: EmbeddingProvider?

    private(set) var isModelAvailable = false
    private(set) var maturityReports: [MaturityGate.Report] = []

    private var index: [ExemplarVector] = []
    private var calibrators: [String: LogisticCalibrator] = [:]
    private var priors: ContextPriors?
    private var suggestibleIntents: Set<String> = []

    /// Skip guesses this improbable rather than show noise.
    private let probabilityFloor = 0.05

    init(db: AppDatabase) {
        self.db = db
    }

    /// Call once at launch: loads the encoder if bundled, backfills
    /// missing embeddings, builds the index.
    func start() async {
        embedder = await WhisperKitEmbedder.loadIfAvailable()
        isModelAvailable = embedder != nil
        if let embedder {
            await EmbeddingBackfill(db: db, embedder: embedder).run()
        }
        await reload()
    }

    /// Rebuilds index, calibrators, priors, and maturity from the database.
    /// Call after anything that confirms, rejects, or prunes.
    func reload() async {
        let db = self.db
        let (index, calibrators, priors, reports) = await Task.detached(priority: .utility) {
            Self.buildState(db: db)
        }.value
        self.index = index
        self.calibrators = calibrators
        self.priors = priors
        self.maturityReports = reports
        self.suggestibleIntents = Set(reports.filter(\.isSuggestible).map(\.intentId))
    }

    private nonisolated static func buildState(
        db: AppDatabase
    ) -> ([ExemplarVector], [String: LogisticCalibrator], ContextPriors?, [MaturityGate.Report]) {
        let exemplars = (try? db.dbQueue.read { try ExemplarRecord.fetchAll($0) }) ?? []
        let intents = (try? db.dbQueue.read {
            try IntentRecord.filter(Column("archivedAt") == nil).fetchAll($0)
        }) ?? []
        let observations = (try? db.dbQueue.read {
            try CalibrationObservationRecord.fetchAll($0)
        }) ?? []

        let index: [ExemplarVector] = exemplars.compactMap { exemplar in
            guard let blob = exemplar.embedding else { return nil }
            return ExemplarVector(
                exemplarId: exemplar.id,
                intentId: exemplar.intentId,
                vector: EmbeddingCodec.decode(blob),
                timestamp: exemplar.timestamp,
                decayExempt: exemplar.decayExempt
            )
        }

        var calibrators: [String: LogisticCalibrator] = [:]
        for intentId in Set(observations.map(\.intentId)) {
            let history = observations
                .filter { $0.intentId == intentId }
                .map { (score: $0.score, accepted: $0.accepted) }
            calibrators[intentId] = LogisticCalibrator.fit(observations: history)
        }

        let priorObservations = exemplars.map { exemplar in
            ContextPriors.Observation(
                intentId: exemplar.intentId,
                hourOfDay: Calendar.current.component(.hour, from: exemplar.timestamp),
                station: exemplar.device,
                timestamp: exemplar.timestamp
            )
        }
        let priors = ContextPriors(
            observations: priorObservations,
            intentIds: intents.map(\.id)
        )

        let intentsWithExemplars = Set(index.map(\.intentId))
        let reports = intents.map { intent in
            intentsWithExemplars.contains(intent.id)
                ? MaturityGate.evaluate(intentId: intent.id, index: index)
                : MaturityGate.Report(intentId: intent.id, exemplarCount: 0, looTop3HitRate: nil, isSuggestible: false)
        }

        return (index, calibrators, priors, reports)
    }

    // MARK: - Ranking

    /// Top-3 tentative guesses for an exchange's segments (§4.5). Only
    /// mature intents may be suggested (§5.6). `excluding` carries the
    /// exchange's dismissed guesses — rejection is final (§2.4).
    func suggestions(for segments: [SegmentRecord],
                     station: String,
                     excluding dismissed: Set<String> = [],
                     now: Date = Date()) async -> [Suggestion] {
        guard isModelAvailable, !index.isEmpty, !suggestibleIntents.isEmpty else { return [] }

        var vectors: [[Float]] = []
        for segment in segments {
            if let blob = await embeddingForSegment(segment) {
                vectors.append(EmbeddingCodec.decode(blob))
            }
        }
        guard let query = VectorMath.meanPooled(vectors) else { return [] }

        let ranked = IntentRanker.rank(query: query, exemplars: index, now: now)
        let context = ContextPriors.Snapshot(
            hourOfDay: Calendar.current.component(.hour, from: now),
            station: station,
            now: now
        )

        let intentById: [String: IntentRecord] = Dictionary(
            uniqueKeysWithValues: ((try? db.dbQueue.read {
                try IntentRecord.filter(Column("archivedAt") == nil).fetchAll($0)
            }) ?? []).map { ($0.id, $0) }
        )

        return ranked
            .filter { suggestibleIntents.contains($0.intentId) && !dismissed.contains($0.intentId) }
            .compactMap { candidate -> Suggestion? in
                guard let intent = intentById[candidate.intentId] else { return nil }
                let rawScore = candidate.score * (priors?.prior(for: candidate.intentId, context: context) ?? 1)
                let calibrator = calibrators[candidate.intentId] ?? .uncalibrated
                let probability = calibrator.probability(of: rawScore)
                guard probability >= probabilityFloor else { return nil }
                return Suggestion(intent: intent, rawScore: rawScore, probability: probability)
            }
            .sorted { $0.probability > $1.probability }
            .prefix(3)
            .map { $0 }
    }

    /// The segment's stored embedding, computing and persisting it if the
    /// encoder is live and it's missing.
    private func embeddingForSegment(_ segment: SegmentRecord) async -> Data? {
        if let blob = segment.embedding { return blob }
        guard let embedder,
              let samples = try? ClipAudioLoader.loadSamples(clipRef: segment.clipRef),
              let vector = try? await embedder.embed(samples: samples)
        else { return nil }
        let blob = EmbeddingCodec.encode(vector)
        try? SessionStore(db: db).updateSegmentEmbedding(id: segment.id, embedding: blob)
        return blob
    }

    /// Embeds raw samples for freshly-captured segments (§5.7: embed near
    /// capture so ranking is instant later). Nil when no model is bundled.
    func embedSamples(_ samples: [Float]) async -> Data? {
        guard let embedder, let vector = try? await embedder.embed(samples: samples) else { return nil }
        return EmbeddingCodec.encode(vector)
    }

    // MARK: - Outcomes

    /// A shown guess was accepted or rejected: store the observation and
    /// refit that word's calibrator. A rejection at a given score lowers
    /// the probability the calibrator assigns near that score — the
    /// threshold tightens (§5.2, phase 2 acceptance criterion).
    func recordOutcome(intentId: String, rawScore: Double, accepted: Bool, now: Date = Date()) {
        try? CalibrationStore(db: db).record(CalibrationObservationRecord(
            intentId: intentId,
            score: rawScore,
            accepted: accepted,
            timestamp: now
        ))
        let history = ((try? CalibrationStore(db: db).observations(intentId: intentId)) ?? [])
            .map { (score: $0.score, accepted: $0.accepted) }
        calibrators[intentId] = LogisticCalibrator.fit(observations: history)
    }
}
