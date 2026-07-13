import XCTest
@testable import Rosetta

/// §5.3: banana at 7am on the kitchen device should outrank banana at 9pm
/// in the bath.
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
}
