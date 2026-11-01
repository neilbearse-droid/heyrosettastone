import SwiftUI

/// The persistent, legible listening indicator (§7, §8) — something he can
/// learn to recognize. Shown on every parent surface and on his board while
/// capture runs.
///
/// Three truthful states: green "Listening", grey "Paused" (the family
/// stopped it), amber "Stopped" (the phone took the microphone away or a
/// failure stopped capture — `isStopped`). A stall must never read as a
/// deliberate pause: the family would otherwise believe the phone is
/// catching his words when it is not.
struct RecordingIndicator: View {
    let isListening: Bool
    /// Listening ended without the family asking (interruption, disk full,
    /// engine failure). Ignored while `isListening` is true.
    var isStopped: Bool = false
    @State private var pulsing = false

    private var stopped: Bool { !isListening && isStopped }

    private var dotColor: Color {
        if isListening { return .green }
        return stopped ? .orange : .secondary
    }

    private var title: String {
        if isListening { return "Listening" }
        return stopped ? "Stopped" : "Paused"
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 12, height: 12)
                .opacity(isListening && pulsing ? 0.4 : 1.0)
                .animation(
                    isListening
                        ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true)
                        : .default,
                    value: pulsing
                )
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isListening ? Color.primary : Color.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color(.secondarySystemBackground)))
        .onAppear { pulsing = true }
        .accessibilityLabel(
            isListening
                ? "Rosetta is listening"
                : (stopped ? "Listening stopped on its own; see the Listen tab" : "Listening is paused")
        )
    }
}
