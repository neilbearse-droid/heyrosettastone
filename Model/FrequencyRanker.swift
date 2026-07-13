import Foundation

// Model/ is where Phase 2's learning stack will live: WhisperKit embeddings,
// the exemplar kNN with recency decay, per-intent logistic calibration, and
// context priors (spec §5). Phase 1 deliberately ships no ML — the only
// ranking is usage frequency, which orders the Confirm card's intent grid.

/// Orders intents by how often they have been confirmed or board-tapped,
/// most frequent first, ties broken alphabetically so the grid is stable.
enum FrequencyRanker {
    static func rank(intents: [IntentRecord], counts: [String: Int]) -> [IntentRecord] {
        intents.sorted { a, b in
            let ca = counts[a.id] ?? 0
            let cb = counts[b.id] ?? 0
            if ca != cb { return ca > cb }
            return a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
        }
    }
}
