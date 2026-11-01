import Foundation
import Observation

/// Dependency container handed through the view tree. One database, one
/// capture controller, one speech output, store facades over the database.
@Observable
final class AppEnvironment {
    /// How long after the last clip of a closed exchange the Board still
    /// attaches taps (and the Confirm card still offers Ask) to it: he
    /// usually walks to the phone after he has stopped talking (§4.3).
    static let recentExchangeWindow: TimeInterval = 120

    let db: AppDatabase
    let capture: CaptureController
    /// Phase 2 ranking. Inert (empty suggestions, Phase 1 behaviour) until
    /// start() finds a bundled encoder model.
    let suggestions: SuggestionEngine
    /// The board's one long-lived voice (D7): pre-warmed, never torn down
    /// with a view, and the capture path's authority on when the phone
    /// itself is talking.
    let speech = SpeechOutput.shared

    var intents: IntentStore { IntentStore(db: db) }
    var exemplars: ExemplarStore { ExemplarStore(db: db) }
    var sessions: SessionStore { SessionStore(db: db) }
    var events: EventLog { EventLog(db: db) }
    var review: ReviewQueue { ReviewQueue(db: db) }
    var board: BoardStore { BoardStore(db: db) }
    var exporter: RosettaExporter { RosettaExporter(db: db) }

    // Stored (not computed) so @Observable notifies views when they change;
    // didSet persists to UserDefaults.

    /// Who is holding the phone — attached to every exemplar (§12).
    var labeller: String {
        didSet { UserDefaults.standard.set(labeller, forKey: "labellerName") }
    }

    var hasCompletedFirstRun: Bool {
        didSet { UserDefaults.standard.set(hasCompletedFirstRun, forKey: "hasCompletedFirstRun") }
    }

    var hasCompletedSetupInterview: Bool {
        didSet { UserDefaults.standard.set(hasCompletedSetupInterview, forKey: "hasCompletedSetupInterview") }
    }

    /// Whether the app is showing his full-screen board. Persisted so a
    /// relaunch of the counter phone lands back on the board, not in the
    /// parent tabs (§2.3: his surface is predictable).
    var childMode: Bool {
        didSet {
            UserDefaults.standard.set(childMode, forKey: "childMode")
            // Child mode and guest mode are exclusive: entering one leaves
            // the other. (guestMode's didSet sees childMode already true
            // and does nothing, so this cannot recurse.)
            if childMode && guestMode { guestMode = false }
        }
    }

    /// Whether the app is showing the read-only guest view (§3, Phase 3):
    /// the dictionary as "when he says this it usually means… respond
    /// by…" cards plus live guesses, for grandparents, EAs and respite
    /// workers. Persisted like `childMode` so a phone handed to a guest
    /// stays on that view across a relaunch.
    var guestMode: Bool {
        didSet {
            UserDefaults.standard.set(guestMode, forKey: "guestMode")
            if guestMode && childMode { childMode = false }
        }
    }

    /// Whether the guest view shows the live "Maybe: …?" strip. Default on;
    /// a family may prefer guests to see only the dictionary.
    var guestsSeeLiveGuesses: Bool {
        didSet { UserDefaults.standard.set(guestsSeeLiveGuesses, forKey: "guestsSeeLiveGuesses") }
    }

    /// Opt-in (§8, default off): a station phone that lives on the counter
    /// starts listening by itself at launch, provided setup is complete and
    /// microphone permission was already granted — the app never prompts
    /// at launch. The indicator still shows and Pause still stops it.
    var autoResumeListening: Bool {
        didSet { UserDefaults.standard.set(autoResumeListening, forKey: "autoResumeListening") }
    }

    init(db: AppDatabase) {
        self.db = db
        self.capture = CaptureController(db: db)
        self.suggestions = SuggestionEngine(db: db)
        self.labeller = UserDefaults.standard.string(forKey: "labellerName") ?? "Parent"
        self.hasCompletedFirstRun = UserDefaults.standard.bool(forKey: "hasCompletedFirstRun")
        self.hasCompletedSetupInterview = UserDefaults.standard.bool(forKey: "hasCompletedSetupInterview")
        let childMode = UserDefaults.standard.bool(forKey: "childMode")
        self.childMode = childMode
        // Exclusive with childMode; if both were somehow persisted, his
        // board wins (§2.3: his surface is predictable).
        self.guestMode = UserDefaults.standard.bool(forKey: "guestMode") && !childMode
        self.guestsSeeLiveGuesses = UserDefaults.standard.object(forKey: "guestsSeeLiveGuesses") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "guestsSeeLiveGuesses")
        self.autoResumeListening = UserDefaults.standard.bool(forKey: "autoResumeListening")
    }

    static func live() -> AppEnvironment {
        do {
            return AppEnvironment(db: try AppDatabase.open())
        } catch {
            // A broken database at launch is unrecoverable in-app; crashing
            // with the underlying error beats silently losing his data.
            fatalError("Could not open the Rosetta database: \(error)")
        }
    }

    /// The exchange a Board tap or an Ask belongs to right now: the open
    /// session, or the just-closed one while it is still fresh. Nil when
    /// nothing has been said recently.
    var currentOrRecentExchangeId: String? {
        if let id = capture.activeSessionId { return id }
        guard let last = capture.recentSegments.last else { return nil }
        let endedAt = last.startedAt.addingTimeInterval(Double(last.durationMs) / 1000)
        guard Date().timeIntervalSince(endedAt) <= Self.recentExchangeWindow else { return nil }
        return last.sessionId
    }
}
