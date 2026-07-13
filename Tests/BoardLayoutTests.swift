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
}
