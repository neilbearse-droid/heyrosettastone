import Foundation
import Observation

/// Logic for the Confirm card (§4.2), kept UI-free so the two-tap path is
/// testable. The common case is exactly two taps: chips are pre-selected
/// (tap one confirms the selection implicitly by not touching it), tap two
/// is the intent.
@Observable
final class ConfirmViewModel {
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
        self.exemplarStore = ExemplarStore(db: db)
        self.sessionStore = SessionStore(db: db)
        self.eventLog = EventLog(db: db)
    }

    var selectedSegments: [SegmentRecord] {
        segments.filter { selectedSegmentIds.contains($0.id) }
    }

    func toggleSegment(_ id: String) {
        if selectedSegmentIds.contains(id) {
            selectedSegmentIds.remove(id)
        } else {
            selectedSegmentIds.insert(id)
        }
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
    @discardableResult
    func confirm(intentId: String, now: Date = Date()) throws -> [ExemplarRecord] {
        guard !dismissedIntentIds.contains(intentId) else { return [] }
        guard !resolved else { return [] }

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
