import SwiftUI

/// The persistent, legible listening indicator (§7, §8) — something he can
/// learn to recognize. Shown on every parent surface while capture runs.
struct RecordingIndicator: View {
    let isListening: Bool
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isListening ? Color.green : Color.secondary)
                .frame(width: 12, height: 12)
                .opacity(isListening && pulsing ? 0.4 : 1.0)
                .animation(
                    isListening
                        ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true)
                        : .default,
                    value: pulsing
                )
            Text(isListening ? "Listening" : "Paused")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isListening ? Color.primary : Color.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color(.secondarySystemBackground)))
        .onAppear { pulsing = true }
        .accessibilityLabel(isListening ? "Rosetta is listening" : "Listening is paused")
    }
}
