import Foundation

/// Cheap accuracy (§5.3): multiply kNN scores by a smoothed prior built
/// from hour-of-day bucket, capture-station identity, and short-horizon
/// recency of the same intent. Routines make these strong — banana at 7am
/// on the kitchen device should outrank banana at 9pm in the bath.
struct ContextPriors {
    struct Snapshot {
        let hourOfDay: Int
        let station: String
        let now: Date
    }

    struct Config {
        /// 3-hour buckets: 8 per day.
        var bucketHours = 3
        /// Laplace smoothing so sparse history stays gentle.
        var smoothing: Double = 2
        /// Exponent tempering the conditional priors (1 = full strength).
        var temper: Double = 0.5
        /// Short-horizon recency boost: size and time constant.
        var recencyBoost: Double = 0.5
        var recencyTau: TimeInterval = 30 * 60
    }

    /// (intentId, hourOfDay, station, timestamp) per historical confirmation.
    struct Observation {
        let intentId: String
        let hourOfDay: Int
        let station: String
        let timestamp: Date
    }

    private let config: Config
    private let intentIds: [String]
    private var byBucket: [Int: [String: Int]] = [:]
    private var bucketTotals: [Int: Int] = [:]
    private var byStation: [String: [String: Int]] = [:]
    private var stationTotals: [String: Int] = [:]
    private var lastConfirmed: [String: Date] = [:]

    init(observations: [Observation], intentIds: [String], config: Config = Config()) {
        self.config = config
        self.intentIds = intentIds
        for obs in observations {
            let bucket = obs.hourOfDay / config.bucketHours
            byBucket[bucket, default: [:]][obs.intentId, default: 0] += 1
            bucketTotals[bucket, default: 0] += 1
            byStation[obs.station, default: [:]][obs.intentId, default: 0] += 1
            stationTotals[obs.station, default: 0] += 1
            if (lastConfirmed[obs.intentId] ?? .distantPast) < obs.timestamp {
                lastConfirmed[obs.intentId] = obs.timestamp
            }
        }
    }

    /// Multiplier around 1: >1 when context says "likely now", <1 when the
    /// history says this intent rarely happens here/at this hour. With no
    /// history at all the prior is exactly 1 and ranking is untouched —
    /// the model earns its way in (§2.1).
    func prior(for intentId: String, context: Snapshot) -> Double {
        let n = max(1, intentIds.count)
        let uniform = 1.0 / Double(n)

        // Laplace-smoothed P(intent | condition), pulling toward uniform on
        // sparse history.
        func smoothedConditional(counts: [String: Int]?, total: Int?) -> Double? {
            guard let counts, let total, total > 0 else { return nil }
            let count = Double(counts[intentId] ?? 0)
            return (count + config.smoothing * uniform) / (Double(total) + config.smoothing)
        }

        var multiplier = 1.0
        let bucket = context.hourOfDay / config.bucketHours
        if let p = smoothedConditional(counts: byBucket[bucket], total: bucketTotals[bucket]) {
            multiplier *= pow(p / uniform, config.temper)
        }
        if let p = smoothedConditional(counts: byStation[context.station], total: stationTotals[context.station]) {
            multiplier *= pow(p / uniform, config.temper)
        }

        // Short-horizon recency: just-confirmed intents often repeat.
        if let last = lastConfirmed[intentId] {
            let delta = context.now.timeIntervalSince(last)
            if delta >= 0 {
                multiplier *= 1 + config.recencyBoost * exp(-delta / config.recencyTau)
            }
        }
        return multiplier
    }
}
