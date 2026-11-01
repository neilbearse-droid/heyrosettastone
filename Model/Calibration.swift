import Foundation

/// Versioning of the calibration feature. Observations are stored as the
/// feature the ranker produced at the time; when the feature's definition
/// changes, old observations are not comparable and must be ignored.
///
/// `CalibrationObservationRecord` has no version column (Data/ is not ours
/// to change), so the version is expressed as a timestamp cutoff:
/// observations stamped before `versionCutoff` were recorded on the v1
/// scale (raw cosine × prior, typically 0.80–0.95) and are skipped when
/// calibrators are fitted. If Data/ later adds a `featureVersion` column,
/// filter on that instead and drop the cutoff.
enum CalibrationFeature {
    /// v1: raw recency-weighted cosine × context prior.
    /// v2: standardized acoustic z from `IntentRanker` (prior NOT applied).
    static let version = 2
    /// 2026-11-01T00:00:00Z — when v2 shipped.
    static let versionCutoff = Date(timeIntervalSince1970: 1_793_491_200)

    static func isCurrent(_ observation: CalibrationObservationRecord) -> Bool {
        observation.timestamp >= versionCutoff
    }

    /// Features are z-scores; anything beyond ±20 is numerically
    /// meaningless and would only serve to overflow `exp`. NaN maps to 0.
    static func clamp(_ z: Double) -> Double {
        guard z.isFinite else { return z.isNaN ? 0 : (z > 0 ? 20 : -20) }
        return min(20, max(-20, z))
    }
}

/// Per-intent logistic calibration (§5.2): maps the standardized ranking
/// feature `z` to an acceptance probability, fitted on that intent's own
/// accept/reject history. Negatives never move embeddings — they land here,
/// so each word learns its own distance threshold, and a wrong-and-rejected
/// guess measurably tightens it.
///
/// Note on decay: the engine refits every calibrator on `reload()` from the
/// stored observations. Observations hold the z recorded at the time, which
/// was computed under the recency weights of that day; the z of the same
/// clip drifts slowly as the store ages. With the recency floor (weights
/// never drop below 0.25) that drift is bounded, and the standardization
/// removes most of it, so refitting on stored z is adequate for MVP.
struct LogisticCalibrator: Equatable {
    var slope: Double
    var intercept: Double

    /// Uncalibrated default on the z scale, used until an intent has enough
    /// of its own history. z is "standard deviations above the mean
    /// similarity of the index", and the best match in an index of N
    /// exemplars sits at roughly z ≈ 1.5-3 by construction (the maximum of
    /// N draws) whether or not the query is really that word, so the
    /// default must not hand three confidence dots to every leader. With
    /// slope 1 / intercept −1.5: p(0) ≈ 0.18 (a best match merely at the
    /// mean is probably wrong and falls under the engine's 0.15 floor
    /// below z ≈ −0.23), p(1.5) = 0.5 (a true match in a 15-exemplar
    /// index: two dots), p(3) ≈ 0.82 (a standout even in an index of
    /// hundreds: three dots).
    static let uncalibrated = LogisticCalibrator(slope: 1.0, intercept: -1.5)

    func probability(of z: Double) -> Double {
        let x = slope * CalibrationFeature.clamp(z) + intercept
        guard x.isFinite else { return x > 0 ? 1 : 0 }
        return 1 / (1 + exp(-min(40, max(-40, x))))
    }

    /// Gradient-descent fit. The slope is L2-regularized toward 0 (a small
    /// pull, so a perfectly separable history cannot run away, but nothing
    /// drags the fit back to an arbitrary default slope), and the intercept
    /// toward the uncalibrated intercept. Requires at least
    /// `minObservations` including one of each outcome; otherwise returns
    /// `.uncalibrated`.
    static func fit(observations: [(score: Double, accepted: Bool)],
                    minObservations: Int = 4,
                    iterations: Int = 600,
                    learningRate: Double = 0.5,
                    slopeRegularization: Double = 0.02,
                    interceptRegularization: Double = 0.02) -> LogisticCalibrator {
        let accepts = observations.filter(\.accepted).count
        let rejects = observations.count - accepts
        guard observations.count >= minObservations, accepts > 0, rejects > 0 else {
            return .uncalibrated
        }

        let clamped = observations.map { (z: CalibrationFeature.clamp($0.score), accepted: $0.accepted) }
        var slope = uncalibrated.slope
        var intercept = uncalibrated.intercept
        let n = Double(clamped.count)

        for _ in 0..<iterations {
            var gradSlope = 0.0
            var gradIntercept = 0.0
            for obs in clamped {
                let x = min(40, max(-40, slope * obs.z + intercept))
                let p = 1 / (1 + exp(-x))
                let error = p - (obs.accepted ? 1 : 0)
                gradSlope += error * obs.z
                gradIntercept += error
            }
            gradSlope = gradSlope / n + slopeRegularization * slope
            gradIntercept = gradIntercept / n + interceptRegularization * (intercept - uncalibrated.intercept)
            slope -= learningRate * gradSlope
            intercept -= learningRate * gradIntercept
            if !slope.isFinite || !intercept.isFinite {
                return .uncalibrated
            }
        }
        return LogisticCalibrator(slope: slope, intercept: intercept)
    }
}
