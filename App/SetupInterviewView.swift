import SwiftUI
import UniformTypeIdentifiers

/// The guided onboarding (§4.1): builds the 20–30 intent seed dictionary in
/// about 15 minutes. Every intent gets a label, optionally a photo of his
/// real object and a respond-note for guests. Near-duplicate labels are
/// flagged with a merge/keep choice, and the finished list is shareable as a
/// one-page summary for his SLP.
///
/// State auto-saves at every step (§7, D4): each word is inserted (and
/// placed on the board) the moment it is added, the labeller and station
/// are saved as typed, and a relaunch with words already saved resumes at
/// the summary instead of starting over — the camera is the classic
/// memory-pressure kill on an old phone.
@MainActor
struct SetupInterviewView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var step: Step = .intro
    @State private var intents: [IntentRecord] = []
    @State private var labellerName = ""
    @State private var stationName = ""
    @State private var importer = ImportController()
    @State private var showingRestore = false
    @State private var hasRestoredProgress = false
    @State private var slpSummary = ""

    enum Step {
        case intro, family, intents, summary
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .intro: intro
                case .family: family
                case .intents:
                    IntentEntryStep(
                        intents: intents,
                        onAdd: { label, photoRef, note in add(label: label, photoRef: photoRef, respondNote: note) },
                        onRemove: { intent in remove(intent) },
                        onDone: { step = .summary }
                    )
                case .summary: summary
                }
            }
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
            .fileImporter(
                isPresented: $showingRestore,
                allowedContentTypes: [.folder, .json]
            ) { result in
                switch result {
                case .success(let url):
                    importer.run(url: url, env: env) {
                        reloadIntents()
                        if !intents.isEmpty {
                            step = .summary
                        }
                    }
                case .failure(let error):
                    importer.message = error.localizedDescription
                }
            }
            .alert("Restore", isPresented: Binding(
                get: { importer.message != nil },
                set: { if !$0 { importer.message = nil } }
            )) {
                Button("OK") { importer.message = nil }
            } message: {
                Text(importer.message ?? "")
            }
        }
        .onAppear(perform: restoreProgress)
    }

    // MARK: Steps

    private var intro: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Build his dictionary")
                    .font(.largeTitle.bold())
                    .padding(.top, 24)
                Text("Think of the 20 to 30 things he communicates most often — wants, places, people, feelings. For each one you'll give it a name, and can add a photo of his actual object and a note telling a new person how to respond.")
                Text("This takes about 15 minutes and works best with everyone who knows him in the room. Everything saves as you go, and you can add and change words any time later in Dictionary.")
                    .foregroundStyle(.secondary)
                Text("Bring the finished list to his speech-language pathologist — there's a share button at the end for exactly that.")
                    .foregroundStyle(.secondary)
                Button("Start") { step = .family }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)

                Button {
                    showingRestore = true
                } label: {
                    if importer.isRunning {
                        HStack {
                            ProgressView()
                            Text("Restoring…")
                        }
                    } else {
                        Label("Moving from another phone? Restore an export", systemImage: "square.and.arrow.down")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(importer.isRunning)
                .frame(maxWidth: .infinity)
                Text("Tap the export zip in Files to unzip it, then choose the folder it creates.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }

    private var family: some View {
        Form {
            Section {
                TextField("Your name", text: $labellerName)
                    .onChange(of: labellerName) {
                        let trimmed = labellerName.trimmingCharacters(in: .whitespaces)
                        env.labeller = trimmed.isEmpty ? "Parent" : trimmed
                    }
            } header: {
                Text("Who is setting up?")
            } footer: {
                Text("Labels get tagged with who confirmed them, so knowing it was Mom vs. Grandma vs. his sister means something later.")
            }
            Section {
                TextField("e.g. Kitchen", text: $stationName)
                    .onChange(of: stationName) {
                        let trimmed = stationName.trimmingCharacters(in: .whitespaces)
                        env.capture.stationName = trimmed.isEmpty ? "Home" : trimmed
                    }
            } header: {
                Text("Where will this device usually live?")
            } footer: {
                Text("The same word often means different things in different rooms. Naming the station helps the app use that.")
            }
            Button("Next: his words") {
                step = .intents
            }
        }
    }

    private var summary: some View {
        List {
            Section {
                ForEach(intents) { intent in
                    HStack {
                        Text(intent.label)
                        Spacer()
                        if intent.photoRef != nil {
                            Image(systemName: "photo").foregroundStyle(.secondary)
                                .accessibilityLabel("Has a photo")
                        }
                        if let note = intent.respondNote, !note.isEmpty {
                            Image(systemName: "text.bubble").foregroundStyle(.secondary)
                                .accessibilityLabel("Has a respond note")
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets where index < intents.count {
                        remove(intents[index])
                    }
                }
            } header: {
                Text("\(intents.count) words in his seed dictionary")
            } footer: {
                if intents.count < 20 {
                    Text("The sweet spot is 20–30 words, but you can start smaller and grow in Dictionary.")
                }
            }

            Section {
                ShareLink(item: slpSummary) {
                    Label("Share seed list for his SLP", systemImage: "square.and.arrow.up")
                }
                .disabled(slpSummary.isEmpty)
            } footer: {
                Text("A one-page text summary — no audio, no photos — for validating the vocabulary with his speech-language pathologist. It is also in Settings later, once there is a week of data behind it.")
            }

            Section {
                Button("Finish setup") { finish() }
                    .font(.headline)
                    .disabled(intents.isEmpty)
                Button("Add more words") { step = .intents }
            }
        }
    }

    // MARK: Persistence

    /// Picks up where a killed or relaunched setup left off: names from
    /// their stores, and the summary step if words were already saved.
    private func restoreProgress() {
        guard !hasRestoredProgress else { return }
        hasRestoredProgress = true
        labellerName = env.labeller == "Parent" ? "" : env.labeller
        stationName = env.capture.stationName == "Home" ? "" : env.capture.stationName
        reloadIntents()
        if !intents.isEmpty {
            step = .summary
        }
    }

    private func reloadIntents() {
        intents = ((try? env.intents.all()) ?? []).sorted { $0.createdAt < $1.createdAt }
        slpSummary = SeedListSummary.text(db: env.db, labeller: env.labeller)
    }

    private func add(label: String, photoRef: String?, respondNote: String) {
        let intent = IntentRecord(
            label: label,
            photoRef: photoRef,
            respondNote: respondNote.isEmpty ? nil : respondNote
        )
        do {
            try env.intents.insert(intent)
            try env.board.place(intentId: intent.id)
        } catch {
            // The next add retries; nothing in memory to lose.
        }
        reloadIntents()
    }

    /// Swipe-delete during setup archives rather than deletes, so a word
    /// removed by mistake is recoverable and nothing on disk is destroyed
    /// before the family has even started.
    private func remove(_ intent: IntentRecord) {
        try? env.intents.archive(id: intent.id)
        reloadIntents()
    }

    private func finish() {
        env.hasCompletedSetupInterview = true
    }
}

// MARK: - SLP seed summary

/// One-page seed summary for the SLP conversation (§4.1), built from the
/// database so it is available at any time (D4) and carries how often each
/// word has come up. Text, so it shares anywhere; deliberately contains no
/// audio or images.
enum SeedListSummary {
    static func text(db: AppDatabase, labeller: String, now: Date = Date()) -> String {
        let intents = ((try? IntentStore(db: db).all()) ?? []).sorted { $0.createdAt < $1.createdAt }
        let confirmCounts = (try? EventLog(db: db).confirmCounts()) ?? [:]
        let exemplars = ExemplarStore(db: db)
        let totalClips = (try? exemplars.totalCount()) ?? 0

        var lines: [String] = [
            "Rosetta vocabulary — \(intents.count) intents, \(totalClips) confirmed clip\(totalClips == 1 ? "" : "s")",
            "Prepared \(now.formatted(date: .abbreviated, time: .omitted)) by \(labeller.isEmpty ? "the family" : labeller)",
            "",
            "These are the things he communicates most often, as labelled by his family. Each becomes a class in a private, on-device communication dictionary. Counts are how many times the family has confirmed that meaning. Please flag anything to merge, split, rename, or add.",
            "",
        ]
        for (index, intent) in intents.enumerated() {
            var line = "\(index + 1). \(intent.label)"
            let clips = (try? exemplars.count(intentId: intent.id)) ?? 0
            let confirmations = confirmCounts[intent.id] ?? 0
            if clips > 0 || confirmations > 0 {
                line += " — \(clips) clip\(clips == 1 ? "" : "s"), confirmed \(confirmations) time\(confirmations == 1 ? "" : "s")"
            }
            if let note = intent.respondNote, !note.isEmpty {
                line += " — respond: \(note)"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Intent entry step

private struct IntentEntryStep: View {
    let intents: [IntentRecord]
    let onAdd: (_ label: String, _ photoRef: String?, _ respondNote: String) -> Void
    let onRemove: (IntentRecord) -> Void
    let onDone: () -> Void

    @State private var label = ""
    @State private var respondNote = ""
    @State private var photoRef: String?
    @State private var showingPhotoSource = false
    @State private var photoSource: PhotoCapture.Source?
    @State private var conflictLabels: [String] = []

    /// Prompt categories, shown as gentle hints — the family knows him.
    private let prompts = [
        "Foods and drinks he asks for",
        "Places (bathroom, outside, his room)",
        "People he asks about",
        "Activities (tablet, trampoline, a show)",
        "Feelings (hurt, tired, done)",
        "Phrases that mean something private to him",
    ]

    var body: some View {
        Form {
            Section {
                DisclosureGroup("Ideas if you're stuck") {
                    ForEach(prompts, id: \.self) { prompt in
                        Text(prompt).foregroundStyle(.secondary)
                    }
                }
            }

            Section("New word") {
                TextField("What the family calls it (e.g. banana)", text: $label)
                    .textInputAutocapitalization(.never)

                if let photoRef {
                    HStack {
                        CachedPhoto(ref: photoRef)
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Button("Remove photo", role: .destructive) { self.photoRef = nil }
                    }
                } else {
                    Button {
                        showingPhotoSource = true
                    } label: {
                        Label("Add a photo of his actual object", systemImage: "camera")
                    }
                }

                TextField("How should a new person respond? (optional)", text: $respondNote, axis: .vertical)
            }

            Section {
                Button("Add word") { tryAdd() }
                    .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Section("Added so far (\(intents.count))") {
                ForEach(intents) { intent in
                    Text(intent.label)
                }
                .onDelete { offsets in
                    for index in offsets where index < intents.count {
                        onRemove(intents[index])
                    }
                }
            }

            Section {
                Button("Done adding words") { onDone() }
                    .disabled(intents.isEmpty)
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
        .alert("Similar word already added", isPresented: .init(
            get: { !conflictLabels.isEmpty },
            set: { if !$0 { conflictLabels = [] } }
        )) {
            Button("Keep both") {
                commitAdd()
                conflictLabels = []
            }
            Button("Don't add — use \"\(conflictLabels.first ?? "")\"", role: .cancel) {
                clearEntry()
                conflictLabels = []
            }
        } message: {
            Text("\"\(label)\" looks close to \(conflictLabels.map { "\"\($0)\"" }.joined(separator: ", ")). If different caregivers use different words for the same thing, his words get split across labels and learning suffers. Merge them unless they really are different things.")
        }
    }

    private func tryAdd() {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let conflicts = LabelSimilarity.conflicts(for: trimmed, in: intents.map(\.label))
        if conflicts.isEmpty {
            commitAdd()
        } else {
            conflictLabels = conflicts
        }
    }

    private func commitAdd() {
        onAdd(
            label.trimmingCharacters(in: .whitespaces),
            photoRef,
            respondNote.trimmingCharacters(in: .whitespaces)
        )
        clearEntry()
    }

    private func clearEntry() {
        label = ""
        respondNote = ""
        photoRef = nil
    }
}

extension PhotoCapture.Source: Identifiable {
    var id: String {
        switch self {
        case .camera: return "camera"
        case .library: return "library"
        }
    }
}
