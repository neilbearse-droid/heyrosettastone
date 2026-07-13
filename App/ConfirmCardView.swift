import SwiftUI

/// The in-the-moment labelling card (§4.2). Top: up to five recent segment
/// chips with playback, all pre-selected. Middle: the intent grid,
/// frequency-sorted (top-3 guesses join in Phase 2), then search. One tap
/// on an intent saves. Long-press an intent to mark it as a dismissed guess.
struct ConfirmCardView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model: ConfirmViewModel?
    @State private var player = ClipPlayer()
    @State private var search = ""
    @State private var intents: [IntentRecord] = []
    @State private var counts: [String: Int] = [:]
    @State private var showingAskBoard = false
    @State private var savedBanner: String?
    @State private var topGuesses: [Suggestion] = []

    var body: some View {
        NavigationStack {
            Group {
                if let model, !model.segments.isEmpty {
                    card(model)
                } else {
                    emptyState
                }
            }
            .navigationTitle("Confirm")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    RecordingIndicator(isListening: env.capture.isListening)
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: env.capture.recentSegments) { reload() }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No exchange waiting",
            systemImage: "checkmark.bubble",
            description: Text("When he says something while listening is on, his clips appear here for you to label at the yes moment.")
        )
    }

    private func card(_ model: ConfirmViewModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let savedBanner {
                    Label(savedBanner, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.headline)
                }

                // Chips: the last five segments, newest last, pre-selected.
                VStack(alignment: .leading, spacing: 8) {
                    Text("His clips — tap to play, untick any that weren't him")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(model.segments.suffix(5)) { segment in
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
                }

                // Top-3 guesses (§4.5), tentative copy always (§2.6). Tap
                // accepts; the ✕ dismisses — and a dismissed guess stays
                // dismissed (§2.4).
                if !topGuesses.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Best guesses — tap if right, ✕ if wrong")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        ForEach(topGuesses) { guess in
                            GuessButton(
                                guess: guess,
                                onAccept: {
                                    env.suggestions.recordOutcome(
                                        intentId: guess.intent.id,
                                        rawScore: guess.rawScore,
                                        accepted: true
                                    )
                                    confirm(guess.intent, with: model)
                                },
                                onDismiss: {
                                    env.suggestions.recordOutcome(
                                        intentId: guess.intent.id,
                                        rawScore: guess.rawScore,
                                        accepted: false
                                    )
                                    model.dismiss(intentId: guess.intent.id)
                                    refreshGuesses(model)
                                }
                            )
                        }
                    }
                }

                // Intent grid, frequency-sorted, searchable.
                VStack(alignment: .leading, spacing: 8) {
                    Text("What did he mean? One tap saves. Hold a word to mark it as a wrong guess.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("Search his words", text: $search)
                        .textFieldStyle(.roundedBorder)

                    let candidates = model.candidates(from: intents, counts: counts)
                        .filter { search.isEmpty || $0.label.localizedCaseInsensitiveContains(search) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
                        ForEach(candidates) { intent in
                            IntentCell(intent: intent)
                                .onTapGesture { confirm(intent, with: model) }
                                .onLongPressGesture { model.dismiss(intentId: intent.id) }
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
            .padding(16)
        }
        .sheet(isPresented: $showingAskBoard) {
            // The Ask flow (§4.3): he answers on his board mid-exchange;
            // his selection resolves the exchange with the same audio.
            NavigationStack {
                BoardView(intents: (try? env.board.boardIntents()) ?? [], mode: .ask { intent in
                    showingAskBoard = false
                    confirm(intent, with: model)
                }) { intent in
                    try? env.events.log(EventRecord(
                        exchangeId: model.exchangeId,
                        type: .boardTap,
                        intentId: intent.id,
                        device: env.capture.stationName
                    ))
                }
                .navigationTitle("His board")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    private func refreshGuesses(_ model: ConfirmViewModel) {
        Task {
            topGuesses = await env.suggestions.suggestions(
                for: model.selectedSegments,
                station: env.capture.stationName,
                excluding: model.dismissedIntentIds
            )
        }
    }

    private func confirm(_ intent: IntentRecord, with model: ConfirmViewModel) {
        guard let created = try? model.confirm(intentId: intent.id), !created.isEmpty else { return }
        savedBanner = "Saved \(created.count) clip\(created.count == 1 ? "" : "s") as “\(intent.label)”"
        topGuesses = []
        env.capture.clearRecentSegments()
        Task { await env.suggestions.reload() }
        // Keep the banner visible briefly on the emptied card.
        Task {
            try? await Task.sleep(for: .seconds(3))
            savedBanner = nil
            reload()
        }
        reload()
    }

    private func skip(_ model: ConfirmViewModel) {
        model.skip()
        topGuesses = []
        env.capture.clearRecentSegments()
        reload()
    }

    private func reload() {
        intents = (try? env.intents.all()) ?? []
        counts = (try? env.events.confirmCounts()) ?? [:]
        let segments = env.capture.recentSegments.filter {
            $0.segmentState == .pending
        }
        if segments.isEmpty {
            model = nil
        } else if model == nil || model?.segments.map(\.id) != segments.map(\.id) {
            model = ConfirmViewModel(
                segments: segments,
                exchangeId: segments.first?.sessionId,
                exchangeOpenedAt: env.capture.activeSessionOpenedAt,
                device: env.capture.stationName,
                labeller: env.labeller,
                db: env.db
            )
            if let model { refreshGuesses(model) }
        }
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
                    Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                        .font(.title2)
                    Text(String(format: "%.1fs", Double(segment.durationMs) / 1000))
                        .font(.callout.monospacedDigit())
                }
            }
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

struct IntentCell: View {
    let intent: IntentRecord

    var body: some View {
        VStack(spacing: 6) {
            if let ref = intent.photoRef,
               let image = UIImage(contentsOfFile: FileLocations.photoURL(id: ref).path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
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
