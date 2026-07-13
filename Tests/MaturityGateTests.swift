import XCTest
@testable import Rosetta

/// §5.6: suggestible = at least 5 confirmed exemplars AND leave-one-out
/// top-3 hit rate over the threshold. Words the model half-knows stay off
/// the guess list.
final class MaturityGateTests: XCTestCase {
    let now = Date(timeIntervalSinceReferenceDate: 5_000_000)

    private func vec(_ id: String, intent: String, _ vector: [Float]) -> ExemplarVector {
        ExemplarVector(exemplarId: id, intentId: intent, vector: vector, timestamp: now, decayExempt: false)
    }

    /// A tight cluster of n exemplars around an axis.
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
}
