import SwiftUI

/// Ambient capture status and pause (§3), plus the way into his board and
/// app settings. Pause is one tap and instant (§7). A live level meter with
/// the speech threshold marked shows whether he registers at all (A4).
@MainActor
struct ListenView: View {
    @Environment(AppEnvironment.self) private var env
    let enterChildMode: () -> Void

    @State private var showingSettings = false
    /// The engine's latest answer for the pending chips: guesses, or the
    /// reason there are none. Nil when nothing is pending.
    @State private var liveResult: SuggestionResult?
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
                    if let liveResult {
                        liveStrip(liveResult)
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

    /// The live strip has honest states (§2.6, §7): nothing when no model
    /// is bundled (Phase 1), a plain note while no word has matured, a
    /// quiet "nothing resembled" when the model declined on purpose, and
    /// the top-3 when it has guesses. Read-only here — resolving happens on
    /// the Confirm card. Copy stays tentative throughout.
    @ViewBuilder
    private func liveStrip(_ result: SuggestionResult) -> some View {
        switch result.reason {
        case .noModel, .noEmbedding:
            EmptyView()
        case .noMatureWords(let total):
            Text(noMatureWordsText(total: total))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)
        case .nothingResembled(let checked):
            if checked > 0 {
                Text("Didn't sound like any of his \(checked) guessing word\(checked == 1 ? "" : "s")")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 48)
            }
        case .suggested:
            liveGuessStrip(result.suggestions)
        }
    }

    /// "N of M words are still learning": N is the words with at least one
    /// confirmed clip (learning has started), M the dictionary. Progress
    /// explains the gate; no link here, the tab is one swipe away.
    private func noMatureWordsText(total: Int) -> String {
        let learning = env.suggestions.maturityReports.filter { $0.exemplarCount > 0 }.count
        if learning == 0 {
            return "No words are guessing yet — they start learning from your first confirmations"
        }
        return "No words are guessing yet — \(learning) of \(total) word\(total == 1 ? " is" : "s are") still learning"
    }

    /// Live top-3 during an exchange (§4.5).
    private func liveGuessStrip(_ guesses: [Suggestion]) -> some View {
        VStack(spacing: 6) {
            ForEach(guesses) { guess in
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
            liveResult = nil
            return
        }
        let station = env.capture.stationName
        let suggestions = env.suggestions
        guessTask = Task {
            // The engine unions in the exchange's own rejections, so a guess
            // dismissed on the Confirm card stays out of this strip too (§2.4).
            let result = await suggestions.suggestionsDetailed(for: segments, station: station)
            guard !Task.isCancelled else { return }
            liveResult = result
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
        // `confidence` is the neural VAD's speech probability when one is
        // active (nil on the energy VAD).
        let level = env.capture.liveLevel
        LevelMeter(
            rms: level.rms,
            threshold: level.threshold,
            confidence: level.confidence
        )
    }
}

/// Microphone level against the speech threshold, so the family can see at
/// a glance whether he registers from where he stands (A4). Both values
/// are RMS; drawn on a dB scale so a soft voice is still visible.
struct LevelMeter: View {
    let rms: Float
    let threshold: Float
    /// Speech probability in 0...1 from a neural VAD, nil when the energy
    /// detector is judging. With it, the caption reads "Speech: 82%"
    /// instead of pointing at the dB line.
    var confidence: Float? = nil

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
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Microphone level")
        .accessibilityValue(accessibilityValue)
    }

    private var speechPercent: Int? {
        guard let confidence else { return nil }
        return Int((min(max(confidence, 0), 1) * 100).rounded())
    }

    private var caption: String {
        if let speechPercent {
            return "Speech: \(speechPercent)%"
        }
        return threshold > 0 ? "Mic level — past the line counts as speech" : "Mic level"
    }

    private var accessibilityValue: String {
        if let speechPercent {
            return "Speech \(speechPercent) percent"
        }
        return isAbove ? "Hearing speech" : "Quiet"
    }
}
