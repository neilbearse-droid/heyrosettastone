import SwiftUI

/// The child's surface: a fixed grid of large photo buttons (§3, §7).
/// Tapping speaks the label and logs a boardTap event. The grid renders
/// slots row-major including gaps, so positions are literally frozen.
///
/// In `ask` mode (§4.3) the board is shown by a parent mid-exchange and a
/// selection also resolves the exchange — that path is an explicit,
/// parent-initiated confirmation, so it may create exemplars.
struct BoardView: View {
    enum Mode {
        case child
        /// Parent-invoked Ask flow; called with the selected intent.
        case ask(onSelect: (IntentRecord) -> Void)
    }

    let intents: [IntentRecord]
    let mode: Mode
    let onTap: (IntentRecord) -> Void

    private let speech = SpeechOutput()

    /// Column count is fixed per size class, never adaptive, so a given
    /// device always shows the same geometry. Touch targets stay >= 2.5 cm
    /// (~160 pt) on iPhone with 2 columns.
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var columns: [GridItem] {
        let count = sizeClass == .regular ? 4 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 16), count: count)
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(Array(BoardLayout.cells(for: intents).enumerated()), id: \.offset) { _, cell in
                    if let intent = cell {
                        BoardButton(intent: intent) {
                            speech.speak(intent.label)
                            onTap(intent)
                            if case .ask(let onSelect) = mode {
                                onSelect(intent)
                            }
                        }
                    } else {
                        // A removed button's slot stays visibly empty;
                        // neighbours must not slide into it (§2.3).
                        Color.clear
                            .frame(minHeight: 160)
                            .accessibilityHidden(true)
                    }
                }
            }
            .padding(16)
        }
        .background(Color(.systemBackground))
    }
}

/// One board cell: real photo, big label, instant feedback. Visual response
/// is driven by the pressed state so it lands well under 100 ms (§7).
struct BoardButton: View {
    let intent: IntentRecord
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                photo
                    .frame(maxWidth: .infinity)
                    .frame(height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Text(intent.label)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .multilineTextAlignment(.center)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 160)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 2)
            )
        }
        .buttonStyle(BoardPressStyle())
        // Generous hit slop for imprecise motor control (§7).
        .contentShape(RoundedRectangle(cornerRadius: 16).inset(by: -8))
        .accessibilityLabel(intent.label)
        .accessibilityHint("Speaks the word aloud")
    }

    @ViewBuilder
    private var photo: some View {
        if let ref = intent.photoRef,
           let image = UIImage(contentsOfFile: FileLocations.photoURL(id: ref).path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.tertiarySystemFill))
                .overlay(
                    Text(String(intent.label.prefix(1)).uppercased())
                        .font(.system(size: 56, weight: .bold))
                        .foregroundStyle(.secondary)
                )
        }
    }
}

/// Immediate press feedback: slight shrink and highlight on touch-down.
private struct BoardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.easeOut(duration: 0.05), value: configuration.isPressed)
    }
}
