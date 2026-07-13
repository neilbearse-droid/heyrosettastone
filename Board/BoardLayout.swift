import Foundation
import GRDB

/// Slot assignment rules for the child's board. Principle §2.3: button
/// positions are motor patterns and never move. These are the only code
/// paths that touch `boardSlot`, and none of them can move an occupied slot.
///
/// - New intents take the lowest empty slot (append-like, gaps refill only
///   with NEW buttons — existing buttons never shift).
/// - Removing an intent clears its slot and leaves every other slot alone;
///   the gap is rendered blank so neighbours don't slide.
/// - There is deliberately NO move/swap/reorder API. Board layout editing is
///   Phase 3, an explicit parent flow with a motor-pattern warning, and will
///   be added as its own audited path.
enum BoardLayout {
    /// The slot a new intent gets, given the slots already in use:
    /// the lowest index not occupied.
    static func slotForNewIntent(occupiedSlots: [Int]) -> Int {
        let occupied = Set(occupiedSlots)
        var slot = 0
        while occupied.contains(slot) { slot += 1 }
        return slot
    }

    /// Row-major cell list for rendering: every slot from 0 through the
    /// highest occupied, with nil for gaps, so removals never shift
    /// surviving buttons.
    static func cells(for intents: [IntentRecord]) -> [IntentRecord?] {
        let placed = intents.filter { $0.boardSlot != nil && $0.archivedAt == nil }
        guard let maxSlot = placed.compactMap(\.boardSlot).max() else { return [] }
        var cells = [IntentRecord?](repeating: nil, count: maxSlot + 1)
        for intent in placed {
            if let slot = intent.boardSlot, slot >= 0, slot < cells.count {
                cells[slot] = intent
            }
        }
        return cells
    }
}

/// Database side of slot assignment. Same rules, persisted.
struct BoardStore {
    let db: AppDatabase

    /// Places an intent on the board in the lowest empty slot. No-op if it
    /// is already placed — placing again must not move it.
    func place(intentId: String) throws {
        try db.dbQueue.write { db in
            guard var intent = try IntentRecord.fetchOne(db, key: intentId) else { return }
            guard intent.boardSlot == nil else { return }
            let occupied = try Int.fetchAll(
                db, sql: "SELECT boardSlot FROM intents WHERE boardSlot IS NOT NULL")
            intent.boardSlot = BoardLayout.slotForNewIntent(occupiedSlots: occupied)
            try intent.update(db)
        }
    }

    /// Takes an intent off the board. Every other slot is untouched.
    func remove(intentId: String) throws {
        try db.dbQueue.write { db in
            guard var intent = try IntentRecord.fetchOne(db, key: intentId) else { return }
            intent.boardSlot = nil
            try intent.update(db)
        }
    }

    func boardIntents() throws -> [IntentRecord] {
        try db.dbQueue.read {
            try IntentRecord
                .filter(Column("boardSlot") != nil && Column("archivedAt") == nil)
                .order(Column("boardSlot"))
                .fetchAll($0)
        }
    }
}
