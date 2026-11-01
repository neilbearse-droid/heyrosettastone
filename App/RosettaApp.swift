import AVFoundation
import SwiftUI

@main
struct RosettaApp: App {
    @State private var environment = AppEnvironment.live()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .task {
                    // Launch housekeeping first (Review expiry, orphaned
                    // sessions, partial clips, retention), off the main
                    // thread and before anything can start listening.
                    let db = environment.db
                    _ = try? await Task.detached(priority: .utility) {
                        try Maintenance.runAtLaunch(db: db)
                    }.value

                    // Then the ranking engine: loads the bundled encoder (if
                    // present) and builds the index from what is already
                    // embedded. Capture's embedding hook is wired the moment
                    // the index is up and before the long backfill starts, so
                    // a segment captured during backfill is still embedded
                    // near capture time (§5.7). The app is fully usable
                    // while (and without) any of this running.
                    let env = environment
                    await env.suggestions.start(onReady: {
                        // Weak: the environment owns capture, which owns
                        // this closure.
                        env.capture.embedSamples = { [weak env] samples, segmentId in
                            guard let env else { return nil }
                            return await env.suggestions.embedSamples(samples, segmentId: segmentId)
                        }

                        // Opt-in auto-resume for the counter phone (§8):
                        // only once setup is done, only if the family
                        // turned it on, and only when the microphone was
                        // already granted — never a permission prompt at
                        // launch. Inside onReady (not after `start`
                        // returns) because start also runs the long
                        // backfill. The indicator shows as usual and
                        // Pause still stops it instantly.
                        if env.hasCompletedFirstRun,
                           env.hasCompletedSetupInterview,
                           env.autoResumeListening,
                           AVAudioApplication.shared.recordPermission == .granted {
                            env.capture.startListening()
                        }
                    })
                }
        }
    }
}
