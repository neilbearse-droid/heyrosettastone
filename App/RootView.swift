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

            HoldToExitButton(action: exit)
                .padding(.top, 12)
                .padding(.trailing, 16)
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        intents = (try? env.board.boardIntents()) ?? []
    }
}

/// The parent's way out of the full-screen board. Deliberately a *hold*,
/// not a tap, so the child can't fall out of his board by mistake — his
/// grid is predictable and never leads into parent UI (§3, §7). But unlike
/// a hidden gesture it is a visible, labelled pill that fills as you hold,
/// so a parent can find it one-handed and can see the hold is working.
private struct HoldToExitButton: View {
    let action: () -> Void

    @State private var progress: CGFloat = 0
    @State private var isHolding = false

    private let holdDuration: Double = 1.0

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.open")
            Text(isHolding ? "Keep holding…" : "Hold to exit")
                .fixedSize()
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.secondarySystemBackground))
                    Capsule()
                        .fill(Color.accentColor.opacity(0.35))
                        .frame(width: geo.size.width * progress)
                }
            }
        )
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
        .contentShape(Capsule())
        .onLongPressGesture(minimumDuration: holdDuration, perform: {
            action()
        }, onPressingChanged: { pressing in
            isHolding = pressing
            if pressing {
                withAnimation(.linear(duration: holdDuration)) { progress = 1 }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { progress = 0 }
            }
        })
        .accessibilityLabel("Leave the board, back to family view")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Press and hold to exit")
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
