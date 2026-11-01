import Foundation

/// One exemplar loaded into the in-memory index.
struct ExemplarVector {
    let exemplarId: String
    let intentId: String
    /// L2-normalized embedding.
    let vector: [Float]
    let timestamp: Date
    let decayExempt: Bool
    /// The exchange session the clip was captured in. Chips from one
    /// exchange are near-duplicates (the same utterance repeated seconds
    /// apart in the same acoustics), so maturity holds out whole sessions
    /// (§5.6). Nil is treated as "its own session".
    let sessionId: String?

    init(exemplarId: String,
         intentId: String,
         vector: [Float],
         timestamp: Date,
         decayExempt: Bool,
         sessionId: String? = nil) {
        self.exemplarId = exemplarId
        self.intentId = intentId
        self.vector = vector
        self.timestamp = timestamp
        self.decayExempt = decayExempt
        self.sessionId = sessionId
    }

    /// Key used for leave-one-session-out: exemplars without a session id
    /// are each their own session.
    var sessionKey: String { sessionId ?? "exemplar:" + exemplarId }
}

/// The §5.1 ranking core: cosine kNN over all exemplars — never class
/// prototypes, because apraxic speech makes classes multimodal and exemplar
/// kNN handles that where averaging destroys it (§5.2) — with exponential
/// recency weighting (§5.4). Pure functions; the caller supplies the index.
///
/// Scoring is per intent: each intent is scored on its own k nearest
/// exemplars (best similarity, plus a small agreement bonus), so every
/// eligible intent gets a score and the top-3 is really three whenever
/// three mature words exist. The calibration feature is a standardized
/// score `z` (how far the intent's best match sits above the mean
/// similarity of the whole eligible index, in standard deviations), because
/// mean-pooled encoder cosines cluster in a narrow band (≈0.80–0.95) where
/// raw scores carry almost no information.
enum IntentRanker {
    struct Config {
        /// Small k (§5.2): the intent's own k nearest exemplars are consulted.
        var k = 4
        /// Recency half-life (§5.4), tunable.
        var halfLifeDays: Double = 90
        /// Old evidence fades to this fraction of its weight, never to zero
        /// (§5.4: old exemplars decay in influence, they do not vanish).
        var recencyFloor: Double = 0.25
        /// Bonus (in z units) per additional neighbour agreeing with the
        /// best match, so repeated agreement breaks ties.
        var agreementBonus: Double = 0.1
        /// A neighbour "agrees" when its weighted similarity is within this
        /// many standard deviations of the intent's best match.
        var agreementStdMargin: Double = 0.5
        /// Legacy multiplicative bonus kept for the [0, 1] `score` field.
        var legacyScoreBonus: Double = 0.05
        /// Floor on the standard deviation used for standardization.
        var minStd: Double = 1e-3
    }

    struct RankedIntent: Equatable {
        let intentId: String
        /// Recency-weighted cosine score in [0, 1]; kept for compatibility
        /// and display. Ranking and calibration use `z`.
        let score: Double
        /// Standardized feature: (best weighted similarity − mean weighted
        /// similarity over the eligible index) / std, plus the agreement
        /// bonus. This is what the per-intent calibrator consumes.
        let z: Double
        /// How many of the intent's exemplars (≤ k) had a positive
        /// weighted similarity.
        let neighbourCount: Int
        /// Best raw cosine (no recency weight, no bonus) between the query
        /// and any of the intent's exemplars. This is the absolute evidence
        /// the engine checks against the word's own self-similarity floor
        /// (`MaturityGate.Report.selfSimilarityFloor`): `z` says how the
        /// word compares with the other words, `bestSimilarity` says
        /// whether the utterance resembles this word at all.
        let bestSimilarity: Double

        init(intentId: String, score: Double, z: Double, neighbourCount: Int, bestSimilarity: Double = 0) {
            self.intentId = intentId
            self.score = score
            self.z = z
            self.neighbourCount = neighbourCount
            self.bestSimilarity = bestSimilarity
        }
    }

    /// Full ranking result including the standardization statistics, so a
    /// caller aggregating over several queries can express "absent" as the
    /// z of a zero similarity.
    struct Ranking {
        let intents: [RankedIntent]
        /// Mean of weighted similarity over the eligible index.
        let meanSimilarity: Double
        /// Population standard deviation of weighted similarity (unfloored).
        let stdSimilarity: Double

        /// z that a weighted similarity of exactly 0 would receive.
        func z(forWeightedSimilarity sim: Double, config: Config = Config()) -> Double {
            (sim - meanSimilarity) / max(stdSimilarity, config.minStd)
        }
    }

    /// `floor + (1 − floor) · 0.5^(age/halfLife)`; decay-exempt exemplars
    /// never fade (§5.4 — old exemplars decay in influence but are never
    /// auto-deleted). The floor keeps a word confirmed heavily months ago
    /// from dropping out of the top-3 even though its LOO still passes.
    static func recencyWeight(timestamp: Date,
                              decayExempt: Bool,
                              now: Date,
                              halfLifeDays: Double,
                              floor: Double = Config().recencyFloor) -> Double {
        guard !decayExempt else { return 1 }
        let ageDays = max(0, now.timeIntervalSince(timestamp)) / 86_400
        let clampedFloor = min(max(floor, 0), 1)
        return clampedFloor + (1 - clampedFloor) * pow(0.5, ageDays / halfLifeDays)
    }

    /// Ranks every eligible intent present in the index against the query
    /// embedding. `excluding` removes those intents' exemplars BEFORE
    /// anything is scored, so a dismissed guess never shadows the next one.
    static func rank(query: [Float],
                     exemplars: [ExemplarVector],
                     excluding: Set<String> = [],
                     now: Date = Date(),
                     config: Config = Config()) -> [RankedIntent] {
        rankDetailed(query: query, exemplars: exemplars, excluding: excluding, now: now, config: config).intents
    }

    static func rankDetailed(query: [Float],
                             exemplars: [ExemplarVector],
                             excluding: Set<String> = [],
                             now: Date = Date(),
                             config: Config = Config()) -> Ranking {
        let empty = Ranking(intents: [], meanSimilarity: 0, stdSimilarity: 0)
        guard !exemplars.isEmpty, !query.isEmpty else { return empty }

        // Eligible = not excluded and dimensionally comparable with the
        // query (a checkpoint change leaves mixed-dimension rows behind;
        // cosine would silently return 0 for them).
        let eligible = exemplars.filter { !excluding.contains($0.intentId) && $0.vector.count == query.count }
        guard !eligible.isEmpty else { return empty }

        let scored: [(intentId: String, weightedSim: Double, rawSim: Double)] = eligible.map { exemplar in
            let similarity = VectorMath.cosine(query, exemplar.vector)
            let weight = recencyWeight(
                timestamp: exemplar.timestamp,
                decayExempt: exemplar.decayExempt,
                now: now,
                halfLifeDays: config.halfLifeDays,
                floor: config.recencyFloor
            )
            // Similarity can be negative; clamp so a strongly-dissimilar old
            // exemplar can't outrank a mildly-dissimilar fresh one after
            // weighting flips the sign ordering.
            return (exemplar.intentId, max(0, similarity) * weight, similarity)
        }

        let stats = standardization(of: scored.map(\.weightedSim))
        let intents = scoreIntents(scored, mean: stats.mean, std: stats.std, config: config)
        return Ranking(intents: intents, meanSimilarity: stats.mean, stdSimilarity: stats.std)
    }

    /// Mean and population standard deviation of the weighted similarities
    /// over the eligible index (zeros included — they are real evidence of
    /// how far the query sits from most of the store).
    static func standardization(of values: [Double]) -> (mean: Double, std: Double) {
        guard !values.isEmpty else { return (0, 0) }
        let n = Double(values.count)
        let mean = values.reduce(0, +) / n
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n
        return (mean, variance.squareRoot())
    }

    /// Per-intent scoring shared by the ranker and the maturity gate's
    /// reference path: neighbours with a non-positive weighted similarity
    /// are dropped before the k cut, then each intent is scored on its own
    /// k nearest.
    static func scoreIntents(_ scored: [(intentId: String, weightedSim: Double, rawSim: Double)],
                             mean: Double,
                             std: Double,
                             config: Config) -> [RankedIntent] {
        var byIntent: [String: [Double]] = [:]
        var bestRaw: [String: Double] = [:]
        for entry in scored where entry.weightedSim > 0 {
            byIntent[entry.intentId, default: []].append(entry.weightedSim)
            bestRaw[entry.intentId] = max(bestRaw[entry.intentId] ?? -1, entry.rawSim)
        }
        let sd = max(std, config.minStd)
        let margin = config.agreementStdMargin * sd

        return byIntent
            .map { intentId, sims -> RankedIntent in
                let topK = Array(sims.sorted(by: >).prefix(max(1, config.k)))
                let best = topK[0]
                let agreeing = topK.dropFirst().filter { $0 >= best - margin }.count
                let z = (best - mean) / sd + config.agreementBonus * Double(agreeing)
                let score = min(1.0, best * (1 + config.legacyScoreBonus * Double(agreeing)))
                return RankedIntent(
                    intentId: intentId,
                    score: score,
                    z: z,
                    neighbourCount: topK.count,
                    bestSimilarity: bestRaw[intentId] ?? 0
                )
            }
            .sorted { lhs, rhs in
                if lhs.z != rhs.z { return lhs.z > rhs.z }
                if lhs.neighbourCount != rhs.neighbourCount { return lhs.neighbourCount > rhs.neighbourCount }
                return lhs.intentId < rhs.intentId
            }
    }
}
