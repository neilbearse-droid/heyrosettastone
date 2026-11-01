import XCTest
@testable import Rosetta

/// §5.2: negatives fit a per-intent logistic so each word learns its own
/// threshold. Phase 2 acceptance: a wrong-and-rejected guess measurably
/// tightens that word's threshold. The feature is the ranker's
/// standardized score `z`, not a raw cosine: real encoder cosines live in
/// a ~0.1-wide band where a raw-score calibrator cannot learn anything.
final class CalibrationTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 6_000_000)

    func testProbabilityIsMonotonicInScore() {
        let calibrator = LogisticCalibrator.fit(observations: [
            (-1.0, false), (-0.5, false), (1.0, true), (1.5, true),
        ])
        XCTAssertLessThan(calibrator.probability(of: -1.0), calibrator.probability(of: 0.0))
        XCTAssertLessThan(calibrator.probability(of: 0.0), calibrator.probability(of: 1.5))
    }

    func testSeparatedHistoryOnTheZScaleIsLearned() {
        // Accepts around z ≈ +1.5, rejects around z ≈ −0.5 — the kind of
        // separation the standardized feature produces for a word the
        // model knows.
        let history: [(score: Double, accepted: Bool)] = [
            (1.3, true), (1.5, true), (1.7, true), (1.5, true),
            (-0.7, false), (-0.5, false), (-0.3, false), (-0.5, false),
        ]
        let calibrator = LogisticCalibrator.fit(observations: history)
        XCTAssertLessThan(calibrator.probability(of: -0.5), 0.3)
        XCTAssertGreaterThan(calibrator.probability(of: 1.5), 0.7)
    }

    func testRejectionTightensTheThreshold() {
        let base: [(score: Double, accepted: Bool)] = [
            (1.5, true), (2.0, true), (2.5, true),
            (-0.5, false), (-0.3, false),
        ]
        let before = LogisticCalibrator.fit(observations: base)

        // The model guessed this word at z ≈ 1.0 and the family said no —
        // twice. The same z must now earn a lower probability.
        let after = LogisticCalibrator.fit(observations: base + [(1.0, false), (1.1, false)])

        XCTAssertLessThan(
            after.probability(of: 1.0),
            before.probability(of: 1.0) - 0.02,
            "a rejected guess must measurably tighten the word's threshold"
        )
        // And high-confidence territory is affected far less.
        XCTAssertGreaterThan(after.probability(of: 2.5), 0.5)
    }

    func testAcceptancesLoosenTheThreshold() {
        let base: [(score: Double, accepted: Bool)] = [
            (2.0, true), (2.5, true),
            (-0.5, false), (-0.3, false),
        ]
        let before = LogisticCalibrator.fit(observations: base)
        let after = LogisticCalibrator.fit(observations: base + [(0.5, true), (0.6, true)])
        XCTAssertGreaterThan(after.probability(of: 0.5), before.probability(of: 0.5))
    }

    /// The realistic case: every cosine in the store sits between ~0.91 and
    /// ~1.0 (mean-pooled encoder states are anisotropic). Going through the
    /// ranker's standardization turns that sliver into separable z values;
    /// fitting on them discriminates where a raw-score fit could not.
    func testNarrowRawBandIsSeparableAfterStandardization() {
        // Everything shares a dominant direction (axis 0); the word
        // identity is a 0.3 lean on axis 1 / 2 / 3 plus a little noise.
        func clip(side: Int, noiseAxis: Int, noise: Float) -> [Float] {
            var v = [Float](repeating: 0, count: EmbeddingFixtures.dim)
            v[0] = 1
            v[side] = 0.3
            v[noiseAxis] = noise
            return VectorMath.l2Normalized(v)
        }
        var index: [ExemplarVector] = []
        for (intent, side) in [("banana", 1), ("water", 2), ("outside", 3)] {
            for i in 0..<5 {
                index.append(ExemplarVector(
                    exemplarId: "\(intent)\(i)", intentId: intent,
                    vector: clip(side: side, noiseAxis: 4 + (i % 4), noise: 0.05),
                    timestamp: now, decayExempt: false
                ))
            }
        }

        // The raw band really is narrow.
        var cosines: [Double] = []
        for a in index {
            for b in index where a.exemplarId != b.exemplarId {
                cosines.append(VectorMath.cosine(a.vector, b.vector))
            }
        }
        XCTAssertGreaterThan(cosines.min() ?? 0, 0.85)
        XCTAssertLessThan((cosines.max() ?? 1) - (cosines.min() ?? 0), 0.15)

        // Banana's z when he said banana (accept) vs when he said water
        // and banana was guessed anyway (reject).
        var history: [(score: Double, accepted: Bool)] = []
        var acceptZ: [Double] = []
        var rejectZ: [Double] = []
        for i in 0..<4 {
            let bananaQuery = clip(side: 1, noiseAxis: 4 + i, noise: 0.08)
            let waterQuery = clip(side: 2, noiseAxis: 4 + i, noise: 0.08)
            let whenBanana = IntentRanker.rank(query: bananaQuery, exemplars: index, now: now)
                .first { $0.intentId == "banana" }!
            let whenWater = IntentRanker.rank(query: waterQuery, exemplars: index, now: now)
                .first { $0.intentId == "banana" }!
            history.append((whenBanana.z, true))
            history.append((whenWater.z, false))
            acceptZ.append(whenBanana.z)
            rejectZ.append(whenWater.z)
        }
        XCTAssertGreaterThan(acceptZ.min()!, rejectZ.max()! + 1.0,
                             "standardization must open a gap the raw band never had")

        let calibrator = LogisticCalibrator.fit(observations: history)
        let meanAccept = acceptZ.reduce(0, +) / Double(acceptZ.count)
        let meanReject = rejectZ.reduce(0, +) / Double(rejectZ.count)
        XCTAssertLessThan(calibrator.probability(of: meanReject), 0.3)
        XCTAssertGreaterThan(calibrator.probability(of: meanAccept), 0.7)
    }

    func testInsufficientOrOneSidedHistoryFallsBackToDefault() {
        XCTAssertEqual(LogisticCalibrator.fit(observations: []), .uncalibrated)
        XCTAssertEqual(LogisticCalibrator.fit(observations: [(1.9, true), (1.8, true)]), .uncalibrated)
        XCTAssertEqual(
            LogisticCalibrator.fit(observations: [(1.9, true), (1.8, true), (1.7, true), (1.6, true)]),
            .uncalibrated,
            "all-accept history cannot fit a slope; keep the default until a reject arrives"
        )
    }

    func testDefaultCalibratorIsSane() {
        let d = LogisticCalibrator.uncalibrated
        XCTAssertEqual(d.probability(of: 0), 0.27, accuracy: 0.02, "a match merely at the mean is probably wrong")
        XCTAssertGreaterThan(d.probability(of: 2), 0.85)
        XCTAssertLessThan(d.probability(of: -0.5), 0.16)
        XCTAssertLessThan(d.probability(of: -1.3), 0.06, "well below the mean falls under the engine's floor")
        XCTAssertGreaterThan(d.probability(of: 1.5), 0.75)
    }

    func testExtremeInputsStayFinite() {
        let wild = LogisticCalibrator.fit(observations: [
            (1e6, true), (-1e6, false), (50, true), (-50, false), (Double.infinity, true), (-Double.infinity, false),
        ])
        XCTAssertTrue(wild.slope.isFinite)
        XCTAssertTrue(wild.intercept.isFinite)
        XCTAssertTrue(wild.probability(of: 1e9).isFinite)
        XCTAssertTrue(wild.probability(of: -1e9).isFinite)
        XCTAssertTrue(wild.probability(of: .infinity).isFinite)
        XCTAssertTrue(wild.probability(of: .nan).isFinite)
        XCTAssertGreaterThan(wild.probability(of: 50), wild.probability(of: -50))

        let withNaN = LogisticCalibrator.fit(observations: [
            (Double.nan, true), (1.0, true), (-1.0, false), (-0.5, false),
        ])
        XCTAssertTrue(withNaN.slope.isFinite)
        XCTAssertTrue(withNaN.intercept.isFinite)
    }

    func testFeatureVersionCutoffIgnoresOldObservations() {
        let old = CalibrationObservationRecord(
            intentId: "x", score: 0.9, accepted: true,
            timestamp: CalibrationFeature.versionCutoff.addingTimeInterval(-1)
        )
        let current = CalibrationObservationRecord(
            intentId: "x", score: 1.2, accepted: true,
            timestamp: CalibrationFeature.versionCutoff
        )
        XCTAssertFalse(CalibrationFeature.isCurrent(old))
        XCTAssertTrue(CalibrationFeature.isCurrent(current))
    }
}
