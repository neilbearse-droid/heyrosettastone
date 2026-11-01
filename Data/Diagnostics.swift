import Foundation
import GRDB

/// The Phase 2 acceptance criterion (§9: mature words hit ≥ 70 % top-3 on
/// held-out confirmations), measured on what actually happened in the
/// kitchen rather than on leave-one-out. Pure read over two tables:
///
/// - `calibrationObservations` rows carry (v4) the exchange a guess was
///   shown in and the score it was shown with; one exchange's rows are the
///   guesses that were on screen at its yes moment (plus any dismissed
///   earlier in it).
/// - `events` rows of type confirm say which word the family chose.
///
/// Only exchanges with both — guesses offered AND a confirmation — count:
/// that is the held-out set. An exchange the model stayed silent on is not
/// a miss here (its silence is measured by the floor-miss counter), and a
/// skipped exchange has no truth to compare against.
///
/// This is an internal diagnostic (§2.9): Progress phrases it as the
/// family's knowledge, never as a score for him.
enum LiveAccuracy {
    struct IntentAccuracy: Identifiable, Equatable {
        let intentId: String
        let label: String
        /// Confirmed exchanges in which this word was among the guesses.
        var shown: Int
        /// Of `shown`, how many times it was the word confirmed.
        var confirmedWhenShown: Int
        /// Confirmed exchanges where this word was the answer but the
        /// model did not offer it (guesses were shown, just not this one).
        var confirmedWhenNotShown: Int

        var id: String { intentId }
    }

    struct Summary: Equatable {
        /// Exchanges in which guesses were shown and a word was confirmed.
        var exchangesWithGuesses: Int
        /// Of those, how many had the confirmed word among the guesses.
        var confirmedWordShown: Int
        /// Of those, how many had the confirmed word as the highest-scoring
        /// guess (ties count).
        var confirmedWordWasTop: Int
        var perIntent: [IntentAccuracy]

        static let empty = Summary(
            exchangesWithGuesses: 0, confirmedWordShown: 0, confirmedWordWasTop: 0, perIntent: []
        )
    }

    /// Summary over observations stamped in `since ... now`. Observations
    /// without an exchange id (rows that predate v4) are ignored.
    static func summary(db: AppDatabase, since: Date, now: Date = Date()) throws -> Summary {
        try db.dbQueue.read { db in
            try summary(db, since: since, now: now)
        }
    }

    static func summary(_ db: Database, since: Date, now: Date) throws -> Summary {
        // Best score per (exchange, intent): a guess dismissed mid-exchange
        // and shown again at the yes moment has two rows.
        let observationRows = try Row.fetchAll(
            db,
            sql: """
            SELECT exchangeId, intentId, MAX(score) AS score
            FROM calibrationObservations
            WHERE exchangeId IS NOT NULL AND timestamp >= ? AND timestamp <= ?
            GROUP BY exchangeId, intentId
            """,
            arguments: [since, now]
        )
        var shownByExchange: [String: [String: Double]] = [:]
        for row in observationRows {
            guard let exchangeId: String = row["exchangeId"],
                  let intentId: String = row["intentId"],
                  let score: Double = row["score"]
            else { continue }
            shownByExchange[exchangeId, default: [:]][intentId] = score
        }
        guard !shownByExchange.isEmpty else { return .empty }

        // The earliest confirm per exchange is the yes moment. Events are
        // stamped a hair before the observations (same `now` on the
        // card), so the time filter is left to the observations.
        let confirmRows = try Row.fetchAll(
            db,
            sql: """
            SELECT exchangeId, intentId FROM events
            WHERE type = ? AND exchangeId IS NOT NULL AND intentId IS NOT NULL
            ORDER BY timestamp
            """,
            arguments: [EventType.confirm.rawValue]
        )
        var confirmedByExchange: [String: String] = [:]
        for row in confirmRows {
            guard let exchangeId: String = row["exchangeId"],
                  let intentId: String = row["intentId"],
                  shownByExchange[exchangeId] != nil,
                  confirmedByExchange[exchangeId] == nil
            else { continue }
            confirmedByExchange[exchangeId] = intentId
        }

        var labels: [String: String] = [:]
        for intent in try IntentRecord.fetchAll(db) {
            labels[intent.id] = intent.label
        }

        var summary = Summary.empty
        var perIntent: [String: IntentAccuracy] = [:]
        func entry(_ intentId: String) -> IntentAccuracy {
            perIntent[intentId] ?? IntentAccuracy(
                intentId: intentId,
                label: labels[intentId] ?? "a word since removed",
                shown: 0,
                confirmedWhenShown: 0,
                confirmedWhenNotShown: 0
            )
        }

        for (exchangeId, confirmedIntentId) in confirmedByExchange {
            guard let shown = shownByExchange[exchangeId] else { continue }
            summary.exchangesWithGuesses += 1
            let topScore = shown.values.max() ?? -.infinity

            for (intentId, score) in shown {
                var row = entry(intentId)
                row.shown += 1
                if intentId == confirmedIntentId {
                    row.confirmedWhenShown += 1
                    summary.confirmedWordShown += 1
                    if score >= topScore { summary.confirmedWordWasTop += 1 }
                }
                perIntent[intentId] = row
            }
            if shown[confirmedIntentId] == nil {
                var row = entry(confirmedIntentId)
                row.confirmedWhenNotShown += 1
                perIntent[confirmedIntentId] = row
            }
        }

        summary.perIntent = perIntent.values.sorted { lhs, rhs in
            if lhs.shown != rhs.shown { return lhs.shown > rhs.shown }
            return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }
        return summary
    }
}
