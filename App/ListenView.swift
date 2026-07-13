import SwiftUI

/// Ambient capture status and pause (§3), plus the way into his board and
/// app settings. Pause is one tap and instant (§7).
struct ListenView: View {
    @Environment(AppEnvironment.self) private var env
    let enterChildMode: () -> Void

    @State private var showingSettings = false
    @State private var liveGuesses: [Suggestion] = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()

                RecordingIndicator(isListening: env.capture.isListening)
                    .scaleEffect(1.3)

                if env.capture.isListening {
                    statusText
                    if !liveGuesses.isEmpty {
                        liveGuessStrip
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
                }
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .onChange(of: env.capture.recentSegments) { refreshLiveGuesses() }
        }
    }

    /// Live top-3 during an exchange (§4.5). Read-only here — resolving
    /// happens on the Confirm card. Copy stays tentative (§2.6).
    private var liveGuessStrip: some View {
        VStack(spacing: 6) {
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
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
            }
        }
        .padding(.horizontal, 48)
    }

    private func refreshLiveGuesses() {
        let segments = env.capture.recentSegments.filter { $0.segmentState == .pending }
        guard !segments.isEmpty else {
            liveGuesses = []
            return
        }
        Task {
            liveGuesses = await env.suggestions.suggestions(
                for: segments,
                station: env.capture.stationName
            )
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

// MARK: - Settings

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var labeller = ""
    @State private var station = ""
    @State private var includeAudioInBackup = UserDefaults.standard.bool(forKey: "includeAudioInBackup")
    @State private var exportURL: URL?
    @State private var exportError: String?
    @State private var confirmingWipe = false

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

                Section("His data") {
                    Button {
                        do { exportURL = try env.exporter.makeExportZip() }
                        catch { exportError = error.localizedDescription }
                    } label: {
                        Label("Export everything (zip)", systemImage: "square.and.arrow.up")
                    }
                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("Share export", systemImage: "doc.zipper")
                        }
                    }
                    if let exportError {
                        Text(exportError).font(.footnote).foregroundStyle(.red)
                    }
                    Button(role: .destructive) {
                        confirmingWipe = true
                    } label: {
                        Label("Delete everything", systemImage: "trash")
                    }
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
            .alert("Delete everything?", isPresented: $confirmingWipe) {
                Button("Delete all data", role: .destructive) {
                    try? env.exporter.wipeAll()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every word, clip, photo, and log on this device is erased permanently. There is no cloud copy and no undo.")
            }
            .onAppear {
                labeller = env.labeller
                station = env.capture.stationName
            }
        }
    }
}

/// Voice selection with an audition — each candidate voice speaks a sample
/// when selected, so he can pick by ear.
struct VoicePickerRow: View {
    @State private var selection = UserDefaults.standard.string(forKey: SpeechOutput.voiceDefaultsKey) ?? ""
    private let speech = SpeechOutput()

    var body: some View {
        Picker("Voice", selection: $selection) {
            Text("System default").tag("")
            ForEach(SpeechOutput.availableVoices(), id: \.identifier) { voice in
                Text(voice.name).tag(voice.identifier)
            }
        }
        .onChange(of: selection) {
            speech.voiceIdentifier = selection.isEmpty ? nil : selection
            speech.speak("Hello!")
        }
    }
}
