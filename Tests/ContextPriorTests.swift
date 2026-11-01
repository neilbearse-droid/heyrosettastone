import XCTest
@testable import Rosetta

/// §5.3: banana at 7am on the kitchen device should outrank banana at 9pm
/// in the bath — but the prior is cheap accuracy, not the decider: every
/// lift is clamped so routine can never outvote the acoustics by orders of
/// magnitude.
final class ContextPriorTests: XCTestCase {
    let now = Date(timeIntervalSinceReferenceDate: 4_000_000)
    let intents = ["banana", "water", "bath"]

    private func obs(_ intent: String, hour: Int, station: String, daysAgo: Double = 10) -> ContextPriors.Observation {
        ContextPriors.Observation(
            intentId: intent,
            hourOfDay: hour,
            station: station,
            timestamp: now.addingTimeInterval(-daysAgo * 86_400)
        )
    }

    func testNoHistoryMeansNeutralPrior() {
        let priors = ContextPriors(observations: [], intentIds: intents)
        let snapshot = ContextPriors.Snapshot(hourOfDay: 7, station: "Kitchen", now: now)
        for intent in intents {
            XCTAssertEqual(priors.prior(for: intent, context: snapshot), 1.0, accuracy: 0.0001,
                           "with no history the prior must not touch the ranking (§2.1)")
        }
    }

    func testMorningKitchenRoutineBoostsBanana() {
        var history: [ContextPriors.Observation] = []
        for _ in 0..<10 { history.append(obs("banana", hour: 7, station: "Kitchen")) }
        for _ in 0..<10 { history.append(obs("bath", hour: 19, station: "Bathroom")) }
        let priors = ContextPriors(observations: history, intentIds: intents)

        let morningKitchen = ContextPriors.Snapshot(hourOfDay: 7, station: "Kitchen", now: now)
        let eveningBath = ContextPriors.Snapshot(hourOfDay: 19, station: "Bathroom", now: now)

        XCTAssertGreaterThan(priors.prior(for: "banana", context: morningKitchen), 1.0)
        XCTAssertLessThan(priors.prior(for: "bath", context: morningKitchen), 1.0)
        XCTAssertGreaterThan(
            priors.prior(for: "banana", context: morningKitchen),
            priors.prior(for: "banana", context: eveningBath),
            "the same word must rank higher in its routine context"
        )
    }

    func testShortHorizonRecencyBoostsJustConfirmedIntent() {
        let recent = [ContextPriors.Observation(
            intentId: "water", hourOfDay: 12, station: "Kitchen",
            timestamp: now.addingTimeInterval(-5 * 60)
        )]
        let stale = [ContextPriors.Observation(
            intentId: "water", hourOfDay: 12, station: "Kitchen",
            timestamp: now.addingTimeInterval(-6 * 3600)
        )]
        let snapshot = ContextPriors.Snapshot(hourOfDay: 12, station: "Kitchen", now: now)

        let boosted = ContextPriors(observations: recent, intentIds: intents)
            .prior(for: "water", context: snapshot)
        let unboosted = ContextPriors(observations: stale, intentIds: intents)
            .prior(for: "water", context: snapshot)
        XCTAssertGreaterThan(boosted, unboosted,
                             "an intent confirmed minutes ago often repeats — it gets a short-lived boost")
    }

    func testPerConditionLiftIsClamped() {
        // 30 words; 100 confirmations in one bucket, every one of them
        // banana. Unclamped that would be ×5 per condition (×25 with the
        // station); clamped it is ×2 — and every other word is ×0.5, not
        // ×0.17. Station history is absent for the query station and the
        // last confirmation is a year old, so only the hour condition acts.
        let thirty = (0..<30).map { "word\($0)" } + ["banana"]
        var history: [ContextPriors.Observation] = []
        for _ in 0..<100 { history.append(obs("banana", hour: 7, station: "A", daysAgo: 365)) }
        let priors = ContextPriors(observations: history, intentIds: thirty)
        let snapshot = ContextPriors.Snapshot(hourOfDay: 7, station: "B", now: now)

        XCTAssertEqual(priors.prior(for: "banana", context: snapshot), 2.0, accuracy: 1e-6)
        XCTAssertEqual(priors.prior(for: "word3", context: snapshot), 0.5, accuracy: 1e-6)
    }

    func testCombinedMultiplierStaysBounded() {
        // Worst case for every term at once: hour, station and recency all
        // scream banana. The combined multiplier must stay within
        // [0.125, 8] (actually [0.25, 6] with the default config).
        let thirty = (0..<30).map { "word\($0)" } + ["banana"]
        var history: [ContextPriors.Observation] = []
        for _ in 0..<100 {
            history.append(ContextPriors.Observation(
                intentId: "banana", hourOfDay: 7, station: "Kitchen", timestamp: now
            ))
        }
        let priors = ContextPriors(observations: history, intentIds: thirty)
        let snapshot = ContextPriors.Snapshot(hourOfDay: 7, station: "Kitchen", now: now)

        let banana = priors.prior(for: "banana", context: snapshot)
        let other = priors.prior(for: "word7", context: snapshot)
        XCTAssertGreaterThan(banana, 1.0)
        XCTAssertLessThan(other, 1.0)
        XCTAssertLessThanOrEqual(banana, 8.0)
        XCTAssertGreaterThanOrEqual(other, 0.125)
        XCTAssertLessThanOrEqual(banana, priors.config.maximumMultiplier)
        XCTAssertGreaterThanOrEqual(other, priors.config.minimumMultiplier)
        XCTAssertLessThan(banana / other, 30, "routine context is a nudge, never two orders of magnitude")
    }

    func testObservationsAreBucketedOnCaptureHourNotConfirmHour() {
        // The engine builds observations from `capturedAt`. Here the
        // record is captured at 07:00 and confirmed at 20:00 — the
        // observation the engine derives must land in the morning bucket.
        var captured = DateComponents()
        captured.year = 2026; captured.month = 11; captured.day = 2; captured.hour = 7
        var confirmed = captured
        confirmed.hour = 20
        let capturedAt = Calendar.current.date(from: captured)!
        let confirmedAt = Calendar.current.date(from: confirmed)!
        let exemplar = ExemplarRecord(
            intentId: "banana", clipRef: "c", device: "Kitchen", labeller: "Mom",
            timestamp: confirmedAt, sessionId: "s", capturedAt: capturedAt
        )
        let observation = ContextPriors.Observation(
            intentId: exemplar.intentId,
            hourOfDay: Calendar.current.component(.hour, from: exemplar.capturedAt),
            station: exemplar.device,
            timestamp: exemplar.capturedAt
        )
        XCTAssertEqual(observation.hourOfDay, 7)
        XCTAssertEqual(observation.timestamp, capturedAt)

        let priors = ContextPriors(observations: [observation], intentIds: intents)
        let morning = ContextPriors.Snapshot(hourOfDay: 7, station: "Kitchen", now: capturedAt.addingTimeInterval(86_400))
        let evening = ContextPriors.Snapshot(hourOfDay: 20, station: "Kitchen", now: capturedAt.addingTimeInterval(86_400 + 13 * 3600))
        XCTAssertGreaterThan(priors.prior(for: "banana", context: morning), priors.prior(for: "banana", context: evening))
    }
}
