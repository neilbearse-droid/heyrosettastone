import Foundation

/// One exemplar loaded into the in-memory index.
struct ExemplarVector {
    let exemplarId: String
    let intentId: String
    /// L2-normalized embedding.
    let vector: [Float]
    let timestamp: Date
    let decayExempt: Bool
}

/// The §5.1 ranking core: cosine kNN over all exemplars — never class
/// prototypes, because apraxic speech makes classes multimodal and exemplar
/// kNN handles that where averaging destroys it (§5.2) — with exponential
/// recency weighting (§5.4). Pure functions; the caller supplies the index.
enum IntentRanker {
    struct Config {
        /// Small k (§5.2).
        var k = 4
        /// Recency half-life (§5.4), tunable.
        var halfLifeDays: Double = 90
    }

    struct RankedIntent: Equatable {
        let intentId: String
        /// Recency-weighted cosine score in [0, 1]-ish; the calibration
        /// layer turns this into a probability.
        let score: Double
    }

    /// 0.5^(age/halfLife); decay-exempt exemplars never fade (§5.4 — old
    /// exemplars decay in influence but are never auto-deleted).
    static func recencyWeight(timestamp: Date, decayExempt: Bool, now: Date, halfLifeDays: Double) -> Double {
        guard !decayExempt else { return 1 }
        let ageDays = max(0, now.timeIntervalSince(timestamp)) / 86_400
        return pow(0.5, ageDays / halfLifeDays)
    }

    /// Ranks every intent present in the index against the query embedding.
    /// The k nearest exemplars (by recency-weighted similarity) vote; an
    /// intent's score is its best-matching neighbour, with a small bonus per
    /// additional neighbour so repeated agreement breaks ties.
    static func rank(query: [Float],
                     exemplars: [ExemplarVector],
                     now: Date = Date(),
                     config: Config = Config()) -> [RankedIntent] {
        guard !exemplars.isEmpty, !query.isEmpty else { return [] }

        let scored: [(intentId: String, weightedSim: Double)] = exemplars.map { exemplar in
            let similarity = VectorMath.cosine(query, exemplar.vector)
            let weight = recencyWeight(
                timestamp: exemplar.timestamp,
                decayExempt: exemplar.decayExempt,
                now: now,
                halfLifeDays: config.halfLifeDays
            )
            // Similarity can be negative; clamp so a strongly-dissimilar old
            // exemplar can't outrank a mildly-dissimilar fresh one after
            // weighting flips the sign ordering.
            return (exemplar.intentId, max(0, similarity) * weight)
        }

        let neighbours = scored
            .sorted { $0.weightedSim > $1.weightedSim }
            .prefix(config.k)

        var best: [String: Double] = [:]
        var hits: [String: Int] = [:]
        for neighbour in neighbours {
            best[neighbour.intentId] = max(best[neighbour.intentId] ?? 0, neighbour.weightedSim)
            hits[neighbour.intentId, default: 0] += 1
        }

        return best
            .map { intentId, bestSim in
                let extraHits = Double((hits[intentId] ?? 1) - 1)
                return RankedIntent(intentId: intentId, score: min(1.0, bestSim * (1 + 0.05 * extraHits)))
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.intentId < rhs.intentId
            }
    }
}
