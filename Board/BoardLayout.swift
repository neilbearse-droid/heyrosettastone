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
/// - Nothing here moves an occupied slot. `BoardLayout` is append-only for
///   automatic placement; the ONLY way an existing button changes position
///   is an explicit parent move or swap through `BoardStore.move` /
///   `BoardStore.swap`, reached solely from the Phase 3 layout editor
///   behind its motor-pattern warning (§7, §9). No automatic path — not
///   sorting, not frequency, not a removal — ever calls those.
enum BoardLayout {
    /// The slot a new intent gets, given the slots already in use:
    /// the lowest index not occupied.
    static func slotForNewIntent(occupiedSlots: [Int]) -> Int {
        let occupied = Set(occupiedSlots)
        var slot = 0
        while occupied.contains(slot) { slot += 1 }
        return slot
    }

    /// Columns on the child's grid, fixed per device kind and never derived
    /// from size class or orientation, so rotation and Split View cannot
    /// reflow his buttons. iPhone: 2 columns (touch targets >= 2.5 cm, §7);
    /// iPad: 4.
    static func columnCount(forPad isPad: Bool) -> Int {
        isPad ? 4 : 2
    }

    /// Where a row-major slot index lands for a fixed column count. A pure
    /// function of (index, columns): nothing about other intents, the
    /// device's orientation or window size enters into it (§2.3).
    static func position(ofIndex index: Int, columns: Int) -> (row: Int, col: Int) {
        let columns = max(1, columns)
        return (index / columns, index % columns)
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

    /// Every occupied slot and the intent sitting in it.
    func occupiedSlots() throws -> [Int: String] {
        try db.dbQueue.read { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT id, boardSlot FROM intents WHERE boardSlot IS NOT NULL")
            var slots: [Int: String] = [:]
            for row in rows {
                if let slot: Int = row["boardSlot"], let id: String = row["id"] {
                    slots[slot] = id
                }
            }
            return slots
        }
    }

    // MARK: - Explicit parent edits (Phase 3 layout editor only)

    /// Moves a button that is already on the board to `slot`. This is an
    /// explicit parent edit (§7: positions are permanent unless a parent
    /// edits the layout, after the warning that moving costs him
    /// relearning) and must never be called by an automatic path.
    ///
    /// Fails with `slotOccupied` when another intent holds `slot`, unless
    /// `swap` is true, in which case the two buttons trade places. Column-
    /// scoped SQL inside one transaction; `boardSlot` is UNIQUE, so the
    /// occupant is parked first.
    func move(intentId: String, toSlot slot: Int, swap: Bool = false) throws {
        guard slot >= 0 else { throw BoardStoreError.invalidSlot(slot) }
        try db.dbQueue.write { db in
            guard let current = try Int.fetchOne(
                db, sql: "SELECT boardSlot FROM intents WHERE id = ? AND archivedAt IS NULL",
                arguments: [intentId]
            ) else {
                throw BoardStoreError.notOnBoard(intentId)
            }
            if current == slot { return }
            let occupant = try String.fetchOne(
                db, sql: "SELECT id FROM intents WHERE boardSlot = ?", arguments: [slot])
            if let occupant, occupant != intentId {
                guard swap else { throw BoardStoreError.slotOccupied(slot: slot, by: occupant) }
                try db.execute(
                    sql: "UPDATE intents SET boardSlot = NULL WHERE id = ?", arguments: [occupant])
                try db.execute(
                    sql: "UPDATE intents SET boardSlot = ? WHERE id = ?", arguments: [slot, intentId])
                try db.execute(
                    sql: "UPDATE intents SET boardSlot = ? WHERE id = ?", arguments: [current, occupant])
            } else {
                try db.execute(
                    sql: "UPDATE intents SET boardSlot = ? WHERE id = ?", arguments: [slot, intentId])
            }
        }
    }

    /// Trades the slots of two buttons that are both on the board. Same
    /// rules and the same audience as `move`: explicit parent edits only.
    func swap(_ a: String, _ b: String) throws {
        guard a != b else { return }
        try db.dbQueue.write { db in
            guard let slotA = try Int.fetchOne(
                db, sql: "SELECT boardSlot FROM intents WHERE id = ? AND archivedAt IS NULL",
                arguments: [a]
            ) else {
                throw BoardStoreError.notOnBoard(a)
            }
            guard let slotB = try Int.fetchOne(
                db, sql: "SELECT boardSlot FROM intents WHERE id = ? AND archivedAt IS NULL",
                arguments: [b]
            ) else {
                throw BoardStoreError.notOnBoard(b)
            }
            try db.execute(sql: "UPDATE intents SET boardSlot = NULL WHERE id = ?", arguments: [a])
            try db.execute(sql: "UPDATE intents SET boardSlot = ? WHERE id = ?", arguments: [slotA, b])
            try db.execute(sql: "UPDATE intents SET boardSlot = ? WHERE id = ?", arguments: [slotB, a])
        }
    }
}

/// Why an explicit board edit was refused. Plain-language descriptions
/// because the editor surfaces them directly.
enum BoardStoreError: Error, LocalizedError, Equatable {
    case notOnBoard(String)
    case slotOccupied(slot: Int, by: String)
    case invalidSlot(Int)

    var errorDescription: String? {
        switch self {
        case .notOnBoard:
            return "That word is not on his board."
        case .slotOccupied(let slot, _):
            return "Spot \(slot + 1) already has a button in it."
        case .invalidSlot:
            return "That is not a spot on his board."
        }
    }
}
