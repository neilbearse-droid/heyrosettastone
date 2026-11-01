import XCTest
@testable import Rosetta

/// §5.6: suggestible = at least 5 confirmed exemplars from at least 3
/// distinct exchange sessions AND leave-one-session-out top-3 hit rate
/// over the threshold. Words the model half-knows stay off the guess list,
/// and one exchange's five near-identical chips do not count as knowing.
final class MaturityGateTests: XCTestCase {
    let now = Date(timeIntervalSinceReferenceDate: 5_000_000)

    private func vec(_ id: String, intent: String, _ vector: [Float], session: String? = nil) -> ExemplarVector {
        ExemplarVector(
            exemplarId: id, intentId: intent, vector: vector,
            timestamp: now, decayExempt: false, sessionId: session
        )
    }

    /// A tight cluster of n exemplars around an axis, each its own session.
    private func cluster(intent: String, axis: Int, count: Int, prefix: String) -> [ExemplarVector] {
        (0..<count).map { i in
            vec("\(prefix)\(i)", intent: intent,
                EmbeddingFixtures.near(axis, leaning: (axis + i + 1) % EmbeddingFixtures.dim, by: 0.08))
        }
    }

    func testTooFewExemplarsIsNotSuggestible() {
        let index = cluster(intent: "banana", axis: 0, count: 4, prefix: "b")
        let report = MaturityGate.evaluate(intentId: "banana", index: index, now: now)
        XCTAssertEqual(report.exemplarCount, 4)
        XCTAssertNil(report.looTop3HitRate)
        XCTAssertFalse(report.isSuggestible)
    }

    func testTightClusterPassesTheGate() {
        var index = cluster(intent: "banana", axis: 0, count: 6, prefix: "b")
        index += cluster(intent: "water", axis: 1, count: 5, prefix: "w")
        index += cluster(intent: "outside", axis: 2, count: 5, prefix: "o")

        let report = MaturityGate.evaluate(intentId: "banana", index: index, now: now)
        XCTAssertEqual(report.exemplarCount, 6)
        XCTAssertEqual(report.sessionCount, 6, "no session id → each exemplar is its own session")
        XCTAssertGreaterThanOrEqual(report.looTop3HitRate ?? 0, 0.7)
        XCTAssertTrue(report.isSuggestible)
    }

    func testScatteredClassFailsTheGate() {
        // "noise" has 5 exemplars, each sitting exactly inside a DIFFERENT
        // intent's tight cluster. Every leave-one-out query lands among
        // that other intent's exemplars, so noise never makes its own top-3.
        var index: [ExemplarVector] = []
        let owners = ["banana", "water", "outside", "bath", "help"]
        for (i, owner) in owners.enumerated() {
            index += cluster(intent: owner, axis: i, count: 5, prefix: "\(owner)-")
            index.append(vec("noise\(i)", intent: "noise", EmbeddingFixtures.axis(i)))
        }

        let report = MaturityGate.evaluate(intentId: "noise", index: index, now: now)
        XCTAssertEqual(report.exemplarCount, 5)
        XCTAssertLessThan(report.looTop3HitRate ?? 1, 0.7)
        XCTAssertFalse(report.isSuggestible)

        // The owners themselves are unharmed by the noise word.
        let banana = MaturityGate.evaluate(intentId: "banana", index: index, now: now)
        XCTAssertTrue(banana.isSuggestible)
    }

    func testOneExchangeOfNearIdenticalChipsDoesNotMature() {
        // Five chips from ONE exchange: the same utterance seconds apart.
        // Plain leave-one-out would score 1.0 because the siblings remain;
        // leave-one-session-out and the session minimum both say no.
        var index = (0..<5).map { i in
            vec("b\(i)", intent: "banana", EmbeddingFixtures.near(0, leaning: 5, by: 0.02 * Float(i)), session: "exchange-1")
        }
        index += cluster(intent: "water", axis: 1, count: 5, prefix: "w")
        index += cluster(intent: "outside", axis: 2, count: 5, prefix: "o")

        let report = MaturityGate.evaluate(intentId: "banana", index: index, now: now)
        XCTAssertEqual(report.exemplarCount, 5)
        XCTAssertEqual(report.sessionCount, 1)
        XCTAssertNil(report.looTop3HitRate)
        XCTAssertFalse(report.isSuggestible, "a word is not known after a single confirmation")
    }

    func testSameChipsAcrossThreeExchangesCanMature() {
        var index = (0..<5).map { i in
            vec("b\(i)", intent: "banana", EmbeddingFixtures.near(0, leaning: 5, by: 0.02 * Float(i)),
                session: ["s1", "s1", "s2", "s2", "s3"][i])
        }
        index += cluster(intent: "water", axis: 1, count: 5, prefix: "w")
        index += cluster(intent: "outside", axis: 2, count: 5, prefix: "o")

        let report = MaturityGate.evaluate(intentId: "banana", index: index, now: now)
        XCTAssertEqual(report.sessionCount, 3)
        XCTAssertGreaterThanOrEqual(report.looTop3HitRate ?? 0, 0.7)
        XCTAssertTrue(report.isSuggestible)
    }

    func testHoldingOutASessionRemovesItsSiblings() {
        // Two sessions only, so the session minimum fails; lower it to 2 to
        // isolate the hold-out behaviour. Each session is one distinct way
        // of saying the word; with the whole session removed, the held-out
        // query finds only the OTHER way, which is orthogonal → miss.
        var config = MaturityGate.Config()
        config.minSessions = 2
        config.minExemplars = 4
        // Exact axis vectors so every cross-session similarity is exactly 0
        // and nothing survives the "drop non-positive neighbours" rule.
        var index: [ExemplarVector] = []
        for i in 0..<3 { index.append(vec("a\(i)", intent: "banana", EmbeddingFixtures.axis(0), session: "A")) }
        for i in 0..<3 { index.append(vec("b\(i)", intent: "banana", EmbeddingFixtures.axis(1), session: "B")) }
        index += cluster(intent: "water", axis: 2, count: 5, prefix: "w")

        let report = MaturityGate.evaluate(intentId: "banana", index: index, now: now, config: config)
        XCTAssertEqual(report.looTop3HitRate ?? 1, 0, accuracy: 1e-9,
                       "with its own session held out, nothing of banana remains near the query")
        XCTAssertFalse(report.isSuggestible)
    }

    // MARK: - Fast path

    /// A messy, deterministic index: several intents with varying cluster
    /// tightness, sessions of 1–3 chips, a scattered word, and some stale
    /// exemplars so recency weighting matters.
    private func messyIndex() -> [ExemplarVector] {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func random() -> Float {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float((seed >> 33) % 10_000) / 10_000
        }
        var index: [ExemplarVector] = []
        let intents = ["banana", "water", "outside", "bath", "help", "more"]
        for (axis, intent) in intents.enumerated() {
            let count = 7 + axis
            for i in 0..<count {
                var v = EmbeddingFixtures.axis(axis)
                v[(axis + 1 + i) % EmbeddingFixtures.dim] = 0.05 + 0.6 * random()
                v[(axis + 3 + i) % EmbeddingFixtures.dim] = 0.3 * random()
                let session = "\(intent)-s\(i / 2)"
                let age = Double(Int(random() * 400))
                index.append(ExemplarVector(
                    exemplarId: "\(intent)\(i)", intentId: intent,
                    vector: VectorMath.l2Normalized(v),
                    timestamp: now.addingTimeInterval(-age * 86_400),
                    decayExempt: i % 5 == 0,
                    sessionId: session
                ))
            }
        }
        for i in 0..<6 {
            index.append(vec("noise\(i)", intent: "noise", EmbeddingFixtures.axis(i), session: "noise-s\(i)"))
        }
        return index
    }

    private func assertSameReports(_ fast: [String: MaturityGate.Report], index: [ExemplarVector],
                                   config: MaturityGate.Config, file: StaticString = #filePath, line: UInt = #line) {
        let intents = Array(Set(index.map(\.intentId))).sorted()
        for intent in intents {
            let reference = MaturityGate.evaluate(intentId: intent, index: index, now: now, config: config)
            guard let quick = fast[intent] else {
                XCTFail("missing fast report for \(intent)", file: file, line: line)
                continue
            }
            XCTAssertEqual(quick.exemplarCount, reference.exemplarCount, "\(intent) count", file: file, line: line)
            XCTAssertEqual(quick.sessionCount, reference.sessionCount, "\(intent) sessions", file: file, line: line)
            XCTAssertEqual(quick.isSuggestible, reference.isSuggestible, "\(intent) suggestible", file: file, line: line)
            switch (quick.looTop3HitRate, reference.looTop3HitRate) {
            case let (q?, r?):
                XCTAssertEqual(q, r, accuracy: 1e-9, "\(intent) hit rate", file: file, line: line)
            case (nil, nil):
                break
            default:
                XCTFail("\(intent): hit rate presence differs (fast \(String(describing: quick.looTop3HitRate)), reference \(String(describing: reference.looTop3HitRate)))", file: file, line: line)
            }
            // The fast path reads Float cosines from the Gram matrix, the
            // reference computes Double cosines per pair: agree to 1e-4.
            switch (quick.selfSimilarityFloor, reference.selfSimilarityFloor) {
            case let (q?, r?):
                XCTAssertEqual(q, r, accuracy: 1e-4, "\(intent) self-similarity floor", file: file, line: line)
            case (nil, nil):
                break
            default:
                XCTFail("\(intent): floor presence differs", file: file, line: line)
            }
            switch (quick.typicalSelfSimilarity, reference.typicalSelfSimilarity) {
            case let (q?, r?):
                XCTAssertEqual(q, r, accuracy: 1e-4, "\(intent) typical self-similarity", file: file, line: line)
            case (nil, nil):
                break
            default:
                XCTFail("\(intent): typical self-similarity presence differs", file: file, line: line)
            }
        }
    }

    func testSelfSimilarityFloorComesFromCrossSessionMatches() {
        // Six banana clips, each its own session, each leaning a different
        // way by 0.08: every cross-session best match is exactly
        // 1/(1+0.08²). Floor = that minus the tolerance; median = that.
        var index = cluster(intent: "banana", axis: 0, count: 6, prefix: "b")
        index += cluster(intent: "water", axis: 1, count: 5, prefix: "w")
        let config = MaturityGate.Config()
        let expected = 1.0 / (1.0 + 0.08 * 0.08)

        let report = MaturityGate.evaluate(intentId: "banana", index: index, now: now, config: config)
        XCTAssertEqual(report.typicalSelfSimilarity ?? .nan, expected, accuracy: 1e-6)
        XCTAssertEqual(report.selfSimilarityFloor ?? .nan, expected - config.selfSimilarityTolerance, accuracy: 1e-6)

        // Not evaluable → no floor (nothing to guard; the word is not
        // suggestible anyway).
        let few = MaturityGate.evaluate(intentId: "banana", index: Array(index.prefix(3)), now: now, config: config)
        XCTAssertNil(few.selfSimilarityFloor)
        XCTAssertNil(few.typicalSelfSimilarity)

        // Siblings in the same session never count as a match: one chip
        // per session held out against itself would give 1.0.
        let oneExchange = (0..<5).map { i in
            vec("same\(i)", intent: "same", EmbeddingFixtures.near(2, leaning: 3, by: 0.1), session: "s0")
        }
        let twoMore = [
            vec("same5", intent: "same", EmbeddingFixtures.near(2, leaning: 4, by: 0.1), session: "s1"),
            vec("same6", intent: "same", EmbeddingFixtures.near(2, leaning: 5, by: 0.1), session: "s2"),
        ]
        let same = MaturityGate.evaluate(intentId: "same", index: index + oneExchange + twoMore, now: now, config: config)
        XCTAssertLessThan(same.typicalSelfSimilarity ?? 1, 1.0,
                          "identical chips of one exchange are not evidence of self-similarity")
    }

    func testQuantileInterpolates() {
        XCTAssertEqual(MaturityGate.quantile([1, 2, 3, 4], 0.5), 2.5, accuracy: 1e-12)
        XCTAssertEqual(MaturityGate.quantile([1, 2, 3, 4], 0), 1, accuracy: 1e-12)
        XCTAssertEqual(MaturityGate.quantile([1, 2, 3, 4], 1), 4, accuracy: 1e-12)
        XCTAssertEqual(MaturityGate.quantile([7], 0.3), 7, accuracy: 1e-12)
        XCTAssertEqual(MaturityGate.quantile([], 0.3), 0, accuracy: 1e-12)
    }

    func testFastPathMatchesReferenceImplementation() {
        let index = messyIndex()
        let intents = Array(Set(index.map(\.intentId))).sorted()
        let config = MaturityGate.Config()

        let fast = MaturityGate.evaluateAll(intentIds: intents, index: index, now: now, config: config)
        assertSameReports(fast, index: index, config: config)
        XCTAssertTrue(fast.values.contains { $0.isSuggestible }, "fixture should contain at least one mature word")
        XCTAssertTrue(fast.values.contains { !$0.isSuggestible }, "fixture should contain at least one immature word")
    }

    func testRowAtATimeFallbackMatchesReference() {
        let index = messyIndex()
        let intents = Array(Set(index.map(\.intentId))).sorted()
        var config = MaturityGate.Config()
        config.matrixLimit = 0 // force the memory-guard path

        let fast = MaturityGate.evaluateAll(intentIds: intents, index: index, now: now, config: config)
        assertSameReports(fast, index: index, config: config)
    }

    func testSimilarityRowsMatchCosine() {
        let index = messyIndex()
        let materialized = SimilarityRows(index: index, dimension: EmbeddingFixtures.dim, materialize: true)
        let onDemand = SimilarityRows(index: index, dimension: EmbeddingFixtures.dim, materialize: false)
        XCTAssertTrue(materialized.isMaterialized)
        XCTAssertFalse(onDemand.isMaterialized)
        for i in stride(from: 0, to: index.count, by: 7) {
            let fromMatrix = materialized.row(i)
            let fromMmul = onDemand.row(i)
            for j in 0..<index.count {
                let expected = Float(VectorMath.cosine(index[i].vector, index[j].vector))
                XCTAssertEqual(fromMatrix[j], expected, accuracy: 1e-5)
                XCTAssertEqual(fromMmul[j], expected, accuracy: 1e-5)
            }
        }
    }

    func testMixedDimensionIndexFallsBackSafely() {
        var index = cluster(intent: "banana", axis: 0, count: 6, prefix: "b")
        index += cluster(intent: "water", axis: 1, count: 5, prefix: "w")
        var wide = [Float](repeating: 0, count: 16)
        wide[0] = 1
        index.append(vec("odd", intent: "banana", wide))

        let fast = MaturityGate.evaluateAll(intentIds: ["banana", "water"], index: index, now: now)
        let reference = MaturityGate.evaluate(intentId: "banana", index: index, now: now)
        XCTAssertEqual(fast["banana"]?.exemplarCount, reference.exemplarCount)
        XCTAssertEqual(fast["banana"]?.isSuggestible, reference.isSuggestible)
    }

    func testReportsAreCachedOnTheExemplarIdSet() {
        var index = cluster(intent: "banana", axis: 0, count: 6, prefix: "b")
        index += cluster(intent: "water", axis: 1, count: 5, prefix: "w")
        var cache = MaturityGate.Cache()

        let first = MaturityGate.reports(intentIds: ["banana", "water", "unseen"], index: index, now: now, cache: &cache)
        XCTAssertEqual(cache.key, MaturityGate.Cache.key(for: index))
        XCTAssertTrue(first["banana"]?.isSuggestible ?? false)
        XCTAssertEqual(first["unseen"]?.exemplarCount, 0)
        XCTAssertFalse(first["unseen"]?.isSuggestible ?? true)

        // Same index → same key, cache reused (the key is unchanged and the
        // cached reports still answer every intent that has exemplars).
        let keyBefore = cache.key
        _ = MaturityGate.reports(intentIds: ["banana", "water"], index: index, now: now, cache: &cache)
        XCTAssertEqual(cache.key, keyBefore)

        // A pruned exemplar changes the key and the reports.
        index.removeLast()
        let after = MaturityGate.reports(intentIds: ["banana", "water"], index: index, now: now, cache: &cache)
        XCTAssertNotEqual(cache.key, keyBefore)
        XCTAssertEqual(after["water"]?.exemplarCount, 4)
        XCTAssertFalse(after["water"]?.isSuggestible ?? true)
    }
}
