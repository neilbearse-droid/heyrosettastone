import SwiftUI

/// The guest surface (§3, Phase 3): a read-only view for grandparents,
/// EAs and respite workers. The dictionary as cards — "when he says or
/// does this, it usually means… respond by…" — plus, when the family
/// allows it and the model has mature words, the live "Maybe: …?" strip.
///
/// Nothing here edits, labels, confirms, or opens Settings. Tapping a card
/// speaks the word aloud (so a guest can check the family's label with
/// him); that is the only action. Leaving the view is the same hold
/// control as his board, so the phone cannot fall back into the family's
/// tabs by a stray tap.
@MainActor
struct GuestView: View {
    @Environment(AppEnvironment.self) private var env
    let exit: () -> Void

    @State private var intents: [IntentRecord] = []
    @State private var heardCounts: [String: Int] = [:]
    @State private var search = ""
    @State private var liveGuesses: [Suggestion] = []
    /// The one in-flight guess refresh; a newer refresh cancels it so stale
    /// guesses never land after fresh ones (same pattern as ListenView).
    @State private var guessTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if env.guestsSeeLiveGuesses && !liveGuesses.isEmpty {
                        liveGuessStrip
                    }

                    if intents.isEmpty {
                        Text("The family has not added any words yet.")
                            .foregroundStyle(.secondary)
                            .padding(.top, 24)
                            .frame(maxWidth: .infinity)
                    } else if visibleIntents.isEmpty {
                        Text("Nothing matches “\(search)”.")
                            .foregroundStyle(.secondary)
                            .padding(.top, 24)
                            .frame(maxWidth: .infinity)
                    }

                    ForEach(visibleIntents) { intent in
                        GuestIntentCard(
                            intent: intent,
                            heardCount: heardCounts[intent.id] ?? 0
                        ) {
                            env.speech.speak(intent.label)
                        }
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .searchable(text: $search, prompt: "Find a word")
            .navigationTitle("His words")
            .navigationBarTitleDisplayMode(.inline)
            // Always visible at the top, never scrolled away: the indicator
            // a guest (and he) can trust, and the family's way back. A bar
            // rather than toolbar items so the long pill has room on an
            // iPhone.
            .safeAreaInset(edge: .top) {
                VStack(spacing: 10) {
                    RecordingIndicator(
                        isListening: env.capture.isListening,
                        isStopped: env.capture.lastError != nil
                    )
                    HoldToExitButton(
                        action: exit,
                        title: "Hold to return to the family view",
                        accessibilityLabel: "Return to the family view"
                    )
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(.bar)
            }
            .onAppear {
                reload()
                refreshLiveGuesses()
            }
            .onChange(of: env.capture.recentSegments) { refreshLiveGuesses() }
        }
    }

    /// Most-heard first, then alphabetical, filtered by the search field on
    /// label or respond note.
    private var visibleIntents: [IntentRecord] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return intents }
        return intents.filter { intent in
            intent.label.localizedCaseInsensitiveContains(query)
                || (intent.respondNote?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    /// Read-only live top-3 (§4.5). Copy stays tentative (§2.6): the model
    /// narrows, the people with him decide.
    private var liveGuessStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Right now he might mean")
                .font(.caption)
                .foregroundStyle(.secondary)
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
            Text("A guess from his past words, not a certainty — his family's yes is what counts.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 8)
    }

    private func reload() {
        let counts = (try? env.events.confirmCounts()) ?? [:]
        heardCounts = counts
        let all = (try? env.intents.all()) ?? []
        intents = all.sorted { a, b in
            let ca = counts[a.id] ?? 0
            let cb = counts[b.id] ?? 0
            if ca != cb { return ca > cb }
            return a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
        }
    }

    private func refreshLiveGuesses() {
        guessTask?.cancel()
        guard env.guestsSeeLiveGuesses else {
            liveGuesses = []
            return
        }
        let segments = env.capture.recentSegments.filter { $0.segmentState == .pending }
        guard !segments.isEmpty else {
            liveGuesses = []
            return
        }
        let station = env.capture.stationName
        let suggestions = env.suggestions
        guessTask = Task {
            // Empty until the engine has mature words (§5.6); the engine
            // also keeps out guesses already dismissed in this exchange.
            let guesses = await suggestions.suggestions(for: segments, station: station)
            guard !Task.isCancelled else { return }
            liveGuesses = guesses
        }
    }
}

/// One dictionary entry for a guest: photo, label, what it usually means,
/// how the family responds, and how often it has come up. The whole card
/// is one button that speaks the word.
struct GuestIntentCard: View {
    let intent: IntentRecord
    let heardCount: Int
    let speak: () -> Void

    var body: some View {
        Button(action: speak) {
            HStack(alignment: .top, spacing: 14) {
                photo
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 6) {
                    Text(intent.label)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("When he says or does this, it usually means “\(intent.label)”.")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    if let note = intent.respondNote, !note.isEmpty {
                        Text("Respond by: \(note)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if heardCount > 0 {
                        Text("heard \(heardCount) time\(heardCount == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Speaks the word aloud")
    }

    private var accessibilityText: String {
        var parts = ["\(intent.label). When he says or does this, it usually means \(intent.label)."]
        if let note = intent.respondNote, !note.isEmpty {
            parts.append("Respond by: \(note).")
        }
        if heardCount > 0 {
            parts.append("Heard \(heardCount) time\(heardCount == 1 ? "" : "s").")
        }
        return parts.joined(separator: " ")
    }

    @ViewBuilder
    private var photo: some View {
        if let ref = intent.photoRef {
            CachedPhoto(ref: ref) { letterTile }
        } else {
            letterTile
        }
    }

    private var letterTile: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color(.tertiarySystemFill))
            .overlay(
                Text(String(intent.label.prefix(1)).uppercased())
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(.secondary)
            )
    }
}
