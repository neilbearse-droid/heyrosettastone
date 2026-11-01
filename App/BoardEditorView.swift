import SwiftUI
import UIKit

/// Phase 3 board layout editing (§7, §9): the one explicit parent path
/// that moves his buttons, behind a plain-language warning that moving
/// costs him relearning. Nothing is reordered automatically — the parent
/// taps a button, then the spot it should go to (or another button to
/// swap with). Edits are kept locally, counted, undoable, and written
/// through `BoardStore.move` / `BoardStore.swap` only when Done is
/// tapped; "Keep it as it is" or Cancel writes nothing.
@MainActor
struct BoardEditorView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    /// Called after a layout change has been saved.
    let onChange: () -> Void

    /// One local, undoable edit. Replayed in order against the store on
    /// Done; the local slot map mirrors what the replay will produce.
    enum LayoutEdit: Equatable {
        case move(intentId: String, from: Int, to: Int)
        case swap(a: String, b: String)
    }

    @State private var acknowledged = false
    @State private var intentsById: [String: IntentRecord] = [:]
    /// Slot of every board button as loaded; the reference for "N buttons
    /// will be in new places".
    @State private var originalSlots: [String: Int] = [:]
    @State private var workingSlots: [String: Int] = [:]
    @State private var edits: [LayoutEdit] = []
    @State private var selectedId: String?
    @State private var saveError: String?
    @State private var confirmingDiscard = false

    var body: some View {
        NavigationStack {
            if acknowledged {
                editor
            } else {
                warning
            }
        }
        .onAppear(perform: load)
    }

    // MARK: - Warning

    private var warning: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("Moving his buttons costs him relearning")
                    .font(.title2.weight(.bold))
                Text("His hands have learned where each button is. A button's spot is a motor pattern, not a picture: if it moves, he has to learn it again, and for a while he may tap where it used to be and get the wrong word.")
                Text("Editing the layout is a good idea only when you are adding a row and want things grouped, or fixing a mistake early, before a spot has been learned. It is not something to tune.")
                Text("Nothing moves on its own. Only the buttons you move will move, and you can undo before saving.")
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Text("Keep it as it is")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    acknowledged = true
                } label: {
                    Text("Continue")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(24)
            .background(.bar)
        }
        .navigationTitle("Edit his board layout")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Editor

    private var editor: some View {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let columnCount = BoardLayout.columnCount(forPad: isPad)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 16), count: columnCount)
        let cells = paddedCells(columns: columnCount)

        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(instruction)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)

                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                        if let intent = cell {
                            BoardButton(intent: intent) {
                                tapped(intent: intent, atSlot: index)
                            }
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .strokeBorder(Color.accentColor, lineWidth: selectedId == intent.id ? 4 : 0)
                            )
                            .accessibilityHint(selectedId == nil
                                ? "Selects this button to move"
                                : (selectedId == intent.id ? "Deselects" : "Swaps places with the selected button"))
                            .accessibilityAddTraits(selectedId == intent.id ? .isSelected : [])
                        } else {
                            emptySlot(index)
                        }
                    }
                }
                .padding(16)
            }
        }
        .background(Color(.systemBackground))
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Text(movedSummary)
                    .font(.footnote)
                    .foregroundStyle(movedCount == 0 ? .secondary : .primary)
                HStack {
                    Button("Undo last move") { undo() }
                        .disabled(edits.isEmpty)
                    Spacer()
                    Button("Done") { save() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
            .background(.bar)
        }
        .navigationTitle("Edit his board layout")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    if edits.isEmpty { dismiss() } else { confirmingDiscard = true }
                }
            }
        }
        .confirmationDialog("Discard these moves?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard and keep the board as it was", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        }
        .alert("Could not save the layout", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    private var instruction: String {
        if let selectedId, let intent = intentsById[selectedId] {
            return "“\(intent.label)” is selected. Tap an empty spot to move it there, or another button to swap the two."
        }
        return "Tap a button to pick it up."
    }

    private var movedCount: Int {
        workingSlots.filter { id, slot in originalSlots[id] != slot }.count
    }

    private var movedSummary: String {
        switch movedCount {
        case 0: return "Nothing has moved yet."
        case 1: return "1 button will be in a new place."
        default: return "\(movedCount) buttons will be in new places."
        }
    }

    private func emptySlot(_ index: Int) -> some View {
        Button {
            tappedEmpty(slot: index)
        } label: {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(selectedId == nil ? Color.secondary.opacity(0.3) : Color.accentColor)
                .frame(maxWidth: .infinity, minHeight: 160)
                .overlay(
                    Text("Spot \(index + 1)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                )
        }
        .buttonStyle(.plain)
        .disabled(selectedId == nil)
        .accessibilityLabel("Empty spot \(index + 1)")
        .accessibilityHint(selectedId == nil ? "Pick a button first" : "Moves the selected button here")
    }

    // MARK: - Local edits

    /// The grid as it will look: every slot up to the highest occupied,
    /// padded to a full row plus one extra empty row so a button can be
    /// moved into a new row (the main legitimate reason to edit, §7).
    private func paddedCells(columns: Int) -> [IntentRecord?] {
        let cells = BoardLayout.cells(for: workingIntents)
        let columns = max(1, columns)
        let rows = cells.count / columns + (cells.count % columns == 0 ? 0 : 1)
        let target = (rows + 1) * columns
        return cells + Array(repeating: nil, count: max(0, target - cells.count))
    }

    private var workingIntents: [IntentRecord] {
        intentsById.values.map { intent in
            var copy = intent
            copy.boardSlot = workingSlots[intent.id]
            return copy
        }
    }

    private func tapped(intent: IntentRecord, atSlot slot: Int) {
        guard let selectedId else {
            self.selectedId = intent.id
            return
        }
        if selectedId == intent.id {
            self.selectedId = nil
            return
        }
        guard let selectedSlot = workingSlots[selectedId] else {
            self.selectedId = nil
            return
        }
        workingSlots[selectedId] = slot
        workingSlots[intent.id] = selectedSlot
        edits.append(.swap(a: selectedId, b: intent.id))
        self.selectedId = nil
    }

    private func tappedEmpty(slot: Int) {
        guard let selectedId, let from = workingSlots[selectedId] else { return }
        guard workingSlots.values.contains(slot) == false else { return }
        workingSlots[selectedId] = slot
        edits.append(.move(intentId: selectedId, from: from, to: slot))
        self.selectedId = nil
    }

    private func undo() {
        guard let last = edits.popLast() else { return }
        selectedId = nil
        switch last {
        case .move(let intentId, let from, _):
            workingSlots[intentId] = from
        case .swap(let a, let b):
            guard let slotA = workingSlots[a], let slotB = workingSlots[b] else { return }
            workingSlots[a] = slotB
            workingSlots[b] = slotA
        }
    }

    // MARK: - Persistence

    private func load() {
        let intents = (try? env.board.boardIntents()) ?? []
        var byId: [String: IntentRecord] = [:]
        var slots: [String: Int] = [:]
        for intent in intents {
            byId[intent.id] = intent
            if let slot = intent.boardSlot { slots[intent.id] = slot }
        }
        intentsById = byId
        originalSlots = slots
        workingSlots = slots
        edits = []
        selectedId = nil
    }

    /// Replays the edits through the store in order — the same sequence
    /// that produced the local slot map, so the board ends up exactly as
    /// previewed. A failure stops the replay; what was applied stays
    /// applied (each step is its own transaction), and the parent sees
    /// the message and the board reloaded from the database.
    private func save() {
        guard !edits.isEmpty else {
            dismiss()
            return
        }
        do {
            for edit in edits {
                switch edit {
                case .move(let intentId, _, let to):
                    try env.board.move(intentId: intentId, toSlot: to)
                case .swap(let a, let b):
                    try env.board.swap(a, b)
                }
            }
            onChange()
            dismiss()
        } catch {
            saveError = error.localizedDescription
            onChange()
            load()
        }
    }
}
