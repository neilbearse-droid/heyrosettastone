import Foundation
import Observation

/// Dependency container handed through the view tree. One database, one
/// capture controller, store facades over both.
@Observable
final class AppEnvironment {
    let db: AppDatabase
    let capture: CaptureController

    var intents: IntentStore { IntentStore(db: db) }
    var exemplars: ExemplarStore { ExemplarStore(db: db) }
    var sessions: SessionStore { SessionStore(db: db) }
    var events: EventLog { EventLog(db: db) }
    var review: ReviewQueue { ReviewQueue(db: db) }
    var board: BoardStore { BoardStore(db: db) }
    var exporter: RosettaExporter { RosettaExporter(db: db) }

    /// Who is holding the phone — attached to every exemplar (§12).
    var labeller: String {
        get { UserDefaults.standard.string(forKey: "labellerName") ?? "Parent" }
        set { UserDefaults.standard.set(newValue, forKey: "labellerName") }
    }

    var hasCompletedFirstRun: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedFirstRun") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedFirstRun") }
    }

    var hasCompletedSetupInterview: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedSetupInterview") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedSetupInterview") }
    }

    init(db: AppDatabase) {
        self.db = db
        self.capture = CaptureController(db: db)
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
