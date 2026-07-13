import Foundation
import GRDB

// The tables from spec §6: intents, exemplars, negatives, events, sessions.
// Phase 1 adds a sixth, `segments`, because the Review queue needs unlabelled
// utterances to survive on disk with a state flag (§4.4: expired segments are
// kept, flagged unlabelled). Exemplars reference the same clip files.

// MARK: - Intent

struct IntentRecord: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "intents"

    var id: String
    var label: String
    /// File id under FileLocations.photos, nil if no photo yet.
    var photoRef: String?
    /// "How to respond" note for guests (§4.1).
    var respondNote: String?
    /// Fixed board slot index; nil = not on the board. Assignment is
    /// append-only — see BoardLayout. Never mutate this outside BoardLayout.
    var boardSlot: Int?
    var createdAt: Date
    var archivedAt: Date?

    init(id: String = UUID().uuidString,
         label: String,
         photoRef: String? = nil,
         respondNote: String? = nil,
         boardSlot: Int? = nil,
         createdAt: Date = Date(),
         archivedAt: Date? = nil) {
        self.id = id
        self.label = label
        self.photoRef = photoRef
        self.respondNote = respondNote
        self.boardSlot = boardSlot
        self.createdAt = createdAt
        self.archivedAt = archivedAt
    }
}

// MARK: - Exemplar

/// A confirmed (audio, meaning) pair. Created in exactly one code path,
/// ExemplarStore.confirm — the Face ID rule (§2.2): the store updates only
/// on explicit confirmation.
struct ExemplarRecord: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "exemplars"

    var id: String
    var intentId: String
    /// Clip file id under FileLocations.clips.
    var clipRef: String
    /// Embedding vector, Phase 2. Nil until the embedding pipeline exists;
    /// Phase 2 backfills from clipRef.
    var embedding: Data?
    /// Capture station identity, e.g. "kitchen" (§5.3 context prior input).
    var device: String
    /// JSON context bag: hour-of-day, station, session id. Kept schemaless
    /// so Phase 2 priors can grow without migrations.
    var contextJSON: String
    /// Who confirmed it (§12: labeller ids mean something).
    var labeller: String
    var timestamp: Date
    var decayExempt: Bool

    init(id: String = UUID().uuidString,
         intentId: String,
         clipRef: String,
         embedding: Data? = nil,
         device: String,
         contextJSON: String = "{}",
         labeller: String,
         timestamp: Date = Date(),
         decayExempt: Bool = false) {
        self.id = id
        self.intentId = intentId
        self.clipRef = clipRef
        self.embedding = embedding
        self.device = device
        self.contextJSON = contextJSON
        self.labeller = labeller
        self.timestamp = timestamp
        self.decayExempt = decayExempt
    }
}

// MARK: - Negative

/// A hard negative: this audio was guessed as that intent and the guess was
/// dismissed. Rejection is final (§2.4). Phase 1 stores the clip reference so
/// Phase 2 can backfill embeddings.
struct NegativeRecord: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "negatives"

    var id: String
    var rejectedIntentId: String
    var clipRef: String?
    var embedding: Data?
    var exchangeId: String?
    var timestamp: Date

    init(id: String = UUID().uuidString,
         rejectedIntentId: String,
         clipRef: String? = nil,
         embedding: Data? = nil,
         exchangeId: String? = nil,
         timestamp: Date = Date()) {
        self.id = id
        self.rejectedIntentId = rejectedIntentId
        self.clipRef = clipRef
        self.embedding = embedding
        self.exchangeId = exchangeId
        self.timestamp = timestamp
    }
}

// MARK: - Event

enum EventType: String, Codable {
    case confirm
    case reject
    case skip
    case boardTap
}

/// The interaction log. Time-to-understanding and abandoned-exchange rate
/// (§2.9) are computed from these rows, never from model internals.
struct EventRecord: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "events"

    var id: String
    var exchangeId: String?
    var type: String
    var intentId: String?
    /// For confirm events: ms from exchange open to confirmation.
    var latencyMs: Int?
    var device: String
    var timestamp: Date

    init(id: String = UUID().uuidString,
         exchangeId: String? = nil,
         type: EventType,
         intentId: String? = nil,
         latencyMs: Int? = nil,
         device: String,
         timestamp: Date = Date()) {
        self.id = id
        self.exchangeId = exchangeId
        self.type = type.rawValue
        self.intentId = intentId
        self.latencyMs = latencyMs
        self.device = device
        self.timestamp = timestamp
    }

    var eventType: EventType? { EventType(rawValue: type) }
}

// MARK: - Session

/// One exchange session (§4.2): opens at first detected utterance, closes
/// after 10 s silence or 90 s total.
struct SessionRecord: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "sessions"

    var id: String
    var startedAt: Date
    var endedAt: Date?
    var device: String

    init(id: String = UUID().uuidString,
         startedAt: Date,
         endedAt: Date? = nil,
         device: String) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.device = device
    }
}

// MARK: - Segment

enum SegmentState: String, Codable {
    /// Awaiting a label; shows in Confirm (while session is recent) and Review.
    case pending
    /// Confirmed into one or more exemplars.
    case labelled
    /// Parent discarded it (noise, TV, etc.).
    case discarded
    /// Marked "not him" — someone else's voice.
    case notHim
    /// Sat in Review past 24 h (§4.4). Kept on disk, flagged unlabelled,
    /// out of the queue.
    case expired
}

/// One VAD-detected utterance, persisted with its clip.
struct SegmentRecord: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "segments"

    var id: String
    var sessionId: String
    var clipRef: String
    var startedAt: Date
    var durationMs: Int
    var state: String
    var labelledAt: Date?
    /// Encoder embedding computed at (or shortly after) capture, so ranking
    /// and confirmation reuse it without re-encoding (§5.7 latency budget).
    var embedding: Data?

    init(id: String = UUID().uuidString,
         sessionId: String,
         clipRef: String,
         startedAt: Date,
         durationMs: Int,
         state: SegmentState = .pending,
         labelledAt: Date? = nil,
         embedding: Data? = nil) {
        self.id = id
        self.sessionId = sessionId
        self.clipRef = clipRef
        self.startedAt = startedAt
        self.durationMs = durationMs
        self.state = state.rawValue
        self.labelledAt = labelledAt
        self.embedding = embedding
    }

    var segmentState: SegmentState? { SegmentState(rawValue: state) }
}

// MARK: - Calibration observation

/// One shown-guess outcome: the raw score the ranker produced and whether
/// the family accepted it. Fitting a per-intent logistic over these is how
/// each word learns its own distance threshold (§5.2); a wrong-and-rejected
/// guess tightens it.
struct CalibrationObservationRecord: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "calibrationObservations"

    var id: String
    var intentId: String
    var score: Double
    var accepted: Bool
    var timestamp: Date

    init(id: String = UUID().uuidString,
         intentId: String,
         score: Double,
         accepted: Bool,
         timestamp: Date = Date()) {
        self.id = id
        self.intentId = intentId
        self.score = score
        self.accepted = accepted
        self.timestamp = timestamp
    }
}
