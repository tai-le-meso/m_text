import Foundation
import MTextCore
import MTextTestKit

enum LineDiffTests {

    static let suite = TestSuite("LineDiff", [
        ("identical files produce no hunks", testIdentical),
        ("detects an inserted line", testInsertion),
        ("detects a deleted line", testDeletion),
        ("detects a modified line", testModification),
        ("detects several separate hunks", testMultipleHunks),
        ("handles a file that was empty", testFromEmpty),
        ("handles a file emptied entirely", testToEmpty),
        ("trims a common prefix and suffix", testTrimsCommonEnds),

        ("marks added lines", testMarksAdded),
        ("marks modified lines", testMarksModified),
        ("marks the line below a deletion", testMarksDeletedAbove),
        ("attaches a trailing deletion to the last line", testDeletionAtEnd),

        ("finds the hunk containing a line", testHunkContaining),
        ("finds a deletion hunk by the line it sits above", testHunkContainingDeletion),
        ("collapses a very large difference into one hunk", testLargeDiffCollapses),
    ])

    // MARK: - Hunks

    static func testIdentical() {
        expectTrue(LineDiff.hunks(old: ["a", "b"], new: ["a", "b"]).isEmpty)
    }

    static func testInsertion() {
        let hunks = LineDiff.hunks(old: ["a", "c"], new: ["a", "b", "c"])
        expectEqual(hunks.count, 1)
        expectEqual(hunks.first?.newRange, 1 ..< 2)
        expectTrue(hunks.first?.isAddition == true)
    }

    static func testDeletion() {
        let hunks = LineDiff.hunks(old: ["a", "b", "c"], new: ["a", "c"])
        expectEqual(hunks.count, 1)
        expectTrue(hunks.first?.isDeletion == true)
        expectEqual(hunks.first?.oldRange, 1 ..< 2)
    }

    static func testModification() {
        let hunks = LineDiff.hunks(old: ["a", "b", "c"], new: ["a", "B", "c"])
        expectEqual(hunks.count, 1)
        expectEqual(hunks.first?.newRange, 1 ..< 2)
        expectEqual(hunks.first?.oldRange, 1 ..< 2)
        expectFalse(hunks.first?.isAddition == true)
        expectFalse(hunks.first?.isDeletion == true)
    }

    static func testMultipleHunks() {
        let hunks = LineDiff.hunks(old: ["a", "b", "c", "d", "e"],
                                   new: ["a", "B", "c", "d", "E"])
        expectEqual(hunks.count, 2, "two separate edits stay separate")
    }

    static func testFromEmpty() {
        let hunks = LineDiff.hunks(old: [], new: ["a", "b"])
        expectEqual(hunks.count, 1)
        expectTrue(hunks.first?.isAddition == true)
        expectEqual(hunks.first?.newRange, 0 ..< 2)
    }

    static func testToEmpty() {
        let hunks = LineDiff.hunks(old: ["a", "b"], new: [])
        expectEqual(hunks.count, 1)
        expectTrue(hunks.first?.isDeletion == true)
    }

    /// The optimisation that makes this cheap enough to run on every gutter draw.
    static func testTrimsCommonEnds() {
        let old = (0 ..< 500).map { "line \($0)" }
        var new = old
        new[250] = "changed"
        let hunks = LineDiff.hunks(old: old, new: new)
        expectEqual(hunks.count, 1)
        expectEqual(hunks.first?.newRange, 250 ..< 251, "only the changed line, not the file")
    }

    // MARK: - Marks

    static func testMarksAdded() {
        let marks = LineDiff.marks(old: ["a", "c"], new: ["a", "b", "c"])
        expectEqual(marks[1], .added)
        expectNil(marks[0])
        expectNil(marks[2])
    }

    static func testMarksModified() {
        let marks = LineDiff.marks(old: ["a", "b"], new: ["a", "B"])
        expectEqual(marks[1], .modified)
    }

    /// A deletion has no line of its own to colour, so it attaches to the line that now
    /// follows it.
    static func testMarksDeletedAbove() {
        let marks = LineDiff.marks(old: ["a", "b", "c"], new: ["a", "c"])
        expectEqual(marks[1], .deletedAbove)
    }

    static func testDeletionAtEnd() {
        let marks = LineDiff.marks(old: ["a", "b", "c"], new: ["a"])
        expectEqual(marks[0], .deletedAbove, "clamped to the last line rather than falling off")
    }

    // MARK: - Revert

    static func testHunkContaining() {
        let old = ["a", "b", "c"]
        let new = ["a", "B", "c"]
        expectEqual(LineDiff.hunk(containing: 1, old: old, new: new)?.oldRange, 1 ..< 2)
        expectNil(LineDiff.hunk(containing: 0, old: old, new: new))
    }

    /// A deletion's `newRange` is empty, so without this a deleted hunk could never be
    /// reverted — there would be no line that "contains" it.
    static func testHunkContainingDeletion() {
        let hunk = LineDiff.hunk(containing: 1, old: ["a", "b", "c"], new: ["a", "c"])
        expectTrue(hunk?.isDeletion == true)
        expectEqual(hunk?.oldRange, 1 ..< 2)
    }

    /// Past the cap the middle is reported as one hunk rather than spending O(n·m) on a
    /// diff nobody reads line by line.
    static func testLargeDiffCollapses() {
        let old = (0 ..< 3000).map { "old \($0)" }
        let new = (0 ..< 3000).map { "new \($0)" }
        let hunks = LineDiff.hunks(old: old, new: new)
        expectEqual(hunks.count, 1)
        expectEqual(hunks.first?.newRange, 0 ..< 3000)
    }
}
