import SwiftUI

@main
struct RosettaApp: App {
    @State private var environment = AppEnvironment.live()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .task {
                    // Loads the bundled encoder (if present), backfills
                    // embeddings, and builds the ranking index. The app is
                    // fully usable while (and without) this running.
                    await environment.suggestions.start()
                    environment.capture.embedSamples = { [weak environment] samples in
                        await environment?.suggestions.embedSamples(samples)
                    }
                }
        }
    }
}
