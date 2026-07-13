import SwiftUI

/// Top-level navigation: first-run consent → setup interview → the app.
/// The app itself is either the child's board (full screen, guarded exit)
/// or the parent tabs.
struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var childMode = false

    var body: some View {
        if !env.hasCompletedFirstRun {
            FirstRunView()
        } else if !env.hasCompletedSetupInterview {
            SetupInterviewView()
        } else if childMode {
            ChildBoardScreen(exit: { childMode = false })
        } else {
            ParentTabView(enterChildMode: { childMode = true })
        }
    }
}

/// Full-screen board for him. Exit is a long-press on a small corner
/// control so a stray tap can't dump him into parent UI, but a parent can
/// leave one-handed. No other chrome: low clutter (§7).
struct ChildBoardScreen: View {
    @Environment(AppEnvironment.self) private var env
    let exit: () -> Void

    @State private var intents: [IntentRecord] = []

    var body: some View {
        ZStack(alignment: .topTrailing) {
            BoardView(intents: intents, mode: .child) { intent in
                try? env.events.log(EventRecord(
                    exchangeId: env.capture.activeSessionId,
                    type: .boardTap,
                    intentId: intent.id,
                    device: env.capture.stationName
                ))
            }

            Image(systemName: "person.crop.circle")
                .font(.title2)
                .foregroundStyle(.tertiary)
                .padding(20)
                .contentShape(Circle().scale(2))
                .onLongPressGesture(minimumDuration: 1.5) { exit() }
                .accessibilityLabel("Back to family view")
                .accessibilityHint("Hold to leave the board")
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        intents = (try? env.board.boardIntents()) ?? []
    }
}

struct ParentTabView: View {
    @Environment(AppEnvironment.self) private var env
    let enterChildMode: () -> Void

    var body: some View {
        TabView {
            ListenView(enterChildMode: enterChildMode)
                .tabItem { Label("Listen", systemImage: "waveform") }
            ConfirmCardView()
                .tabItem { Label("Confirm", systemImage: "checkmark.bubble") }
            ReviewView()
                .tabItem { Label("Review", systemImage: "tray.full") }
            DictionaryView()
                .tabItem { Label("Dictionary", systemImage: "book") }
            ProgressTabView()
                .tabItem { Label("Progress", systemImage: "chart.line.uptrend.xyaxis") }
        }
    }
}
