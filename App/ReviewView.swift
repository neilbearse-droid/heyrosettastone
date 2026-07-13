import SwiftUI

/// Evening batch labelling (§4.4). Each pending segment: play, then one tap
/// to label, discard, or mark "not him". Segments expire out of the queue
/// after 24 hours — kept on disk, flagged unlabelled — because memory of
/// what he meant goes stale.
struct ReviewView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var pending: [SegmentRecord] = []
    @State private var expiredCount = 0
    @State private var player = ClipPlayer()
    @State private var labelling: SegmentRecord?

    var body: some View {
        NavigationStack {
            Group {
                if pending.isEmpty {
                    ContentUnavailableView(
                        "Queue is clear",
                        systemImage: "tray",
                        description: Text(emptyDescription)
                    )
                } else {
                    List {
                        Section {
                            ForEach(pending) { segment in
                                row(segment)
                            }
                        } footer: {
                            Text("Clips leave this queue 24 hours after capture — label while you still remember the moment. Nothing is deleted; expired clips stay on the device.")
                        }
                    }
                }
            }
            .navigationTitle("Review")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    RecordingIndicator(isListening: env.capture.isListening)
                }
            }
            .sheet(item: $labelling) { segment in
                IntentPickerSheet { intent in
                    label(segment, as: intent)
                    labelling = nil
                }
            }
            .onAppear(perform: reload)
        }
    }

    private var emptyDescription: String {
        expiredCount > 0
            ? "Nothing waiting. \(expiredCount) unlabelled clip\(expiredCount == 1 ? "" : "s") expired and stay stored on this device."
            : "Skipped exchanges land here for labelling in the evening."
    }

    private func row(_ segment: SegmentRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    player.toggle(clipRef: segment.clipRef)
                } label: {
                    Image(systemName: player.playingClipRef == segment.clipRef
                        ? "stop.circle.fill" : "play.circle.fill")
                        .font(.largeTitle)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading) {
                    Text(segment.startedAt.formatted(date: .omitted, time: .shortened))
                        .font(.headline)
                    Text("\(String(format: "%.1f", Double(segment.durationMs) / 1000))s · expires \(expiryText(segment))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 10) {
                Button("Label") { labelling = segment }
                    .buttonStyle(.borderedProminent)
                Button("Not him") { resolve(segment, as: .notHim) }
                    .buttonStyle(.bordered)
                Button("Discard", role: .destructive) { resolve(segment, as: .discarded) }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 6)
    }

    private func expiryText(_ segment: SegmentRecord) -> String {
        let expiry = segment.startedAt.addingTimeInterval(ReviewQueue.expiryInterval)
        return expiry.formatted(.relative(presentation: .named))
    }

    private func label(_ segment: SegmentRecord, as intent: IntentRecord) {
        _ = try? env.exemplars.confirm(
            segments: [segment],
            intentId: intent.id,
            device: env.capture.stationName,
            labeller: env.labeller
        )
        try? env.events.log(EventRecord(
            exchangeId: segment.sessionId,
            type: .confirm,
            intentId: intent.id,
            device: env.capture.stationName
        ))
        reload()
    }

    private func resolve(_ segment: SegmentRecord, as state: SegmentState) {
        try? env.sessions.updateSegmentState(id: segment.id, state: state)
        reload()
    }

    private func reload() {
        pending = (try? env.review.pending()) ?? []
        expiredCount = (try? env.review.expired().count) ?? 0
    }
}

/// Frequency-sorted, searchable intent picker used by Review.
struct IntentPickerSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let onPick: (IntentRecord) -> Void

    @State private var search = ""
    @State private var intents: [IntentRecord] = []
    @State private var counts: [String: Int] = [:]

    var body: some View {
        NavigationStack {
            List {
                ForEach(filtered) { intent in
                    Button {
                        onPick(intent)
                    } label: {
                        HStack {
                            Text(intent.label)
                            Spacer()
                            if let count = counts[intent.id], count > 0 {
                                Text("\(count)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Search his words")
            .navigationTitle("What did he mean?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                intents = (try? env.intents.all()) ?? []
                counts = (try? env.events.confirmCounts()) ?? [:]
            }
        }
    }

    private var filtered: [IntentRecord] {
        FrequencyRanker.rank(intents: intents, counts: counts)
            .filter { search.isEmpty || $0.label.localizedCaseInsensitiveContains(search) }
    }
}
