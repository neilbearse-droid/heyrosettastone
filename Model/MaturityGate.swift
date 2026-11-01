import Accelerate
import Foundation

/// §5.6: an intent becomes suggestible when it has at least 5 confirmed
/// exemplars from at least 3 distinct exchange sessions AND its
/// leave-one-session-out top-3 hit rate on its own exemplars clears the
/// threshold. Sessions, not single exemplars, are held out: the chips of
/// one exchange are the same utterance repeated seconds apart in the same
/// acoustics, so plain leave-one-out would let a word look mature after a
/// single confirmation. Progress shows these numbers per word so the family
/// can see exactly what the model knows.
///
/// Two implementations: `evaluate` is the pure, slow reference (one ranker
/// call per held-out exemplar) used by the unit tests; `evaluateAll`
/// computes the N×N similarity once with `cblas_sgemm` and derives every
/// intent's hit rate from matrix rows. The tests assert both agree.
enum MaturityGate {
    struct Config {
        var minExemplars = 5
        /// Distinct capture sessions required before the gate can open.
        var minSessions = 3
        var minLooHitRate = 0.7
        /// Self-similarity floor (the absolute guard): for every exemplar
        /// of the word, its best raw cosine to the word's exemplars from
        /// OTHER sessions is collected; the floor is this quantile of those
        /// values minus `selfSimilarityTolerance`. An utterance whose best
        /// match to the word falls under the floor is never suggested as
        /// that word, however it ranks against the other words. This is
        /// what stops a one-word dictionary answering "Football?" to
        /// everything he says: relative ranking alone always has a leader.
        var selfSimilarityQuantile = 0.1
        var selfSimilarityTolerance = 0.02
        var ranker = IntentRanker.Config()
        /// Above this many exemplars the N×N matrix (N² floats: 64 MB at
        /// 4000) is not materialized; rows are computed one at a time.
        var matrixLimit = 4000
    }

    struct Report: Identifiable {
        let intentId: String
        let exemplarCount: Int
        /// Distinct capture sessions among the exemplars.
        let sessionCount: Int
        /// nil until there are enough exemplars and sessions to evaluate.
        let looTop3HitRate: Double?
        let isSuggestible: Bool
        /// Minimum raw cosine an utterance must reach against this word's
        /// exemplars to be suggested as it (see `Config.selfSimilarityQuantile`).
        /// nil until evaluable.
        let selfSimilarityFloor: Double?
        /// Median cross-session self-similarity, for display ("its clips
        /// match each other at 0.91").
        let typicalSelfSimilarity: Double?

        var id: String { intentId }

        init(intentId: String,
             exemplarCount: Int,
             sessionCount: Int = 0,
             looTop3HitRate: Double?,
             isSuggestible: Bool,
             selfSimilarityFloor: Double? = nil,
             typicalSelfSimilarity: Double? = nil) {
            self.intentId = intentId
            self.exemplarCount = exemplarCount
            self.sessionCount = sessionCount
            self.looTop3HitRate = looTop3HitRate
            self.isSuggestible = isSuggestible
            self.selfSimilarityFloor = selfSimilarityFloor
            self.typicalSelfSimilarity = typicalSelfSimilarity
        }

        static func empty(intentId: String) -> Report {
            Report(intentId: intentId, exemplarCount: 0, sessionCount: 0, looTop3HitRate: nil, isSuggestible: false)
        }
    }

    /// Floor and median from the collected cross-session best
    /// self-similarities. Shared by the reference and fast paths so they
    /// agree exactly. Empty input gives nils.
    static func selfSimilarityStats(_ values: [Double], config: Config) -> (floor: Double?, median: Double?) {
        guard !values.isEmpty else { return (nil, nil) }
        let sorted = values.sorted()
        return (
            quantile(sorted, config.selfSimilarityQuantile) - config.selfSimilarityTolerance,
            quantile(sorted, 0.5)
        )
    }

    /// Linear-interpolated quantile of an ascending-sorted array.
    static func quantile(_ sorted: [Double], _ q: Double) -> Double {
        guard let first = sorted.first else { return 0 }
        guard sorted.count > 1 else { return first }
        let position = min(max(q, 0), 1) * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let fraction = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }

    /// Reports cached on the sorted exemplar id set, so a reload that did
    /// not change the store (a new negative, a calibration refit) does not
    /// recompute the N×N pass. The reports ignore drift in `now` between
    /// reloads; recency weights move slowly (90-day half-life, floored) and
    /// any confirm or prune changes the key anyway.
    struct Cache {
        var key: [String] = []
        var reports: [String: Report] = [:]

        static func key(for index: [ExemplarVector]) -> [String] {
            index.map(\.exemplarId).sorted()
        }
    }

    // MARK: - Reference path

    /// Leave-one-session-out evaluation for one intent: every session's
    /// exemplars in turn are removed from the index and each of them
    /// queries the rest; a hit is the intent appearing in the top 3.
    static func evaluate(intentId: String,
                         index: [ExemplarVector],
                         now: Date = Date(),
                         config: Config = Config()) -> Report {
        let own = index.filter { $0.intentId == intentId }
        let sessions = Dictionary(grouping: own, by: \.sessionKey)
        guard own.count >= config.minExemplars, sessions.count >= config.minSessions else {
            return Report(
                intentId: intentId,
                exemplarCount: own.count,
                sessionCount: sessions.count,
                looTop3HitRate: nil,
                isSuggestible: false
            )
        }

        var hitCount = 0
        var selfSimilarities: [Double] = []
        for (sessionKey, held) in sessions {
            let rest = index.filter { $0.sessionKey != sessionKey }
            let ownRest = rest.filter { $0.intentId == intentId }
            for exemplar in held {
                let top3 = IntentRanker.rank(query: exemplar.vector, exemplars: rest, now: now, config: config.ranker)
                    .prefix(3)
                if top3.contains(where: { $0.intentId == intentId }) {
                    hitCount += 1
                }
                // Raw cosine, unweighted: the absolute guard must not drift
                // with recency.
                let best = ownRest.map { VectorMath.cosine(exemplar.vector, $0.vector) }.max() ?? -1
                selfSimilarities.append(best)
            }
        }
        let hitRate = Double(hitCount) / Double(own.count)
        let stats = selfSimilarityStats(selfSimilarities, config: config)
        return Report(
            intentId: intentId,
            exemplarCount: own.count,
            sessionCount: sessions.count,
            looTop3HitRate: hitRate,
            isSuggestible: hitRate >= config.minLooHitRate,
            selfSimilarityFloor: stats.floor,
            typicalSelfSimilarity: stats.median
        )
    }

    // MARK: - Fast path

    /// Reports for every intent id, computed from one similarity pass over
    /// the index. Returns the same result as `evaluate` per intent (up to
    /// floating-point rounding of the cosine), in O(N²·d) once instead of
    /// O(N²·d) per intent plus a sort per exemplar.
    static func evaluateAll(intentIds: [String],
                            index: [ExemplarVector],
                            now: Date = Date(),
                            config: Config = Config()) -> [String: Report] {
        var reports: [String: Report] = [:]
        let n = index.count
        guard n > 0, let dimension = index.first?.vector.count, dimension > 0,
              index.allSatisfy({ $0.vector.count == dimension })
        else {
            // Empty or mixed-dimension index: the reference path filters
            // per query and is correct for both.
            for intentId in intentIds {
                reports[intentId] = evaluate(intentId: intentId, index: index, now: now, config: config)
            }
            return reports
        }

        let similarity = SimilarityRows(index: index, dimension: dimension, materialize: n <= config.matrixLimit)
        let rankerConfig = config.ranker
        let weights: [Double] = index.map {
            IntentRanker.recencyWeight(
                timestamp: $0.timestamp,
                decayExempt: $0.decayExempt,
                now: now,
                halfLifeDays: rankerConfig.halfLifeDays,
                floor: rankerConfig.recencyFloor
            )
        }
        let sessionKeys: [String] = index.map(\.sessionKey)
        let intentSlots: [String] = Array(Set(index.map(\.intentId))).sorted()
        let slotByIntent: [String: Int] = Dictionary(uniqueKeysWithValues: intentSlots.enumerated().map { ($1, $0) })
        let slotOf: [Int] = index.map { slotByIntent[$0.intentId] ?? 0 }
        var ownByIntent: [String: [Int]] = [:]
        for (i, exemplar) in index.enumerated() {
            ownByIntent[exemplar.intentId, default: []].append(i)
        }

        let k = max(1, rankerConfig.k)
        var row = [Float](repeating: 0, count: n)
        var weighted = [Double](repeating: 0, count: n)
        var eligible = [Bool](repeating: false, count: n)
        var topK = [[Double]](repeating: [], count: intentSlots.count)

        for intentId in intentIds {
            let own = ownByIntent[intentId] ?? []
            let sessionCount = Set(own.map { sessionKeys[$0] }).count
            guard own.count >= config.minExemplars, sessionCount >= config.minSessions else {
                reports[intentId] = Report(
                    intentId: intentId,
                    exemplarCount: own.count,
                    sessionCount: sessionCount,
                    looTop3HitRate: nil,
                    isSuggestible: false
                )
                continue
            }

            var hitCount = 0
            var selfSimilarities: [Double] = []
            let intentSlot = slotByIntent[intentId] ?? -1
            for i in own {
                similarity.fill(row: i, into: &row)
                let heldSession = sessionKeys[i]

                // Weighted similarity over the rest (held session removed),
                // then mean / population std exactly as the ranker does.
                // Alongside: the best raw cosine to the word's own exemplars
                // in other sessions, for the self-similarity floor.
                var sum = 0.0
                var count = 0
                var bestOwn = -1.0
                for j in 0..<n {
                    if sessionKeys[j] == heldSession {
                        eligible[j] = false
                        weighted[j] = 0
                        continue
                    }
                    eligible[j] = true
                    let raw = Double(row[j])
                    if slotOf[j] == intentSlot, raw > bestOwn { bestOwn = raw }
                    let w = max(0, raw) * weights[j]
                    weighted[j] = w
                    sum += w
                    count += 1
                }
                selfSimilarities.append(bestOwn)
                guard count > 0 else { continue }
                let mean = sum / Double(count)
                var sumSq = 0.0
                for j in 0..<n where eligible[j] {
                    let d = weighted[j] - mean
                    sumSq += d * d
                }
                let std = (sumSq / Double(count)).squareRoot()
                let sd = max(std, rankerConfig.minStd)
                let margin = rankerConfig.agreementStdMargin * sd

                // Per-intent top-k of positive weighted similarities.
                for slot in 0..<topK.count {
                    topK[slot].removeAll(keepingCapacity: true)
                }
                for j in 0..<n where eligible[j] && weighted[j] > 0 {
                    insert(weighted[j], into: &topK[slotOf[j]], limit: k)
                }

                var candidates: [(z: Double, count: Int, intentId: String)] = []
                for slot in 0..<topK.count where !topK[slot].isEmpty {
                    let values = topK[slot]
                    let best = values[0]
                    let agreeing = values.dropFirst().filter { $0 >= best - margin }.count
                    let z = (best - mean) / sd + rankerConfig.agreementBonus * Double(agreeing)
                    candidates.append((z, values.count, intentSlots[slot]))
                }
                candidates.sort { lhs, rhs in
                    if lhs.z != rhs.z { return lhs.z > rhs.z }
                    if lhs.count != rhs.count { return lhs.count > rhs.count }
                    return lhs.intentId < rhs.intentId
                }
                if candidates.prefix(3).contains(where: { $0.intentId == intentId }) {
                    hitCount += 1
                }
            }

            let hitRate = Double(hitCount) / Double(own.count)
            let stats = selfSimilarityStats(selfSimilarities, config: config)
            reports[intentId] = Report(
                intentId: intentId,
                exemplarCount: own.count,
                sessionCount: sessionCount,
                looTop3HitRate: hitRate,
                isSuggestible: hitRate >= config.minLooHitRate,
                selfSimilarityFloor: stats.floor,
                typicalSelfSimilarity: stats.median
            )
        }
        return reports
    }

    /// Reports for every intent, served from `cache` when the exemplar id
    /// set is unchanged, recomputed via the fast path otherwise.
    static func reports(intentIds: [String],
                        index: [ExemplarVector],
                        now: Date = Date(),
                        config: Config = Config(),
                        cache: inout Cache) -> [String: Report] {
        let key = Cache.key(for: index)
        let intentsWithExemplars = Set(index.map(\.intentId))
        let toEvaluate = intentIds.filter { intentsWithExemplars.contains($0) }

        var evaluated: [String: Report]
        if cache.key == key, toEvaluate.allSatisfy({ cache.reports[$0] != nil }) {
            evaluated = cache.reports
        } else {
            evaluated = evaluateAll(intentIds: toEvaluate, index: index, now: now, config: config)
            cache = Cache(key: key, reports: evaluated)
        }

        var result: [String: Report] = [:]
        for intentId in intentIds {
            result[intentId] = evaluated[intentId] ?? .empty(intentId: intentId)
        }
        return result
    }

    /// Keeps `values` sorted descending with at most `limit` entries.
    private static func insert(_ value: Double, into values: inout [Double], limit: Int) {
        if values.count == limit, let last = values.last, value <= last { return }
        var position = values.count
        while position > 0, values[position - 1] < value {
            position -= 1
        }
        values.insert(value, at: position)
        if values.count > limit {
            values.removeLast()
        }
    }
}

/// Rows of the exemplar-by-exemplar cosine matrix, either materialized in
/// one `cblas_sgemm` call (A·Aᵀ over L2-normalized rows) or computed on
/// demand with `vDSP_mmul` when N is too large to hold N² floats.
struct SimilarityRows {
    let n: Int
    let dimension: Int
    /// n × dimension, row-major, every row L2-normalized.
    private let stacked: [Float]
    /// n × n, row-major, when materialized.
    private let matrix: [Float]?

    init(index: [ExemplarVector], dimension: Int, materialize: Bool) {
        self.n = index.count
        self.dimension = dimension
        var a: [Float] = []
        a.reserveCapacity(index.count * dimension)
        for exemplar in index {
            a.append(contentsOf: VectorMath.l2Normalized(exemplar.vector))
        }
        self.stacked = a
        self.matrix = materialize ? Self.gram(a, n: index.count, dimension: dimension) : nil
    }

    var isMaterialized: Bool { matrix != nil }

    /// C = A · Aᵀ for a row-major n × d matrix A.
    static func gram(_ a: [Float], n: Int, dimension: Int) -> [Float] {
        var c = [Float](repeating: 0, count: n * n)
        guard n > 0, dimension > 0 else { return c }
        a.withUnsafeBufferPointer { ap in
            c.withUnsafeMutableBufferPointer { cp in
                cblas_sgemm(
                    CblasRowMajor, CblasNoTrans, CblasTrans,
                    Int32(n), Int32(n), Int32(dimension),
                    1.0, ap.baseAddress, Int32(dimension),
                    ap.baseAddress, Int32(dimension),
                    0.0, cp.baseAddress, Int32(n)
                )
            }
        }
        return c
    }

    /// Writes row `i` (cosine of exemplar i with every exemplar) into
    /// `out`, which must have `n` elements.
    func fill(row i: Int, into out: inout [Float]) {
        precondition(out.count == n)
        if let matrix {
            let start = i * n
            out.withUnsafeMutableBufferPointer { op in
                matrix.withUnsafeBufferPointer { mp in
                    guard let dst = op.baseAddress, let src = mp.baseAddress else { return }
                    dst.update(from: src + start, count: n)
                }
            }
        } else {
            stacked.withUnsafeBufferPointer { ap in
                guard let base = ap.baseAddress else { return }
                let query = base + i * dimension
                out.withUnsafeMutableBufferPointer { op in
                    guard let dst = op.baseAddress else { return }
                    // C(n×1) = A(n×d) · q(d×1)
                    vDSP_mmul(base, 1, query, 1, dst, 1, vDSP_Length(n), 1, vDSP_Length(dimension))
                }
            }
        }
    }

    func row(_ i: Int) -> [Float] {
        var out = [Float](repeating: 0, count: n)
        fill(row: i, into: &out)
        return out
    }
}
