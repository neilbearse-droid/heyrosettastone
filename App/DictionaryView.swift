import SwiftUI

/// Intent management (§3): the dictionary itself. Add, edit, archive, and
/// delete intents; browse and prune individual exemplars so one mislabelled
/// clip can't quietly poison a class (§5.2).
struct DictionaryView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var intents: [IntentRecord] = []
    @State private var exemplarCounts: [String: Int] = [:]
    @State private var addingNew = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(intents) { intent in
                    NavigationLink(value: intent.id) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(intent.label).font(.headline)
                                if let note = intent.respondNote, !note.isEmpty {
                                    Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            Text("\(exemplarCounts[intent.id] ?? 0)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                            if intent.boardSlot != nil {
                                Image(systemName: "square.grid.2x2")
                                    .font(.caption)
                                    .foregroundStyle(.tint)
                                    .accessibilityLabel("On his board")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Dictionary")
            .navigationDestination(for: String.self) { intentId in
                IntentDetailView(intentId: intentId, onChange: reload)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { addingNew = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add a word")
                }
            }
            .sheet(isPresented: $addingNew) {
                IntentEditorSheet(intent: nil) { reload() }
            }
            .onAppear(perform: reload)
        }
    }

    private func reload() {
        intents = (try? env.intents.all()) ?? []
        var counts: [String: Int] = [:]
        for intent in intents {
            counts[intent.id] = (try? env.exemplars.count(intentId: intent.id)) ?? 0
        }
        exemplarCounts = counts
    }
}

// MARK: - Detail

@MainActor
struct IntentDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let intentId: String
    let onChange: () -> Void

    @State private var intent: IntentRecord?
    @State private var exemplars: [ExemplarRecord] = []
    @State private var player = ClipPlayer()
    @State private var editing = false
    @State private var confirmingDelete = false

    var body: some View {
        List {
            if let intent {
                Section {
                    if let ref = intent.photoRef {
                        CachedPhoto(ref: ref)
                            .frame(maxWidth: .infinity)
                            .frame(height: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .listRowInsets(EdgeInsets())
                    }
                    if let note = intent.respondNote, !note.isEmpty {
                        LabeledContent("How to respond", value: note)
                    }
                }

                Section {
                    if intent.boardSlot != nil {
                        LabeledContent("On his board", value: "Slot \((intent.boardSlot ?? 0) + 1)")
                        Button("Remove from board", role: .destructive) {
                            try? env.board.remove(intentId: intent.id)
                            refresh()
                        }
                    } else {
                        Button("Add to his board") {
                            try? env.board.place(intentId: intent.id)
                            refresh()
                        }
                    }
                } footer: {
                    Text("New buttons take the first empty spot. Existing buttons never move — his hands know where they are.")
                }

                Section {
                    if exemplars.isEmpty {
                        Text("None yet. Clips arrive when you confirm exchanges.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(exemplars) { exemplar in
                        exemplarRow(exemplar)
                    }
                    .onDelete { offsets in
                        // Pruning deletes the audio too (B3); the segment row
                        // stays as a tombstone.
                        for index in offsets where index < exemplars.count {
                            let exemplar = exemplars[index]
                            if player.playingClipRef == exemplar.clipRef {
                                player.stop()
                            }
                            try? env.exemplars.delete(id: exemplar.id, deleteClip: true)
                        }
                        let suggestions = env.suggestions
                        Task { await suggestions.reload() }
                        refresh()
                        onChange()
                    }
                } header: {
                    Text("Confirmed clips (\(exemplars.count))")
                } footer: {
                    Text("Swipe a clip to delete it and its recording — one mislabelled clip should not teach the wrong word.")
                }

                Section {
                    Button("Delete this word and its clips", role: .destructive) {
                        confirmingDelete = true
                    }
                }
            }
        }
        .navigationTitle(intent?.label ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { editing = true }
            }
        }
        .sheet(isPresented: $editing) {
            IntentEditorSheet(intent: intent) {
                refresh()
                onChange()
            }
        }
        .alert("Delete “\(intent?.label ?? "")”?", isPresented: $confirmingDelete) {
            Button("Delete forever", role: .destructive) {
                player.stop()
                if let removedPhoto = try? env.intents.deleteForever(id: intentId) {
                    PhotoCache.shared.invalidate(ref: removedPhoto)
                }
                let suggestions = env.suggestions
                Task { await suggestions.reload() }
                onChange()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the word, its board button, and every confirmed clip of it, recordings included. This cannot be undone.")
        }
        .onAppear(perform: refresh)
    }

    private func exemplarRow(_ exemplar: ExemplarRecord) -> some View {
        let deleted = FileLocations.isDeleted(clipRef: exemplar.clipRef)
        return HStack {
            Button {
                player.toggle(clipRef: exemplar.clipRef)
            } label: {
                Image(systemName: deleted
                    ? "speaker.slash"
                    : (player.playingClipRef == exemplar.clipRef ? "stop.circle.fill" : "play.circle.fill"))
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(deleted)
            .accessibilityLabel(deleted ? "Recording deleted" : (player.playingClipRef == exemplar.clipRef ? "Stop" : "Play clip"))
            VStack(alignment: .leading) {
                Text(exemplar.capturedAt.formatted(date: .abbreviated, time: .shortened))
                Text("\(exemplar.labeller) · \(exemplar.device)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func refresh() {
        intent = try? env.intents.fetch(id: intentId)
        exemplars = (try? env.exemplars.forIntent(intentId)) ?? []
    }
}

// MARK: - Editor (add / edit)

struct IntentEditorSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let intent: IntentRecord?
    let onSave: () -> Void

    @State private var label = ""
    @State private var respondNote = ""
    @State private var photoRef: String?
    @State private var photoSource: PhotoCapture.Source?
    @State private var showingPhotoSource = false
    @State private var conflictLabels: [String] = []
    @State private var addToBoard = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Word") {
                    TextField("Label (e.g. banana)", text: $label)
                    TextField("How should a new person respond? (optional)",
                              text: $respondNote, axis: .vertical)
                }
                Section("Photo") {
                    if let photoRef {
                        HStack {
                            CachedPhoto(ref: photoRef)
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            Button("Remove", role: .destructive) { self.photoRef = nil }
                        }
                    } else {
                        Button {
                            showingPhotoSource = true
                        } label: {
                            Label("Add a photo of his actual object", systemImage: "camera")
                        }
                    }
                }
                if intent == nil {
                    Section {
                        Toggle("Add to his board", isOn: $addToBoard)
                    }
                }
            }
            .navigationTitle(intent == nil ? "New word" : "Edit word")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { trySave() }
                        .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("Add a photo", isPresented: $showingPhotoSource) {
                if PhotoCapture.cameraAvailable() {
                    Button("Take photo") { photoSource = .camera }
                }
                Button("Choose from library") { photoSource = .library }
            }
            .sheet(item: $photoSource) { source in
                PhotoCapture(source: source) { ref in
                    if let ref {
                        photoRef = ref
                    }
                    photoSource = nil
                }
            }
            .alert("Similar word exists", isPresented: .init(
                get: { !conflictLabels.isEmpty },
                set: { if !$0 { conflictLabels = [] } }
            )) {
                Button("Save anyway") {
                    conflictLabels = []
                    save()
                }
                Button("Cancel", role: .cancel) { conflictLabels = [] }
            } message: {
                Text("\"\(label)\" looks close to \(conflictLabels.map { "\"\($0)\"" }.joined(separator: ", ")). Splitting one meaning across two labels makes both harder to learn.")
            }
            .onAppear {
                if let intent {
                    label = intent.label
                    respondNote = intent.respondNote ?? ""
                    photoRef = intent.photoRef
                }
            }
        }
    }

    private func trySave() {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        let existing = ((try? env.intents.all()) ?? [])
            .filter { $0.id != intent?.id }
            .map(\.label)
        let conflicts = LabelSimilarity.conflicts(for: trimmed, in: existing)
        if conflicts.isEmpty {
            save()
        } else {
            conflictLabels = conflicts
        }
    }

    private func save() {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        let note = respondNote.trimmingCharacters(in: .whitespaces)
        if let intent {
            try? env.intents.updateDetails(
                id: intent.id,
                label: trimmed,
                photoRef: photoRef,
                respondNote: note.isEmpty ? nil : note
            )
        } else {
            let record = IntentRecord(
                label: trimmed,
                photoRef: photoRef,
                respondNote: note.isEmpty ? nil : note
            )
            try? env.intents.insert(record)
            if addToBoard {
                try? env.board.place(intentId: record.id)
            }
        }
        onSave()
        dismiss()
    }
}
