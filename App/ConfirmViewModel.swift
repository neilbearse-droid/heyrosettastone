import Foundation
import GRDB
import Observation

/// Logic for the Confirm card (§4.2), kept UI-free so the two-tap path is
/// testable. The common case is exactly two taps: chips are pre-selected
/// (tap one confirms the selection implicitly by not touching it), tap two
/// is the intent.
///
/// One model lives for one exchange. New segments of the same exchange are
/// absorbed in place (`absorb`), so a dismissed guess stays dismissed and
/// an unticked chip stays unticked while he keeps talking (§2.4, C3). A
/// segment resolved elsewhere (Review) drops out on `syncWithDatabase` so
/// it cannot be labelled twice (D6).
@Observable
final class ConfirmViewModel {
    private let db: AppDatabase
    private let exemplarStore: ExemplarStore
    private let sessionStore: SessionStore
    private let eventLog: EventLog
    let device: String
    let labeller: String

    let exchangeId: String?
    let exchangeOpenedAt: Date?

    private(set) var segments: [SegmentRecord]
    /// Default selection is every segment in the session (§4.2): the theory
    /// is he repeated the same intent through the no's.
    private(set) var selectedSegmentIds: Set<String>
    /// Guesses dismissed during this exchange. Rejection is final (§2.4):
    /// nothing puts a dismissed intent back in front of the family.
    private(set) var dismissedIntentIds: Set<String> = []
    private(set) var resolved = false

    /// The ranker's latest top-3 for the selected chips, set by the view
    /// after each refresh. What is actually shown is `displayedGuesses`.
    var topGuesses: [Suggestion] = []

    /// The yes moment with guesses on screen: called with every guess that
    /// was showing, the intent chosen, and the exchange id, so the engine
    /// can record an accept/reject observation per shown guess (C9). Wired
    /// by the view to `SuggestionEngine.recordOutcomes`.
    @ObservationIgnored
    var outcomeRecorder: ((_ shown: [Suggestion], _ confirmedIntentId: String, _ exchangeId: String?) -> Void)?

    init(segments: [SegmentRecord],
         exchangeId: String?,
         exchangeOpenedAt: Date?,
         device: String,
         labeller: String,
         db: AppDatabase) {
        self.segments = segments
        self.selectedSegmentIds = Set(segments.map(\.id))
        self.exchangeId = exchangeId
        self.exchangeOpenedAt = exchangeOpenedAt
        self.device = device
        self.labeller = labeller
        self.db = db
        self.exemplarStore = ExemplarStore(db: db)
        self.sessionStore = SessionStore(db: db)
        self.eventLog = EventLog(db: db)
        // Rejection is final (§2.4) across the life of the exchange, not of
        // this object: the card is rebuilt when the parent comes back from
        // his board or the app relaunches, and the negatives table is where
        // earlier dismissals live. Seed from it so a dismissed guess never
        // reappears in the grid or the pinned board taps.
        self.dismissedIntentIds = Self.storedDismissals(exchangeId: exchangeId, db: db)
    }

    /// Intents already rejected in this exchange, from the negatives table.
    private static func storedDismissals(exchangeId: String?, db: AppDatabase) -> Set<String> {
        guard let exchangeId else { return [] }
        let ids = (try? db.dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT DISTINCT rejectedIntentId FROM negatives WHERE exchangeId = ?",
                arguments: [exchangeId]
            )
        }) ?? []
        return Set(ids)
    }

    var selectedSegments: [SegmentRecord] {
        segments.filter { selectedSegmentIds.contains($0.id) }
    }

    /// Top guesses minus anything dismissed this exchange: the single
    /// source for what the card renders, so a dismissal can never leave a
    /// guess on screen (D6).
    var displayedGuesses: [Suggestion] {
        topGuesses.filter { !dismissedIntentIds.contains($0.intent.id) }
    }

    func toggleSegment(_ id: String) {
        if selectedSegmentIds.contains(id) {
            selectedSegmentIds.remove(id)
        } else {
            selectedSegmentIds.insert(id)
        }
    }

    /// Mid-exchange update (C3): segments not seen before are appended and
    /// selected by default; copies already held pick up an embedding the
    /// capture path persisted after this model's snapshot. Selection,
    /// dismissals and resolution are untouched.
    func absorb(newSegments incoming: [SegmentRecord]) {
        var indexById: [String: Int] = [:]
        for (index, segment) in segments.enumerated() {
            indexById[segment.id] = index
        }
        for record in incoming {
            if let index = indexById[record.id] {
                if segments[index].embedding == nil, let embedding = record.embedding {
                    segments[index].embedding = embedding
                }
            } else {
                indexById[record.id] = segments.count
                segments.append(record)
                selectedSegmentIds.insert(record.id)
            }
        }
    }

    /// Re-reads each held segment's row (D6). A segment that is no longer
    /// pending — labelled, discarded or marked not-him in Review, or gone
    /// after a wipe — leaves the card and the selection so it cannot be
    /// labelled twice. Embeddings written since the snapshot are picked up.
    func syncWithDatabase() {
        let ids = segments.map(\.id)
        guard !ids.isEmpty else { return }
        let rows: [SegmentRecord]
        do {
            rows = try db.dbQueue.read { db in
                try SegmentRecord.filter(ids.contains(Column("id"))).fetchAll(db)
            }
        } catch {
            return
        }
        var fresh: [String: SegmentRecord] = [:]
        for row in rows { fresh[row.id] = row }

        var kept: [SegmentRecord] = []
        for segment in segments {
            guard let row = fresh[segment.id], row.segmentState == .pending else {
                selectedSegmentIds.remove(segment.id)
                continue
            }
            var merged = row
            if merged.embedding == nil {
                merged.embedding = segment.embedding
            }
            kept.append(merged)
        }
        segments = kept
    }

    /// Intents he tapped on his own board during this exchange (§4.3, D5),
    /// most recent first, minus anything dismissed. The card pins these
    /// above the model's guesses: one tap confirms with the same audio.
    func boardTappedIntentIds() -> [String] {
        guard let exchangeId else { return [] }
        let ids = (try? db.dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT intentId FROM events
                WHERE exchangeId = ? AND type = ? AND intentId IS NOT NULL
                ORDER BY timestamp DESC
                """,
                arguments: [exchangeId, EventType.boardTap.rawValue]
            )
        }) ?? []
        var seen: Set<String> = []
        return ids.filter { !dismissedIntentIds.contains($0) && seen.insert($0).inserted }
    }

    /// Candidate intents for the grid: frequency-ranked, minus anything
    /// dismissed this exchange.
    func candidates(from intents: [IntentRecord], counts: [String: Int]) -> [IntentRecord] {
        FrequencyRanker.rank(intents: intents, counts: counts)
            .filter { !dismissedIntentIds.contains($0.id) }
    }

    /// A guess was dismissed ("no"). Stored as a hard negative for every
    /// selected segment (§4.2.3) and removed from the candidates for good.
    func dismiss(intentId: String, now: Date = Date()) {
        dismissedIntentIds.insert(intentId)
        for segment in selectedSegments {
            try? exemplarStore.recordNegative(NegativeRecord(
                rejectedIntentId: intentId,
                clipRef: segment.clipRef,
                embedding: segment.embedding,
                exchangeId: exchangeId,
                timestamp: now
            ))
        }
        try? eventLog.log(EventRecord(
            exchangeId: exchangeId,
            type: .reject,
            intentId: intentId,
            device: device,
            timestamp: now
        ))
    }

    /// The yes moment: every selected segment becomes a confirmed exemplar
    /// of the intent, in one tap. This is the app's only route to training
    /// data (§2.2), and it refuses intents dismissed this exchange (§2.4).
    /// Every guess on screen at that moment is reported through
    /// `outcomeRecorder` (C9) once the save has succeeded.
    @discardableResult
    func confirm(intentId: String, now: Date = Date()) throws -> [ExemplarRecord] {
        guard !dismissedIntentIds.contains(intentId) else { return [] }
        guard !resolved else { return [] }

        let shown = displayedGuesses
        let created = try exemplarStore.confirm(
            segments: selectedSegments,
            intentId: intentId,
            device: device,
            labeller: labeller,
            now: now
        )
        let latencyMs = exchangeOpenedAt.map { Int(now.timeIntervalSince($0) * 1000) }
        try eventLog.log(EventRecord(
            exchangeId: exchangeId,
            type: .confirm,
            intentId: intentId,
            latencyMs: latencyMs,
            device: device,
            timestamp: now
        ))
        outcomeRecorder?(shown, intentId, exchangeId)
        resolved = true
        return created
    }

    /// Anything skipped lands in Review (§4.2) — segments simply stay
    /// pending; the 24 h clock is already running from capture time.
    func skip(now: Date = Date()) {
        try? eventLog.log(EventRecord(
            exchangeId: exchangeId,
            type: .skip,
            device: device,
            timestamp: now
        ))
        resolved = true
    }
}
