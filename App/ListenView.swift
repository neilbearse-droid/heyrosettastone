import SwiftUI

/// Ambient capture status and pause (§3), plus the way into his board and
/// app settings. Pause is one tap and instant (§7). A live level meter with
/// the speech threshold marked shows whether he registers at all (A4).
@MainActor
struct ListenView: View {
    @Environment(AppEnvironment.self) private var env
    let enterChildMode: () -> Void

    @State private var showingSettings = false
    @State private var liveGuesses: [Suggestion] = []
    /// The one in-flight guess refresh; a newer refresh cancels it so stale
    /// guesses never land after fresh ones (D9).
    @State private var guessTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()

                RecordingIndicator(
                    isListening: env.capture.isListening,
                    isStopped: env.capture.lastError != nil
                )
                .scaleEffect(1.3)

                if env.capture.isListening {
                    statusText
                    // Its own view so the 10 Hz level updates re-render the
                    // meter alone, not this whole tab.
                    LiveLevelMeter()
                        .padding(.horizontal, 48)
                    if !liveGuesses.isEmpty {
                        liveGuessStrip
                    }
                } else {
                    Text("Not recording. Tap Listen when you want to start catching his words.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 32)
                }

                Button {
                    if env.capture.isListening {
                        env.capture.pauseListening()
                    } else {
                        env.capture.startListening()
                    }
                } label: {
                    Label(
                        env.capture.isListening ? "Pause" : "Listen",
                        systemImage: env.capture.isListening ? "pause.fill" : "mic.fill"
                    )
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(env.capture.isListening ? .orange : .green)
                .padding(.horizontal, 48)

                if let error = env.capture.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Spacer()

                Button {
                    enterChildMode()
                } label: {
                    Label("Open his board", systemImage: "square.grid.2x2")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, 48)
                .padding(.bottom, 16)
            }
            .navigationTitle("Listen")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            // onAppear too: the tab is rebuilt on leaving his board, which
            // may be mid-exchange with chips already waiting.
            .onAppear { refreshLiveGuesses() }
            .onChange(of: env.capture.recentSegments) { refreshLiveGuesses() }
        }
    }

    /// Live top-3 during an exchange (§4.5). Read-only here — resolving
    /// happens on the Confirm card. Copy stays tentative (§2.6).
    private var liveGuessStrip: some View {
        VStack(spacing: 6) {
            ForEach(liveGuesses) { guess in
                HStack {
                    Text("Maybe: \(guess.intent.label)?")
                        .font(.headline)
                    Spacer()
                    HStack(spacing: 3) {
                        ForEach(0..<3, id: \.self) { dot in
                            Circle()
                                .fill(dot < guess.confidenceDots ? Color.accentColor : Color(.tertiarySystemFill))
                                .frame(width: 7, height: 7)
                        }
                    }
                    .accessibilityLabel("Confidence \(guess.confidenceDots) of 3")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
            }
        }
        .padding(.horizontal, 48)
    }

    private func refreshLiveGuesses() {
        guessTask?.cancel()
        let segments = env.capture.recentSegments.filter { $0.segmentState == .pending }
        guard !segments.isEmpty else {
            liveGuesses = []
            return
        }
        let station = env.capture.stationName
        let suggestions = env.suggestions
        guessTask = Task {
            // The engine unions in the exchange's own rejections, so a guess
            // dismissed on the Confirm card stays out of this strip too (§2.4).
            let guesses = await suggestions.suggestions(for: segments, station: station)
            guard !Task.isCancelled else { return }
            liveGuesses = guesses
        }
    }

    private var statusText: some View {
        VStack(spacing: 6) {
            if env.capture.activeSessionId != nil {
                Text("In an exchange — \(env.capture.recentSegments.count) clip\(env.capture.recentSegments.count == 1 ? "" : "s") so far")
                    .font(.headline)
                Text("Head to Confirm at the yes moment.")
                    .foregroundStyle(.secondary)
            } else if !env.capture.recentSegments.isEmpty {
                Text("Last exchange: \(env.capture.recentSegments.count) clip\(env.capture.recentSegments.count == 1 ? "" : "s") waiting in Confirm")
                    .font(.headline)
            } else {
                Text("Quiet — waiting for him.")
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
    }
}

/// Reads the capture controller's level itself, so only this view
/// re-renders at the ~10 Hz publish rate.
private struct LiveLevelMeter: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        LevelMeter(
            rms: env.capture.liveLevel.rms,
            threshold: env.capture.liveLevel.threshold
        )
    }
}

/// Microphone level against the speech threshold, so the family can see at
/// a glance whether he registers from where he stands (A4). Both values
/// are RMS; drawn on a dB scale so a soft voice is still visible.
struct LevelMeter: View {
    let rms: Float
    let threshold: Float

    /// Quietest level drawn (dBFS); anything below sits at the left edge.
    private static let floorDB: Float = -70

    private static func fraction(_ value: Float) -> CGFloat {
        guard value > 0 else { return 0 }
        let db = 20 * log10(value)
        let clamped = min(max(db, floorDB), 0)
        return CGFloat((clamped - floorDB) / -floorDB)
    }

    private var level: CGFloat { Self.fraction(rms) }
    private var mark: CGFloat { Self.fraction(threshold) }
    private var isAbove: Bool { threshold > 0 && rms >= threshold }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.tertiarySystemFill))
                    Capsule()
                        .fill(isAbove ? Color.green : Color.accentColor.opacity(0.6))
                        .frame(width: max(0, geo.size.width * level))
                        .animation(.linear(duration: 0.1), value: level)
                    if threshold > 0 {
                        Rectangle()
                            .fill(Color.primary.opacity(0.7))
                            .frame(width: 2)
                            .offset(x: geo.size.width * mark - 1)
                    }
                }
            }
            .frame(height: 10)
            Text(threshold > 0
                ? "Mic level — past the line counts as speech"
                : "Mic level")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Microphone level")
        .accessibilityValue(isAbove ? "Hearing speech" : "Quiet")
    }
}
