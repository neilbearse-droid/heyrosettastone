import SwiftUI

/// Plain-language recording trust screen (§7, §8). Shown once, before
/// anything records. Explains what is captured, where it lives, and how to
/// delete it — in words, not policy.
struct FirstRunView: View {
    @Environment(AppEnvironment.self) private var env

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
                    body: "Everything stays on this device. Rosetta has no account, no cloud, and no way to send audio anywhere — the app is built without network access, and iOS enforces that."
                )
                explainer(
                    icon: "trash",
                    title: "How to delete it",
                    body: "Any clip can be deleted in one tap. Settings has a single button that erases everything, permanently."
                )
                explainer(
                    icon: "hand.raised",
                    title: "His say",
                    body: "The indicator is something he can learn to recognize. Pause is instant and always honoured. If he objects to a device in a room, that room goes quiet — no argument."
                )

                Button {
                    env.hasCompletedFirstRun = true
                } label: {
                    Text("Got it — let's set up his words")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
            }
            .padding(24)
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
