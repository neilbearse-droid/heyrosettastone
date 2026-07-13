import Foundation

/// Per-intent logistic calibration (§5.2): maps a raw ranking score to an
/// acceptance probability, fitted on that intent's own accept/reject
/// history. Negatives never move embeddings — they land here, so each word
/// learns its own distance threshold, and a wrong-and-rejected guess
/// measurably tightens it.
struct LogisticCalibrator: Equatable {
    var slope: Double
    var intercept: Double

    /// Uncalibrated default: p(0.5-score) = 0.5, gentle slope. Used until an
    /// intent has enough of its own history to fit.
    static let uncalibrated = LogisticCalibrator(slope: 4, intercept: -2)

    func probability(of score: Double) -> Double {
        1 / (1 + exp(-(slope * score + intercept)))
    }

    /// Gradient-descent fit with L2 pull toward the default parameters —
    /// the regularization keeps small or one-sided histories from producing
    /// runaway slopes (perfect separation), and makes the fit deterministic.
    /// Requires at least `minObservations` including one of each outcome;
    /// otherwise returns `.uncalibrated`.
    static func fit(observations: [(score: Double, accepted: Bool)],
                    minObservations: Int = 4,
                    iterations: Int = 600,
                    learningRate: Double = 0.5,
                    regularization: Double = 0.02) -> LogisticCalibrator {
        let accepts = observations.filter(\.accepted).count
        let rejects = observations.count - accepts
        guard observations.count >= minObservations, accepts > 0, rejects > 0 else {
            return .uncalibrated
        }

        var slope = uncalibrated.slope
        var intercept = uncalibrated.intercept
        let n = Double(observations.count)

        for _ in 0..<iterations {
            var gradSlope = 0.0
            var gradIntercept = 0.0
            for obs in observations {
                let p = 1 / (1 + exp(-(slope * obs.score + intercept)))
                let error = p - (obs.accepted ? 1 : 0)
                gradSlope += error * obs.score
                gradIntercept += error
            }
            gradSlope = gradSlope / n + regularization * (slope - uncalibrated.slope)
            gradIntercept = gradIntercept / n + regularization * (intercept - uncalibrated.intercept)
            slope -= learningRate * gradSlope
            intercept -= learningRate * gradIntercept
        }
        return LogisticCalibrator(slope: slope, intercept: intercept)
    }
}
