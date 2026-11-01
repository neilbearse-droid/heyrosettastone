import SwiftUI
import UIKit

/// Plain-language recording trust screen (§7, §8). Shown once, before
/// anything records. Explains what is captured, where it lives, and how to
/// delete it — in words, not policy. Asks for the microphone here (A8) so
/// the first Listen tap never races the system prompt.
@MainActor
struct FirstRunView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var requestingMicrophone = false
    @State private var microphoneDenied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Rosetta")
                        .font(.largeTitle.bold())
                    Text("A dictionary of how he talks, built by the people who understand him.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 40)

                explainer(
                    icon: "waveform",
                    title: "What gets recorded",
                    body: "When listening is on, this device keeps short clips of speech it hears, so you can save the ones that were him and label what he meant. You choose when listening is on. A green indicator is always visible while it is."
                )
                explainer(
                    icon: "iphone",
                    title: "Where it lives",
                    body: "Everything stays on this device. Rosetta never connects to the internet: there is no account, no cloud, and no code path that sends audio anywhere."
                )
                explainer(
                    icon: "trash",
                    title: "How to delete it",
                    body: "Any clip can be removed in one tap from Review or Dictionary. Clips you discard, or mark as someone else's voice, are deleted — at the latest within 7 days. Settings has a single button that erases everything, permanently."
                )
                explainer(
                    icon: "hand.raised",
                    title: "His say",
                    body: "The indicator is something he can learn to recognize. Pause is instant and always honoured. If he objects to a device in a room, that room goes quiet — no argument."
                )

                if microphoneDenied {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Microphone access is off", systemImage: "mic.slash")
                            .font(.headline)
                        Text("Without the microphone Rosetta cannot hear him, so Listen will not work. His board and dictionary still do. To turn listening on later: Settings > Privacy & Security > Microphone > Rosetta.")
                            .foregroundStyle(.secondary)
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            Link("Open iPhone Settings", destination: url)
                        }
                        Button("Continue without listening for now") {
                            env.hasCompletedFirstRun = true
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
                } else {
                    Button {
                        requestMicrophone()
                    } label: {
                        HStack {
                            if requestingMicrophone {
                                ProgressView()
                            }
                            Text("Got it — let's set up his words")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(requestingMicrophone)
                    .padding(.top, 8)

                    Text("Next, iOS will ask whether Rosetta may use the microphone. That is what makes listening possible.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
    }

    private func requestMicrophone() {
        guard !requestingMicrophone else { return }
        requestingMicrophone = true
        Task {
            let granted = await CaptureController.requestMicrophonePermission()
            requestingMicrophone = false
            if granted {
                env.hasCompletedFirstRun = true
            } else {
                microphoneDenied = true
            }
        }
    }

    private func explainer(icon: String, title: String, body text: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary)
            }
        }
    }
}
