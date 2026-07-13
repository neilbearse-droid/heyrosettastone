import Foundation

/// §5.6: an intent becomes suggestible when it has at least 5 confirmed
/// exemplars AND its leave-one-out top-3 hit rate on its own exemplars
/// clears the threshold. Progress shows these numbers per word so the
/// family can see exactly what the model knows.
enum MaturityGate {
    struct Config {
        var minExemplars = 5
        var minLooHitRate = 0.7
        var ranker = IntentRanker.Config()
    }

    struct Report: Identifiable {
        let intentId: String
        let exemplarCount: Int
        /// nil until there are enough exemplars to evaluate.
        let looTop3HitRate: Double?
        let isSuggestible: Bool

        var id: String { intentId }
    }

    /// Leave-one-out evaluation for one intent: each of its exemplars in
    /// turn becomes the query against the index minus itself; a hit is the
    /// intent appearing in the top 3.
    static func evaluate(intentId: String,
                         index: [ExemplarVector],
                         now: Date = Date(),
                         config: Config = Config()) -> Report {
        let own = index.filter { $0.intentId == intentId }
        guard own.count >= config.minExemplars else {
            return Report(
                intentId: intentId,
                exemplarCount: own.count,
                looTop3HitRate: nil,
                isSuggestible: false
            )
        }

        var hitCount = 0
        for exemplar in own {
            let rest = index.filter { $0.exemplarId != exemplar.exemplarId }
            let top3 = IntentRanker.rank(query: exemplar.vector, exemplars: rest, now: now, config: config.ranker)
                .prefix(3)
            if top3.contains(where: { $0.intentId == intentId }) {
                hitCount += 1
            }
        }
        let hitRate = Double(hitCount) / Double(own.count)
        return Report(
            intentId: intentId,
            exemplarCount: own.count,
            looTop3HitRate: hitRate,
            isSuggestible: hitRate >= config.minLooHitRate
        )
    }
}
