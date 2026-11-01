import SwiftUI
import UniformTypeIdentifiers

// MARK: - Settings

@MainActor
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var labeller = ""
    @State private var station = ""
    @State private var includeAudioInBackup = UserDefaults.standard.bool(forKey: "includeAudioInBackup")
    @State private var export = ExportController()
    @State private var importer = ImportController()
    @State private var showingImporter = false
    @State private var storageLine: String?
    @State private var slpSummary = ""
    @State private var confirmingWipe = false
    @State private var isWiping = false
    @State private var wipeError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("This device") {
                    TextField("Who's labelling (e.g. Mom)", text: $labeller)
                        .onSubmit { env.labeller = labeller }
                    TextField("Station name (e.g. Kitchen)", text: $station)
                        .onSubmit { env.capture.stationName = station }
                }

                Section {
                    VoicePickerRow()
                } header: {
                    Text("Board voice")
                } footer: {
                    Text("His choice, if he shows a preference.")
                }

                Section {
                    Toggle("Include audio in device backups", isOn: $includeAudioInBackup)
                        .onChange(of: includeAudioInBackup) {
                            UserDefaults.standard.set(includeAudioInBackup, forKey: "includeAudioInBackup")
                            try? FileLocations.setAudioBackupInclusion(includeAudioInBackup)
                        }
                } footer: {
                    Text("Off means his voice recordings never leave this device, not even inside an iCloud or computer backup. Turn on only if you want recordings restored when moving phones.")
                }

                Section {
                    ShareLink(item: slpSummary) {
                        Label("Share seed list for his SLP", systemImage: "square.and.arrow.up")
                    }
                    .disabled(slpSummary.isEmpty)
                } header: {
                    Text("His words")
                } footer: {
                    Text("A one-page text summary of his dictionary with how often each word has come up — no audio, no photos — for his speech-language pathologist.")
                }

                Section {
                    if let storageLine {
                        LabeledContent("On this phone", value: storageLine)
                    }

                    Button {
                        export.run(env.exporter)
                    } label: {
                        if let progress = export.progress {
                            HStack {
                                ProgressView(value: progress)
                                Text("Preparing…")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Label("Export everything (zip)", systemImage: "square.and.arrow.up")
                        }
                    }
                    .disabled(export.isRunning)
                    if let error = export.error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }

                    Button {
                        showingImporter = true
                    } label: {
                        if importer.isRunning {
                            HStack {
                                ProgressView()
                                Text("Restoring…")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Label("Restore from an export", systemImage: "square.and.arrow.down")
                        }
                    }
                    .disabled(importer.isRunning)

                    Button(role: .destructive) {
                        confirmingWipe = true
                    } label: {
                        if isWiping {
                            HStack {
                                ProgressView()
                                Text("Deleting…")
                            }
                        } else {
                            Label("Delete everything", systemImage: "trash")
                        }
                    }
                    .disabled(isWiping)
                    if let wipeError {
                        Text(wipeError).font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("His data")
                } footer: {
                    Text("Restoring adds what is missing from a Rosetta export and never overwrites anything already here. Tap the zip in Files to unzip it first, then choose the folder.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if !labeller.isEmpty { env.labeller = labeller }
                        if !station.isEmpty { env.capture.stationName = station }
                        dismiss()
                    }
                }
            }
            .sheet(item: Bindable(export).result) { item in
                ActivityShareSheet(item: item)
            }
            // Folder only: a security-scoped URL to rosetta.json alone does
            // not grant access to the clips/ and photos/ beside it, so a
            // JSON pick would restore rows and silently copy no audio.
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.folder]
            ) { result in
                switch result {
                case .success(let url):
                    importer.run(url: url, env: env) {
                        refreshStorage()
                        refreshSLPSummary()
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
            .alert("Delete everything?", isPresented: $confirmingWipe) {
                Button("Delete all data", role: .destructive) { wipeEverything() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every word, clip, photo, and log on this device is erased permanently. There is no cloud copy and no undo.")
            }
            .onAppear {
                labeller = env.labeller
                station = env.capture.stationName
                refreshStorage()
                refreshSLPSummary()
            }
        }
    }

    /// Full local deletion (§8), then everything that still held the old
    /// rows in memory is reset (B4): capture's chips and open session, the
    /// backfill's missing-clip memory, the ranking index, and the setup
    /// flag the views read.
    private func wipeEverything() {
        guard !isWiping else { return }
        isWiping = true
        wipeError = nil
        env.capture.pauseListening()
        env.capture.clearRecentSegments()
        let exporter = env.exporter
        Task {
            let failure: String? = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try exporter.wipeAll()
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            // Again after the delete: pausing cuts any utterance in
            // progress, and its chip is appended to recentSegments on the
            // main actor after the clear above ran.
            env.capture.clearRecentSegments()
            MissingClipRegistry.shared.removeAll()
            PhotoCache.shared.removeAll()
            await env.suggestions.reload()
            isWiping = false
            if let failure {
                wipeError = failure
                refreshStorage()
            } else {
                env.hasCompletedSetupInterview = false
                dismiss()
            }
        }
    }

    /// "N clips, X MB" (B5), computed off the main thread: it walks the
    /// clips directory.
    private func refreshStorage() {
        Task {
            let summary = await Task.detached(priority: .utility) {
                try? Maintenance.storageSummary()
            }.value
            guard let summary else {
                storageLine = nil
                return
            }
            let audio = ByteCountFormatter.string(fromByteCount: summary.bytes, countStyle: .file)
            var line = "\(summary.clipCount) clip\(summary.clipCount == 1 ? "" : "s"), \(audio)"
            if summary.photoBytes > 0 {
                let photos = ByteCountFormatter.string(fromByteCount: summary.photoBytes, countStyle: .file)
                line += " + \(photos) of photos"
            }
            storageLine = line
        }
    }

    private func refreshSLPSummary() {
        slpSummary = SeedListSummary.text(db: env.db, labeller: env.labeller)
    }
}

/// Voice selection with an audition — each candidate voice speaks a sample
/// when selected, so he can pick by ear. Uses the app's one long-lived
/// synthesizer so the sample is not cut off when the row goes away (D7).
struct VoicePickerRow: View {
    @Environment(AppEnvironment.self) private var env
    @State private var selection = UserDefaults.standard.string(forKey: SpeechOutput.voiceDefaultsKey) ?? ""

    var body: some View {
        Picker("Voice", selection: $selection) {
            Text("System default").tag("")
            ForEach(SpeechOutput.availableVoices(), id: \.identifier) { voice in
                Text(voice.name).tag(voice.identifier)
            }
        }
        .onChange(of: selection) {
            env.speech.voiceIdentifier = selection.isEmpty ? nil : selection
            env.speech.speak("Hello!")
        }
    }
}
