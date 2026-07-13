import XCTest
@testable import Rosetta

/// §4.1: inconsistent labels across caregivers poison the classes, so the
/// setup interview flags near-duplicates for a merge/keep decision.
final class LabelSimilarityTests: XCTestCase {
    func testExactAndCaseInsensitiveMatches() {
        XCTAssertTrue(LabelSimilarity.areNearDuplicates("Banana", "banana"))
        XCTAssertTrue(LabelSimilarity.areNearDuplicates("  banana ", "banana"))
    }

    func testMisspellingsAreFlagged() {
        XCTAssertTrue(LabelSimilarity.areNearDuplicates("bannana", "banana"))
        XCTAssertTrue(LabelSimilarity.areNearDuplicates("bathrom", "bathroom"))
    }

    func testConceptClustersCatchSynonyms() {
        // The spec's own example: snack vs hungry.
        XCTAssertTrue(LabelSimilarity.areNearDuplicates("snack", "hungry"))
        XCTAssertTrue(LabelSimilarity.areNearDuplicates("toilet", "bathroom"))
        XCTAssertTrue(LabelSimilarity.areNearDuplicates("mommy", "mom"))
    }

    func testDistinctIntentsAreNotFlagged() {
        XCTAssertFalse(LabelSimilarity.areNearDuplicates("banana", "outside"))
        XCTAssertFalse(LabelSimilarity.areNearDuplicates("hurt", "tablet"))
        XCTAssertFalse(LabelSimilarity.areNearDuplicates("water", "trampoline"))
    }

    func testConflictListsEveryNearDuplicate() {
        let existing = ["banana", "hungry", "outside"]
        let conflicts = LabelSimilarity.conflicts(for: "snack", in: existing)
        XCTAssertEqual(conflicts, ["hungry"])
        XCTAssertTrue(LabelSimilarity.conflicts(for: "trampoline", in: existing).isEmpty)
    }
}
