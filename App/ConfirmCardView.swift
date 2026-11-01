import SwiftUI

/// The in-the-moment labelling card (§4.2). Top: the exchange's segment
/// chips with playback, all pre-selected. Middle: anything he tapped on his
/// own board this exchange (pinned, §4.3), the top-3 guesses (Phase 2), the
/// intent grid frequency-sorted, then search. One tap on an intent saves.
/// Hold a word (or use its context menu) to mark it as a dismissed guess.
///
/// One view model lives for one exchange: new chips of the same exchange
/// are absorbed in place so dismissed guesses stay dismissed and unticked
/// chips stay unticked while he keeps talking (§2.4).
@MainActor
struct ConfirmCardView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model: ConfirmViewModel?
    @State private var player = ClipPlayer()
    @State private var search = ""
    @State private var intents: [IntentRecord] = []
    @State private var counts: [String: Int] = [:]
    @State private var showingAskBoard = false
    @State private var banner: Banner?
    @State private var bannerToken = UUID()
    /// Intents he tapped on his board during this exchange, most recent first.
    @State private var boardTapped: [IntentRecord] = []
    /// The one in-flight guess refresh; a newer refresh cancels it so a
    /// slow answer can never overwrite a fresh one (D9).
    @State private var guessTask: Task<Void, Never>?

    struct Banner {
        let text: String
        let isSuccess: Bool
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Outside the card so the "Saved N clips" feedback is
                    // visible on the emptied card after a confirm (D6).
                    if let banner {
                        Label(banner.text, systemImage: banner.isSuccess ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(banner.isSuccess ? Color.green : Color.orange)
                            .font(.headline)
                            .accessibilityAddTraits(.updatesFrequently)
                    }

                    if let model, !model.segments.isEmpty {
                        card(model)
                    } else {
                        emptyState
                    }
                }
                .padding(16)
            }
            .navigationTitle("Confirm")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    RecordingIndicator(
                        isListening: env.capture.isListening,
                        isStopped: env.capture.lastError != nil
                    )
                }
            }
            .sheet(isPresented: $showingAskBoard) { askBoard }
        }
        .onAppear(perform: reload)
        .onChange(of: env.capture.recentSegments) { reload() }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                "No exchange waiting",
                systemImage: "checkmark.bubble",
                description: Text("When he says something while listening is on, his clips appear here for you to label at the yes moment.")
            )
            // The Ask flow is also useful before a chip has landed: he is
            // mid-sentence, or he has just stopped and is walking over. His
            // tap is attached to that exchange and shows up here as a
            // pinned guess when the clips arrive (§4.3).
            if env.currentOrRecentExchangeId != nil {
                Button {
                    showingAskBoard = true
                } label: {
                    Label("Ask on his board", systemImage: "square.grid.2x2")
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    // MARK: - Card

    private func card(_ model: ConfirmViewModel) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            // Chips: every segment of the exchange, oldest first, pre-selected.
            // All of them, so what is selected is exactly what is visible (D6).
            VStack(alignment: .leading, spacing: 8) {
                Text("His clips — tap to play, untick any that weren't him")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(model.segments) { segment in
                            SegmentChip(
                                segment: segment,
                                isSelected: model.selectedSegmentIds.contains(segment.id),
                                isPlaying: player.playingClipRef == segment.clipRef,
                                onPlay: { player.toggle(clipRef: segment.clipRef) },
                                onToggle: {
                                    model.toggleSegment(segment.id)
                                    refreshGuesses(model)
                                }
                            )
                        }
                    }
                }
                if model.selectedSegments.isEmpty {
                    Text("Nothing ticked — tick at least one clip to save it.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            // He answered on his own board (§4.3, D5): the strongest guess
            // there is, pinned above the model's. One tap confirms with
            // this exchange's audio.
            if !boardTapped.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("He tapped on his board — tap to confirm")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ForEach(boardTapped) { intent in
                        HStack(spacing: 8) {
                            Button {
                                confirm(intent, with: model)
                            } label: {
                                HStack {
                                    Image(systemName: "hand.tap.fill")
                                    Text("He tapped: \(intent.label)")
                                        .font(.title3.weight(.semibold))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .background(RoundedRectangle(cornerRadius: 14).fill(Color.green.opacity(0.15)))
                            }
                            .buttonStyle(.plain)

                            Button {
                                dismiss(intent.id, in: model)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityLabel("No, not \(intent.label)")
                        }
                    }
                }
            }

            // Top-3 guesses (§4.5), tentative copy always (§2.6). Tap
            // accepts; the ✕ dismisses — and a dismissed guess stays
            // dismissed (§2.4). Rendered from `displayedGuesses`, which
            // already excludes dismissals, so no path can leave one on screen.
            let guesses = model.displayedGuesses
            if !guesses.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Best guesses — tap if right, ✕ if wrong")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ForEach(guesses) { guess in
                        GuessButton(
                            guess: guess,
                            onAccept: { confirm(guess.intent, with: model) },
                            onDismiss: { dismiss(guess.intent.id, in: model) }
                        )
                    }
                }
            }

            // Intent grid, frequency-sorted, searchable.
            VStack(alignment: .leading, spacing: 8) {
                if let notice = declinedNotice(model) {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("The model has no guess for this one. Pick from the list.")
                }
                Text("What did he mean? One tap saves. Hold a word to mark it as a wrong guess.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("Search his words", text: $search)
                    .textFieldStyle(.roundedBorder)

                let candidates = model.candidates(from: intents, counts: counts)
                    .filter { search.isEmpty || $0.label.localizedCaseInsensitiveContains(search) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
                    ForEach(candidates) { intent in
                        Button {
                            confirm(intent, with: model)
                        } label: {
                            IntentCell(intent: intent)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                dismiss(intent.id, in: model)
                            } label: {
                                Label("Not \(intent.label) — mark as a wrong guess", systemImage: "xmark")
                            }
                        }
                        .accessibilityHint("Saves his clips as this word. Use the actions menu to mark it as a wrong guess.")
                    }
                }
            }

            HStack {
                Button("Ask on his board") { showingAskBoard = true }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Skip — decide tonight") { skip(model) }
                    .buttonStyle(.bordered)
                    .tint(.secondary)
            }
        }
    }

    /// The Ask flow (§4.3): he answers on his board mid-exchange and his
    /// selection resolves the exchange with the same audio. Reachable with
    /// or without chips on the card; without, the tap is remembered against
    /// the current exchange and pinned when the clips land.
    private var askBoard: some View {
        NavigationStack {
            BoardView(intents: (try? env.board.boardIntents()) ?? [], mode: .ask { intent in
                showingAskBoard = false
                if let model {
                    confirm(intent, with: model)
                }
            }) { intent in
                // BoardView calls this off the main thread; read observable
                // state on the main actor, then write the row off it.
                Task { @MainActor in
                    let event = EventRecord(
                        exchangeId: model?.exchangeId ?? env.currentOrRecentExchangeId,
                        type: .boardTap,
                        intentId: intent.id,
                        device: env.capture.stationName
                    )
                    let events = env.events
                    Task.detached(priority: .utility) {
                        try? events.log(event)
                    }
                }
            }
            .navigationTitle("His board")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Actions

    private func refreshGuesses(_ model: ConfirmViewModel) {
        guessTask?.cancel()
        let segments = model.selectedSegments
        let excluding = model.dismissedIntentIds
        let station = env.capture.stationName
        let suggestions = env.suggestions
        guessTask = Task {
            let result = await suggestions.suggestionsDetailed(
                for: segments,
                station: station,
                excluding: excluding
            )
            guard !Task.isCancelled, !model.resolved else { return }
            model.topGuesses = result.suggestions
            model.declinedGuesses = result.declined
            model.suggestionReason = result.reason
        }
    }

    /// The model is live, words are mature, and it chose to say nothing:
    /// said out loud, quietly, so the empty guess list reads as deliberate
    /// rather than broken. Nothing when no word has matured (the grid is
    /// the normal path then) or when every mature word was dismissed.
    private func declinedNotice(_ model: ConfirmViewModel) -> String? {
        guard model.displayedGuesses.isEmpty,
              case .nothingResembled(let checked)? = model.suggestionReason,
              checked > 0
        else { return nil }
        return "None of his guessing words sounded like this — pick from the list"
    }

    /// The one dismissal path for ✕, the pinned board tap and the grid's
    /// context menu (D6): hard negatives, the engine's exclusion set, a
    /// calibration observation when the intent was a shown guess, then a
    /// refresh so the next guess surfaces (§4.5).
    private func dismiss(_ intentId: String, in model: ConfirmViewModel) {
        let guess = model.topGuesses.first { $0.intent.id == intentId }
        model.dismiss(intentId: intentId)
        if let guess {
            // recordOutcome also notes the dismissal for this exchange.
            env.suggestions.recordOutcome(
                intentId: intentId,
                rawScore: guess.rawScore,
                accepted: false,
                exchangeId: model.exchangeId
            )
        } else {
            env.suggestions.noteDismissal(intentId: intentId, exchangeId: model.exchangeId)
        }
        boardTapped = tappedIntents(model)
        refreshGuesses(model)
    }

    private func confirm(_ intent: IntentRecord, with model: ConfirmViewModel) {
        // A second tap on an already-saved card (double tap, or a stale
        // button after the model was swapped) is silently ignored.
        guard !model.resolved else { return }
        // Rejection is final (§2.4): the model refuses a dismissed intent.
        // The Ask board can still hand one in (he taps a word the parent
        // ✕'d), so say why nothing happened instead of doing nothing.
        guard !model.dismissedIntentIds.contains(intent.id) else {
            showBanner("“\(intent.label)” was marked as a wrong guess this exchange, so it was not saved.", success: false)
            return
        }
        guard !model.selectedSegments.isEmpty else {
            showBanner("Tick at least one clip to save it as “\(intent.label)”", success: false)
            return
        }
        let created: [ExemplarRecord]
        do {
            created = try model.confirm(intentId: intent.id)
        } catch {
            showBanner("Could not save: \(error.localizedDescription)", success: false)
            return
        }
        guard !created.isEmpty else {
            // The store skipped every selected clip (audio already deleted).
            // The model is resolved now, so the card must not stay up dead.
            showBanner("Nothing saved — those recordings are no longer on this phone.", success: false)
            clearModel()
            env.capture.clearRecentSegments()
            reload()
            return
        }

        showBanner("Saved \(created.count) clip\(created.count == 1 ? "" : "s") as “\(intent.label)”", success: true)
        clearModel()
        env.capture.clearRecentSegments()
        let suggestions = env.suggestions
        Task { await suggestions.reload() }
        reload()
    }

    private func skip(_ model: ConfirmViewModel) {
        model.skip()
        clearModel()
        env.capture.clearRecentSegments()
        reload()
    }

    private func showBanner(_ text: String, success: Bool) {
        let token = UUID()
        bannerToken = token
        banner = Banner(text: text, isSuccess: success)
        Task {
            try? await Task.sleep(for: .seconds(4))
            if bannerToken == token {
                banner = nil
            }
        }
    }

    private func clearModel() {
        guessTask?.cancel()
        guessTask = nil
        model = nil
        boardTapped = []
        player.stop()
    }

    private func tappedIntents(_ model: ConfirmViewModel) -> [IntentRecord] {
        let byId = Dictionary(intents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return model.boardTappedIntentIds().compactMap { byId[$0] }
    }

    /// Keeps the model in step with capture: same exchange → absorb new
    /// chips in place (dismissals and selection survive, C3); exchange
    /// changed or resolved → a fresh model. Segment state is re-read from
    /// the database either way so a clip labelled in Review leaves the
    /// card (D6).
    private func reload() {
        intents = (try? env.intents.all()) ?? []
        counts = (try? env.events.confirmCounts()) ?? [:]
        let incoming = env.capture.recentSegments.filter { $0.segmentState == .pending }
        let exchangeId = incoming.first?.sessionId

        if let model, !model.resolved, let exchangeId, model.exchangeId == exchangeId {
            model.absorb(newSegments: incoming)
            model.syncWithDatabase()
            if model.segments.isEmpty {
                clearModel()
            } else {
                boardTapped = tappedIntents(model)
                refreshGuesses(model)
            }
            return
        }

        guard !incoming.isEmpty else {
            clearModel()
            return
        }

        let fresh = ConfirmViewModel(
            segments: incoming,
            exchangeId: exchangeId,
            exchangeOpenedAt: env.capture.activeSessionOpenedAt,
            device: env.capture.stationName,
            labeller: env.labeller,
            db: env.db
        )
        let suggestions = env.suggestions
        fresh.outcomeRecorder = { shown, confirmedIntentId, exchangeId in
            // ConfirmViewModel is driven from the main thread; the engine is
            // main-actor isolated.
            MainActor.assumeIsolated {
                suggestions.recordOutcomes(
                    topGuesses: shown,
                    confirmed: confirmedIntentId,
                    exchangeId: exchangeId
                )
            }
        }
        fresh.floorMissRecorder = { intentId, bestSimilarity, exchangeId in
            MainActor.assumeIsolated {
                suggestions.noteFloorMiss(
                    intentId: intentId,
                    bestSimilarity: bestSimilarity,
                    exchangeId: exchangeId
                )
            }
        }
        fresh.syncWithDatabase()
        guard !fresh.segments.isEmpty else {
            clearModel()
            return
        }
        guessTask?.cancel()
        model = fresh
        boardTapped = tappedIntents(fresh)
        refreshGuesses(fresh)
    }
}

// MARK: - Pieces

/// One tentative guess: "Maybe: banana?" with confidence dots and an
/// explicit dismiss. Large targets — this is the two-tap fast path.
struct GuessButton: View {
    let guess: Suggestion
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onAccept) {
                HStack {
                    Text("Maybe: \(guess.intent.label)?")
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer()
                    HStack(spacing: 3) {
                        ForEach(0..<3, id: \.self) { dot in
                            Circle()
                                .fill(dot < guess.confidenceDots ? Color.accentColor : Color(.tertiarySystemFill))
                                .frame(width: 8, height: 8)
                        }
                    }
                    .accessibilityLabel("Confidence \(guess.confidenceDots) of 3")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.accentColor.opacity(0.12)))
            }
            .buttonStyle(.plain)

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("No, not \(guess.intent.label)")
        }
    }
}

struct SegmentChip: View {
    let segment: SegmentRecord
    let isSelected: Bool
    let isPlaying: Bool
    let onPlay: () -> Void
    let onToggle: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Button(action: onPlay) {
                HStack(spacing: 6) {
                    Image(systemName: segment.isClipDeleted
                        ? "speaker.slash"
                        : (isPlaying ? "stop.circle.fill" : "play.circle.fill"))
                        .font(.title2)
                    Text(String(format: "%.1fs", Double(segment.durationMs) / 1000))
                        .font(.callout.monospacedDigit())
                }
            }
            .disabled(segment.isClipDeleted)
            .accessibilityLabel(segment.isClipDeleted ? "Recording deleted" : (isPlaying ? "Stop" : "Play clip"))
            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .accessibilityLabel(isSelected ? "Included" : "Excluded")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(.secondarySystemBackground))
        )
    }
}

/// A word in the Confirm grid. The caller wraps it in a Button (so it has
/// the button trait and pressed feedback) and a context menu for dismiss,
/// which VoiceOver can reach where a long-press cannot (D9).
struct IntentCell: View {
    let intent: IntentRecord

    var body: some View {
        VStack(spacing: 6) {
            if let ref = intent.photoRef {
                CachedPhoto(ref: ref)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Text(intent.label)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 56)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}
