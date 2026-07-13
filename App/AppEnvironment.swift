import Foundation
import Observation

/// Dependency container handed through the view tree. One database, one
/// capture controller, store facades over both.
@Observable
final class AppEnvironment {
    let db: AppDatabase
    let capture: CaptureController
    /// Phase 2 ranking. Inert (empty suggestions, Phase 1 behaviour) until
    /// start() finds a bundled encoder model.
    let suggestions: SuggestionEngine

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

    init(db: AppDatabase) {
        self.db = db
        self.capture = CaptureController(db: db)
        self.suggestions = SuggestionEngine(db: db)
        self.labeller = UserDefaults.standard.string(forKey: "labellerName") ?? "Parent"
        self.hasCompletedFirstRun = UserDefaults.standard.bool(forKey: "hasCompletedFirstRun")
        self.hasCompletedSetupInterview = UserDefaults.standard.bool(forKey: "hasCompletedSetupInterview")
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
}
