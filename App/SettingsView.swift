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
    @State private var buildingReport = false
    @State private var reportItem: ShareItem?
    @State private var reportError: String?

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
                    Toggle("Start listening when this station starts up", isOn: Bindable(env).autoResumeListening)
                } header: {
                    Text("Listening")
                } footer: {
                    Text("Only for a station phone that lives on the counter. The green indicator still shows whenever it is listening, and Pause still stops it instantly. It never asks for the microphone at startup: if permission was not already given, nothing starts.")
                }

                Section {
                    Button {
                        dismiss()
                        env.guestMode = true
                    } label: {
                        Label("Show guest view", systemImage: "person.2")
                    }
                    Toggle("Guests can see live guesses", isOn: Bindable(env).guestsSeeLiveGuesses)
                } header: {
                    Text("Guest mode")
                } footer: {
                    Text("A read-only view for grandparents, EAs and respite workers: what he says, what it usually means, and how to respond. Nothing can be changed from it; hold the pill at the top to come back here.")
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

                    Button {
                        buildSLPReport()
                    } label: {
                        if buildingReport {
                            HStack {
                                ProgressView()
                                Text("Preparing report…")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Label("Report for his SLP (PDF)", systemImage: "doc.richtext")
                        }
                    }
                    .disabled(buildingReport)
                    if let reportError {
                        Text(reportError).font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("His words")
                } footer: {
                    Text("The seed list is a one-page text summary of his dictionary with how often each word has come up. The PDF report adds when and where each word comes up and how the dictionary has grown week by week. Neither contains audio or photos.")
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
            .sheet(item: $reportItem) { item in
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

    /// §6 SLP report: the summary is built off the main thread (it reads
    /// every exemplar), the PDF is drawn on the main thread (UIKit text
    /// drawing; small), written to a temp file and handed to the share
    /// sheet. Maturity comes from the engine's reports, read here on the
    /// main actor, and is passed in as plain values.
    private func buildSLPReport() {
        guard !buildingReport else { return }
        buildingReport = true
        reportError = nil
        let db = env.db
        let labeller = env.labeller
        let maturity: [MaturityGate.Report]? = env.suggestions.isModelAvailable
            ? env.suggestions.maturityReports
            : nil
        Task {
            let built: Result<SLPReportData, Error> = await Task.detached(priority: .userInitiated) { () -> Result<SLPReportData, Error> in
                do {
                    return .success(try SLPReportData.build(db: db, labeller: labeller, maturity: maturity))
                } catch {
                    return .failure(error)
                }
            }.value
            switch built {
            case .success(let data):
                do {
                    let url = try SLPReport.writeTemporaryPDF(data)
                    reportItem = ShareItem(url: url)
                } catch {
                    reportError = error.localizedDescription
                }
            case .failure(let error):
                reportError = error.localizedDescription
            }
            buildingReport = false
        }
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
