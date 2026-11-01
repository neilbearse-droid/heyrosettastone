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

    func testShortWordsOneEditApartAreDifferentWords() {
        // One edit on a three-letter word is a different word, not a typo.
        XCTAssertFalse(LabelSimilarity.areNearDuplicates("dad", "mad"))
        XCTAssertFalse(LabelSimilarity.areNearDuplicates("cat", "hat"))
        XCTAssertFalse(LabelSimilarity.areNearDuplicates("bed", "bad"))
    }

    func testInflectedFormsAreFlagged() {
        XCTAssertTrue(LabelSimilarity.areNearDuplicates("snacks", "snack"))
        XCTAssertTrue(LabelSimilarity.areNearDuplicates("Snacks", "snack"))
        XCTAssertTrue(LabelSimilarity.areNearDuplicates("cookies", "cookie"))
    }

    func testMultiWordFormsReachTheConceptClusters() {
        XCTAssertTrue(LabelSimilarity.areNearDuplicates("want food", "hungry"))
        XCTAssertTrue(LabelSimilarity.areNearDuplicates("go potty", "bathroom"))
        XCTAssertTrue(LabelSimilarity.areNearDuplicates("my cup", "thirsty"))
        XCTAssertTrue(LabelSimilarity.areNearDuplicates("snack please", "food"))
        XCTAssertTrue(LabelSimilarity.areNearDuplicates("more", "again"),
                      "a label that is only a stopword keeps its raw token")
    }

    func testTokenizerStripsStopwordsAndPlurals() {
        XCTAssertEqual(LabelSimilarity.tokens("Want my snacks, please!"), ["snack"])
        XCTAssertEqual(LabelSimilarity.tokens("all done"), ["all", "done"])
        XCTAssertEqual(LabelSimilarity.tokens("glass"), ["glass"], "a trailing double-s is not a plural")
        XCTAssertEqual(LabelSimilarity.tokens("bus"), ["bus"], "short words are not stemmed")
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

    func testSemanticFallbackIsGuardedAndSymmetric() {
        // Whether or not the on-device word embedding is present, the
        // fallback must never crash and must give the same answer both ways.
        let a = LabelSimilarity.semanticallyClose(["cookie"], ["biscuit"])
        let b = LabelSimilarity.semanticallyClose(["biscuit"], ["cookie"])
        XCTAssertEqual(a, b)
        XCTAssertFalse(LabelSimilarity.semanticallyClose(["dad"], ["mad"]), "short tokens never use the embedding")
        XCTAssertFalse(LabelSimilarity.semanticallyClose([], ["banana"]))
    }
}
