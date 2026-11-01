import XCTest
@testable import Rosetta

/// Fixture embeddings: unit basis vectors with deterministic mixing, so
/// similarity structure is exact and tests never touch a real encoder.
enum EmbeddingFixtures {
    static let dim = 8

    static func axis(_ i: Int) -> [Float] {
        var v = [Float](repeating: 0, count: dim)
        v[i % dim] = 1
        return v
    }

    /// A vector mostly along `axis`, leaning `lean` toward `towardAxis` —
    /// cosine to axis(axis) is exactly 1/sqrt(1+lean²).
    static func near(_ axisIndex: Int, leaning towardAxis: Int = 0, by lean: Float = 0.15) -> [Float] {
        var v = axis(axisIndex)
        if towardAxis != axisIndex {
            v[towardAxis % dim] = lean
        }
        return VectorMath.l2Normalized(v)
    }

    /// Arbitrary mixture, L2-normalized. Indices beyond `dim` are ignored.
    static func mix(_ components: [Float]) -> [Float] {
        var v = [Float](repeating: 0, count: dim)
        for (i, c) in components.enumerated() where i < dim {
            v[i] = c
        }
        return VectorMath.l2Normalized(v)
    }
}

/// §10: kNN with recency weighting against fixture embeddings.
final class RankingTests: XCTestCase {
    let now = Date(timeIntervalSinceReferenceDate: 3_000_000)

    private func vec(_ id: String, intent: String, _ vector: [Float],
                     ageDays: Double = 0, exempt: Bool = false) -> ExemplarVector {
        ExemplarVector(
            exemplarId: id,
            intentId: intent,
            vector: vector,
            timestamp: now.addingTimeInterval(-ageDays * 86_400),
            decayExempt: exempt
        )
    }

    func testEmbeddingCodecRoundTrip() {
        let vector: [Float] = [0.25, -1.5, 3.14159, 0, 42]
        XCTAssertEqual(EmbeddingCodec.decode(EmbeddingCodec.encode(vector)), vector)
    }

    func testNearestClusterWins() {
        let index = [
            vec("b1", intent: "banana", EmbeddingFixtures.near(0, leaning: 3, by: 0.1)),
            vec("b2", intent: "banana", EmbeddingFixtures.near(0, leaning: 4, by: 0.1)),
            vec("w1", intent: "water", EmbeddingFixtures.near(1, leaning: 3, by: 0.1)),
            vec("w2", intent: "water", EmbeddingFixtures.near(1, leaning: 4, by: 0.1)),
        ]
        let ranked = IntentRanker.rank(query: EmbeddingFixtures.near(0, leaning: 5, by: 0.05),
                                       exemplars: index, now: now)
        XCTAssertEqual(ranked.first?.intentId, "banana")
        XCTAssertGreaterThan(ranked.first?.z ?? 0, 0, "the winner sits above the mean similarity of the index")
    }

    func testMultimodalClassIsHandledByExemplarKNN() {
        // §5.2: banana is said two distinct ways (axis 0 and axis 2). A
        // class prototype would average to a vector near neither; exemplar
        // kNN must still recognize the second way.
        let index = [
            vec("b1", intent: "banana", EmbeddingFixtures.axis(0)),
            vec("b2", intent: "banana", EmbeddingFixtures.near(0, leaning: 4, by: 0.1)),
            vec("b3", intent: "banana", EmbeddingFixtures.axis(2)),
            vec("b4", intent: "banana", EmbeddingFixtures.near(2, leaning: 5, by: 0.1)),
            vec("w1", intent: "water", EmbeddingFixtures.axis(1)),
            vec("w2", intent: "water", EmbeddingFixtures.near(1, leaning: 4, by: 0.1)),
        ]
        let secondWayQuery = EmbeddingFixtures.near(2, leaning: 6, by: 0.08)
        let ranked = IntentRanker.rank(query: secondWayQuery, exemplars: index, now: now)
        XCTAssertEqual(ranked.first?.intentId, "banana")

        // Sanity: the prototype (mean of banana's exemplars) really is far
        // from the query — averaging would have destroyed the class.
        let prototype = VectorMath.meanPooled(index.filter { $0.intentId == "banana" }.map(\.vector))!
        let protoSim = VectorMath.cosine(secondWayQuery, prototype)
        let bestExemplarSim = index.filter { $0.intentId == "banana" }
            .map { VectorMath.cosine(secondWayQuery, $0.vector) }.max()!
        XCTAssertLessThan(protoSim, bestExemplarSim - 0.2)
    }

    func testRecencyWeightingPrefersFreshEvidence() {
        // The old exemplar matches slightly BETTER raw, but it is two
        // half-lives stale (weight 0.25 + 0.75·0.25 ≈ 0.44) — the fresh
        // intent must win.
        let query = EmbeddingFixtures.axis(0)
        let staleButCloser = vec("old", intent: "oldWord",
                                 EmbeddingFixtures.near(0, leaning: 1, by: 0.05), ageDays: 180)
        let freshButFarther = vec("new", intent: "newWord",
                                  EmbeddingFixtures.near(0, leaning: 1, by: 0.30), ageDays: 1)

        let ranked = IntentRanker.rank(query: query, exemplars: [staleButCloser, freshButFarther], now: now)
        XCTAssertEqual(ranked.first?.intentId, "newWord")

        // Without the age difference the closer one wins — proving the
        // flip above came from recency weighting alone.
        let sameAge = IntentRanker.rank(
            query: query,
            exemplars: [
                vec("old2", intent: "oldWord", EmbeddingFixtures.near(0, leaning: 1, by: 0.05), ageDays: 1),
                vec("new2", intent: "newWord", EmbeddingFixtures.near(0, leaning: 1, by: 0.30), ageDays: 1),
            ],
            now: now
        )
        XCTAssertEqual(sameAge.first?.intentId, "oldWord")
    }

    func testRecencyWeightIsFlooredNeverZero() {
        // §5.4: old evidence fades, it does not vanish. Ten half-lives out
        // the weight sits at the floor, not at ~0.001.
        let ancient = now.addingTimeInterval(-900 * 86_400)
        let weight = IntentRanker.recencyWeight(timestamp: ancient, decayExempt: false, now: now, halfLifeDays: 90)
        XCTAssertGreaterThanOrEqual(weight, 0.25)
        XCTAssertLessThan(weight, 0.26)

        let fresh = IntentRanker.recencyWeight(timestamp: now, decayExempt: false, now: now, halfLifeDays: 90)
        XCTAssertEqual(fresh, 1.0, accuracy: 1e-9)

        let oneHalfLife = IntentRanker.recencyWeight(
            timestamp: now.addingTimeInterval(-90 * 86_400), decayExempt: false, now: now, halfLifeDays: 90
        )
        XCTAssertEqual(oneHalfLife, 0.25 + 0.75 * 0.5, accuracy: 1e-9)
    }

    func testDecayExemptExemplarNeverFades() {
        let query = EmbeddingFixtures.axis(0)
        let ranked = IntentRanker.rank(
            query: query,
            exemplars: [
                vec("kept", intent: "keptWord",
                    EmbeddingFixtures.near(0, leaning: 1, by: 0.05), ageDays: 720, exempt: true),
                vec("new", intent: "newWord",
                    EmbeddingFixtures.near(0, leaning: 1, by: 0.30), ageDays: 1),
            ],
            now: now
        )
        XCTAssertEqual(ranked.first?.intentId, "keptWord",
                       "decay-exempt exemplars keep full influence regardless of age")
    }

    func testEveryIntentIsScoredOnItsOwnNeighbours() {
        // Four excellent water exemplars and one weaker banana. Scoring is
        // per intent, so banana still gets a score — it just ranks below
        // water. (Previously a global top-k let water's four exemplars
        // crowd banana out entirely, which made "top-3" top-1.)
        var index = (0..<4).map { i in
            vec("w\(i)", intent: "water", EmbeddingFixtures.near(0, leaning: 1 + i, by: 0.05))
        }
        index.append(vec("b1", intent: "banana", EmbeddingFixtures.near(0, leaning: 5, by: 0.9)))

        let ranked = IntentRanker.rank(query: EmbeddingFixtures.axis(0), exemplars: index, now: now)
        XCTAssertEqual(ranked.map(\.intentId), ["water", "banana"])
        XCTAssertGreaterThan(ranked[0].z, ranked[1].z)
        XCTAssertEqual(ranked[0].neighbourCount, 4)
        XCTAssertEqual(ranked[1].neighbourCount, 1)
    }

    func testDismissingTheTopIntentYieldsTheNext() {
        var index = (0..<4).map { i in
            vec("w\(i)", intent: "water", EmbeddingFixtures.near(0, leaning: 1 + i, by: 0.05))
        }
        index.append(vec("b1", intent: "banana", EmbeddingFixtures.near(0, leaning: 5, by: 0.9)))
        index.append(vec("o1", intent: "outside", EmbeddingFixtures.axis(6)))

        let afterNo = IntentRanker.rank(
            query: EmbeddingFixtures.axis(0), exemplars: index, excluding: ["water"], now: now
        )
        XCTAssertEqual(afterNo.first?.intentId, "banana")
        XCTAssertFalse(afterNo.contains { $0.intentId == "water" })
        // Standardization is over the remaining index only, so banana is
        // now the clear best match rather than the runner-up.
        XCTAssertGreaterThan(afterNo.first?.z ?? -1, 0)
    }

    func testMixedDimensionVectorsAreDropped() {
        var wide = [Float](repeating: 0, count: 16)
        wide[0] = 1
        let index = [
            vec("b1", intent: "banana", EmbeddingFixtures.axis(0)),
            vec("w1", intent: "water", wide),
        ]
        let narrowQuery = IntentRanker.rank(query: EmbeddingFixtures.axis(0), exemplars: index, now: now)
        XCTAssertEqual(narrowQuery.map(\.intentId), ["banana"],
                       "a 16-dim exemplar cannot vote on an 8-dim query")

        let wideQuery = IntentRanker.rank(query: wide, exemplars: index, now: now)
        XCTAssertEqual(wideQuery.map(\.intentId), ["water"])
    }

    func testAllZeroSimilaritiesYieldNoSuggestions() {
        let index = [
            vec("w1", intent: "water", EmbeddingFixtures.axis(1)),
            vec("o1", intent: "outside", EmbeddingFixtures.axis(2)),
        ]
        let ranked = IntentRanker.rank(query: EmbeddingFixtures.axis(0), exemplars: index, now: now)
        XCTAssertTrue(ranked.isEmpty, "orthogonal exemplars must not produce a confident-looking guess")
    }

    func testStandardizedFeatureMatchesDefinition() {
        // Two exemplars: one identical to the query (sim 1), one orthogonal
        // (sim 0). Mean 0.5, std 0.5 → the match sits exactly one std above.
        let index = [
            vec("b1", intent: "banana", EmbeddingFixtures.axis(0)),
            vec("w1", intent: "water", EmbeddingFixtures.axis(1)),
        ]
        let ranking = IntentRanker.rankDetailed(query: EmbeddingFixtures.axis(0), exemplars: index, now: now)
        XCTAssertEqual(ranking.meanSimilarity, 0.5, accuracy: 1e-6)
        XCTAssertEqual(ranking.stdSimilarity, 0.5, accuracy: 1e-6)
        XCTAssertEqual(ranking.intents.count, 1)
        XCTAssertEqual(ranking.intents[0].z, 1.0, accuracy: 1e-6)
        XCTAssertEqual(ranking.z(forWeightedSimilarity: 0), -1.0, accuracy: 1e-6)
    }

    func testEmptyInputsRankNothing() {
        XCTAssertTrue(IntentRanker.rank(query: [], exemplars: []).isEmpty)
        XCTAssertTrue(IntentRanker.rank(query: EmbeddingFixtures.axis(0), exemplars: []).isEmpty)
    }
}
