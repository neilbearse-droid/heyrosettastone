import SwiftUI

/// The guided onboarding (§4.1): builds the 20–30 intent seed dictionary in
/// about 15 minutes. Every intent gets a label, optionally a photo of his
/// real object and a respond-note for guests. Near-duplicate labels are
/// flagged with a merge/keep choice, and the finished list is shareable as a
/// one-page summary for his SLP.
struct SetupInterviewView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model = SetupInterviewModel()
    @State private var step: Step = .intro

    enum Step {
        case intro, family, intents, summary
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .intro: intro
                case .family: family
                case .intents: IntentEntryStep(model: model, onDone: { step = .summary })
                case .summary: summary
                }
            }
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: Steps

    private var intro: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Build his dictionary")
                    .font(.largeTitle.bold())
                    .padding(.top, 24)
                Text("Think of the 20 to 30 things he communicates most often — wants, places, people, feelings. For each one you'll give it a name, and can add a photo of his actual object and a note telling a new person how to respond.")
                Text("This takes about 15 minutes and works best with everyone who knows him in the room. You can add and change words any time later in Dictionary.")
                    .foregroundStyle(.secondary)
                Text("Bring the finished list to his speech-language pathologist — there's a share button at the end for exactly that.")
                    .foregroundStyle(.secondary)
                Button("Start") { step = .family }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
            }
            .padding(24)
        }
    }

    private var family: some View {
        Form {
            Section {
                TextField("Your name", text: $model.labellerName)
            } header: {
                Text("Who is setting up?")
            } footer: {
                Text("Labels get tagged with who confirmed them, so knowing it was Mom vs. Grandma vs. his sister means something later.")
            }
            Section {
                TextField("e.g. Kitchen", text: $model.stationName)
            } header: {
                Text("Where will this device usually live?")
            } footer: {
                Text("The same word often means different things in different rooms. Naming the station helps the app use that.")
            }
            Button("Next: his words") {
                env.labeller = model.labellerName.isEmpty ? "Parent" : model.labellerName
                env.capture.stationName = model.stationName.isEmpty ? "Home" : model.stationName
                step = .intents
            }
        }
    }

    private var summary: some View {
        List {
            Section {
                ForEach(model.drafts) { draft in
                    HStack {
                        Text(draft.label)
                        Spacer()
                        if draft.photoRef != nil {
                            Image(systemName: "photo").foregroundStyle(.secondary)
                        }
                        if !(draft.respondNote.isEmpty) {
                            Image(systemName: "text.bubble").foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("\(model.drafts.count) words in his seed dictionary")
            } footer: {
                if model.drafts.count < 20 {
                    Text("The spec sweet spot is 20–30 words, but you can start smaller and grow in Dictionary.")
                }
            }

            Section {
                ShareLink(item: model.slpSummary()) {
                    Label("Share seed list for his SLP", systemImage: "square.and.arrow.up")
                }
            } footer: {
                Text("A one-page text summary — no audio, no photos — for validating the vocabulary with his speech-language pathologist.")
            }

            Section {
                Button("Finish setup") { finish() }
                    .font(.headline)
                    .disabled(model.drafts.isEmpty)
                Button("Add more words") { step = .intents }
            }
        }
    }

    private func finish() {
        for draft in model.drafts {
            let intent = IntentRecord(
                label: draft.label,
                photoRef: draft.photoRef,
                respondNote: draft.respondNote.isEmpty ? nil : draft.respondNote
            )
            try? env.intents.insert(intent)
            try? env.board.place(intentId: intent.id)
        }
        env.hasCompletedSetupInterview = true
    }
}

// MARK: - Model

@Observable
final class SetupInterviewModel {
    struct Draft: Identifiable {
        let id = UUID()
        var label: String
        var photoRef: String?
        var respondNote: String = ""
    }

    var labellerName = ""
    var stationName = ""
    var drafts: [Draft] = []

    /// Near-duplicate labels of `candidate` among the drafts so far (§4.1).
    func conflicts(for candidate: String) -> [String] {
        LabelSimilarity.conflicts(for: candidate, in: drafts.map(\.label))
    }

    func add(label: String, photoRef: String?, respondNote: String) {
        drafts.append(Draft(label: label, photoRef: photoRef, respondNote: respondNote))
    }

    /// One-page seed summary for the SLP conversation (§4.1). Text, so it
    /// shares anywhere; deliberately contains no audio or images.
    func slpSummary() -> String {
        var lines: [String] = [
            "Rosetta seed vocabulary — \(drafts.count) intents",
            "Prepared \(Date().formatted(date: .abbreviated, time: .omitted)) by \(labellerName.isEmpty ? "the family" : labellerName)",
            "",
            "These are the things he communicates most often, as labelled by his family. Each becomes a class in a private, on-device communication dictionary. Please flag anything to merge, split, rename, or add.",
            "",
        ]
        for (index, draft) in drafts.enumerated() {
            var line = "\(index + 1). \(draft.label)"
            if !draft.respondNote.isEmpty {
                line += " — respond: \(draft.respondNote)"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Intent entry step

private struct IntentEntryStep: View {
    @Bindable var model: SetupInterviewModel
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

                if let photoRef,
                   let image = UIImage(contentsOfFile: FileLocations.photoURL(id: photoRef).path) {
                    HStack {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
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

            Section("Added so far (\(model.drafts.count))") {
                ForEach(model.drafts) { draft in
                    Text(draft.label)
                }
                .onDelete { model.drafts.remove(atOffsets: $0) }
            }

            Section {
                Button("Done adding words") { onDone() }
                    .disabled(model.drafts.isEmpty)
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
                photoRef = ref
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
        let conflicts = model.conflicts(for: trimmed)
        if conflicts.isEmpty {
            commitAdd()
        } else {
            conflictLabels = conflicts
        }
    }

    private func commitAdd() {
        model.add(
            label: label.trimmingCharacters(in: .whitespaces),
            photoRef: photoRef,
            respondNote: respondNote.trimmingCharacters(in: .whitespaces)
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
