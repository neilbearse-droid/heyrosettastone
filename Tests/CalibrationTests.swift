import XCTest
@testable import Rosetta

/// §5.2: negatives fit a per-intent logistic so each word learns its own
/// threshold. Phase 2 acceptance: a wrong-and-rejected guess measurably
/// tightens that word's threshold.
final class CalibrationTests: XCTestCase {
    func testProbabilityIsMonotonicInScore() {
        let calibrator = LogisticCalibrator.fit(observations: [
            (0.2, false), (0.3, false), (0.7, true), (0.8, true),
        ])
        XCTAssertLessThan(calibrator.probability(of: 0.2), calibrator.probability(of: 0.5))
        XCTAssertLessThan(calibrator.probability(of: 0.5), calibrator.probability(of: 0.8))
    }

    func testRejectionTightensTheThreshold() {
        let base: [(Double, Bool)] = [
            (0.75, true), (0.8, true), (0.85, true),
            (0.3, false), (0.35, false),
        ]
        let before = LogisticCalibrator.fit(observations: base)

        // The model guessed this word at score 0.6 and the family said no —
        // twice. The same score must now earn a lower probability.
        let after = LogisticCalibrator.fit(observations: base + [(0.6, false), (0.62, false)])

        XCTAssertLessThan(
            after.probability(of: 0.6),
            before.probability(of: 0.6) - 0.02,
            "a rejected guess must measurably tighten the word's threshold"
        )
        // And high-confidence territory is affected far less.
        XCTAssertGreaterThan(after.probability(of: 0.9), 0.5)
    }

    func testAcceptancesLoosenTheThreshold() {
        let base: [(Double, Bool)] = [
            (0.8, true), (0.85, true),
            (0.3, false), (0.35, false),
        ]
        let before = LogisticCalibrator.fit(observations: base)
        let after = LogisticCalibrator.fit(observations: base + [(0.5, true), (0.55, true)])
        XCTAssertGreaterThan(after.probability(of: 0.5), before.probability(of: 0.5))
    }

    func testInsufficientOrOneSidedHistoryFallsBackToDefault() {
        XCTAssertEqual(LogisticCalibrator.fit(observations: []), .uncalibrated)
        XCTAssertEqual(LogisticCalibrator.fit(observations: [(0.9, true), (0.8, true)]), .uncalibrated)
        XCTAssertEqual(
            LogisticCalibrator.fit(observations: [(0.9, true), (0.8, true), (0.7, true), (0.6, true)]),
            .uncalibrated,
            "all-accept history cannot fit a slope; keep the default until a reject arrives"
        )
    }

    func testDefaultCalibratorIsSane() {
        let d = LogisticCalibrator.uncalibrated
        XCTAssertEqual(d.probability(of: 0.5), 0.5, accuracy: 0.01)
        XCTAssertGreaterThan(d.probability(of: 0.9), 0.7)
        XCTAssertLessThan(d.probability(of: 0.1), 0.3)
    }
}
