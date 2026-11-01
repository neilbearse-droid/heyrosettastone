import XCTest
@testable import Rosetta

/// §2.3: button positions are motor patterns. Nothing may move an existing
/// button — adding fills the lowest gap, removing leaves a hole.
final class BoardLayoutTests: XCTestCase {
    func testNewIntentTakesLowestFreeSlot() {
        XCTAssertEqual(BoardLayout.slotForNewIntent(occupiedSlots: []), 0)
        XCTAssertEqual(BoardLayout.slotForNewIntent(occupiedSlots: [0, 1, 2]), 3)
        XCTAssertEqual(BoardLayout.slotForNewIntent(occupiedSlots: [0, 2, 3]), 1)
        XCTAssertEqual(BoardLayout.slotForNewIntent(occupiedSlots: [1]), 0)
    }

    func testCellsRenderGapsInsteadOfShifting() {
        let a = IntentRecord(label: "a", boardSlot: 0)
        let c = IntentRecord(label: "c", boardSlot: 2)
        let cells = BoardLayout.cells(for: [a, c])
        XCTAssertEqual(cells.count, 3)
        XCTAssertEqual(cells[0]?.id, a.id)
        XCTAssertNil(cells[1], "the removed button's slot must stay empty")
        XCTAssertEqual(cells[2]?.id, c.id)
    }

    func testPositionIsPureFunctionOfIndexAndFixedColumnCount() {
        // (row, col) for a slot depends on nothing but the slot index and
        // the device's fixed column count: not on how many intents exist,
        // not on orientation or window size (which never reach this API).
        for columns in [BoardLayout.columnCount(forPad: false), BoardLayout.columnCount(forPad: true)] {
            for index in 0..<40 {
                let position = BoardLayout.position(ofIndex: index, columns: columns)
                XCTAssertEqual(position.row, index / columns)
                XCTAssertEqual(position.col, index % columns)
                XCTAssertLessThan(position.col, columns)
                // Calling again yields the same answer: no hidden state.
                let again = BoardLayout.position(ofIndex: index, columns: columns)
                XCTAssertEqual(again.row, position.row)
                XCTAssertEqual(again.col, position.col)
            }
        }

        // Fixed device kinds: iPhone 2 columns, iPad 4.
        XCTAssertEqual(BoardLayout.columnCount(forPad: false), 2)
        XCTAssertEqual(BoardLayout.columnCount(forPad: true), 4)

        // Adding intents later never changes where earlier slots render.
        let a = IntentRecord(label: "a", boardSlot: 0)
        let c = IntentRecord(label: "c", boardSlot: 2)
        let d = IntentRecord(label: "d", boardSlot: 7)
        let before = BoardLayout.cells(for: [a, c])
        let after = BoardLayout.cells(for: [a, c, d])
        for index in 0..<before.count {
            XCTAssertEqual(before[index]?.id, after[index]?.id)
            let p1 = BoardLayout.position(ofIndex: index, columns: 2)
            let p2 = BoardLayout.position(ofIndex: index, columns: 2)
            XCTAssertEqual(p1.row, p2.row)
            XCTAssertEqual(p1.col, p2.col)
        }
        XCTAssertEqual(after.count, 8)
        XCTAssertEqual(BoardLayout.position(ofIndex: 7, columns: 2).row, 3)
        XCTAssertEqual(BoardLayout.position(ofIndex: 7, columns: 2).col, 1)
        XCTAssertEqual(BoardLayout.position(ofIndex: 7, columns: 4).row, 1)
        XCTAssertEqual(BoardLayout.position(ofIndex: 7, columns: 4).col, 3)
    }

    func testGridImmutabilityAcrossAddAndRemove() throws {
        let db = try AppDatabase.inMemory()
        let intents = IntentStore(db: db)
        let board = BoardStore(db: db)

        let first = IntentRecord(label: "banana")
        let second = IntentRecord(label: "outside")
        let third = IntentRecord(label: "bathroom")
        for intent in [first, second, third] {
            try intents.insert(intent)
            try board.place(intentId: intent.id)
        }

        func slot(_ id: String) throws -> Int? {
            try intents.fetch(id: id)?.boardSlot
        }

        XCTAssertEqual(try slot(first.id), 0)
        XCTAssertEqual(try slot(second.id), 1)
        XCTAssertEqual(try slot(third.id), 2)

        // Removing the middle button must not move its neighbours.
        try board.remove(intentId: second.id)
        XCTAssertNil(try slot(second.id))
        XCTAssertEqual(try slot(first.id), 0)
        XCTAssertEqual(try slot(third.id), 2)

        // A NEW button may take the freed slot; existing ones still don't move.
        let fourth = IntentRecord(label: "water")
        try intents.insert(fourth)
        try board.place(intentId: fourth.id)
        XCTAssertEqual(try slot(fourth.id), 1)
        XCTAssertEqual(try slot(first.id), 0)
        XCTAssertEqual(try slot(third.id), 2)

        // Re-placing an already-placed intent is a no-op, never a move.
        try board.place(intentId: third.id)
        XCTAssertEqual(try slot(third.id), 2)
    }

    // MARK: - Phase 3: explicit parent moves (§7, §9)

    func testMoveIntoFreeSlotLeavesOthersAlone() throws {
        let db = try AppDatabase.inMemory()
        let intents = IntentStore(db: db)
        let board = BoardStore(db: db)
        let banana = IntentRecord(label: "banana")
        let cup = IntentRecord(label: "cup")
        for intent in [banana, cup] {
            try intents.insert(intent)
            try board.place(intentId: intent.id)
        }

        try board.move(intentId: banana.id, toSlot: 5)
        XCTAssertEqual(try intents.fetch(id: banana.id)?.boardSlot, 5)
        XCTAssertEqual(try intents.fetch(id: cup.id)?.boardSlot, 1, "the other button must not move")
        XCTAssertEqual(try board.occupiedSlots(), [5: banana.id, 1: cup.id])

        // The grid renders the gap, not a shifted neighbour.
        let cells = BoardLayout.cells(for: try board.boardIntents())
        XCTAssertEqual(cells.count, 6)
        XCTAssertNil(cells[0])
        XCTAssertEqual(cells[1]?.id, cup.id)
        XCTAssertEqual(cells[5]?.id, banana.id)

        // Moving to its own slot is a no-op, not an error.
        try board.move(intentId: banana.id, toSlot: 5)
        XCTAssertEqual(try intents.fetch(id: banana.id)?.boardSlot, 5)
    }

    func testMoveRefusesOccupiedSlotUnlessSwapping() throws {
        let db = try AppDatabase.inMemory()
        let intents = IntentStore(db: db)
        let board = BoardStore(db: db)
        let banana = IntentRecord(label: "banana")
        let cup = IntentRecord(label: "cup")
        for intent in [banana, cup] {
            try intents.insert(intent)
            try board.place(intentId: intent.id)
        }

        XCTAssertThrowsError(try board.move(intentId: banana.id, toSlot: 1)) { error in
            XCTAssertEqual(error as? BoardStoreError, .slotOccupied(slot: 1, by: cup.id))
        }
        // Nothing changed.
        XCTAssertEqual(try intents.fetch(id: banana.id)?.boardSlot, 0)
        XCTAssertEqual(try intents.fetch(id: cup.id)?.boardSlot, 1)

        try board.move(intentId: banana.id, toSlot: 1, swap: true)
        XCTAssertEqual(try intents.fetch(id: banana.id)?.boardSlot, 1)
        XCTAssertEqual(try intents.fetch(id: cup.id)?.boardSlot, 0)

        XCTAssertThrowsError(try board.move(intentId: banana.id, toSlot: -1)) { error in
            XCTAssertEqual(error as? BoardStoreError, .invalidSlot(-1))
        }
    }

    func testSwapRequiresBothOnBoard() throws {
        let db = try AppDatabase.inMemory()
        let intents = IntentStore(db: db)
        let board = BoardStore(db: db)
        let banana = IntentRecord(label: "banana")
        let cup = IntentRecord(label: "cup")
        let outside = IntentRecord(label: "outside")
        for intent in [banana, cup, outside] {
            try intents.insert(intent)
        }
        try board.place(intentId: banana.id)
        try board.place(intentId: cup.id)

        try board.swap(banana.id, cup.id)
        XCTAssertEqual(try intents.fetch(id: banana.id)?.boardSlot, 1)
        XCTAssertEqual(try intents.fetch(id: cup.id)?.boardSlot, 0)

        let cells = BoardLayout.cells(for: try board.boardIntents())
        XCTAssertEqual(cells.map { $0?.id }, [cup.id, banana.id])

        XCTAssertThrowsError(try board.swap(banana.id, outside.id)) { error in
            XCTAssertEqual(error as? BoardStoreError, .notOnBoard(outside.id))
        }
        XCTAssertThrowsError(try board.move(intentId: outside.id, toSlot: 4)) { error in
            XCTAssertEqual(error as? BoardStoreError, .notOnBoard(outside.id))
        }
        // A failed swap is atomic: both buttons where they were.
        XCTAssertEqual(try intents.fetch(id: banana.id)?.boardSlot, 1)
        XCTAssertEqual(try intents.fetch(id: cup.id)?.boardSlot, 0)
        XCTAssertNil(try intents.fetch(id: outside.id)?.boardSlot)
    }
}
