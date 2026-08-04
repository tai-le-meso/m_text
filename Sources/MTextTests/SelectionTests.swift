import Foundation
import MTextCore
import MTextTestKit

enum SelectionTests {

    static let suite = TestSuite("Selection", [
        ("region start/end and direction", testRegionOrientation),
        ("overlapping regions merge", testOverlapMerges),
        ("adjacent selections do not merge", testAdjacentSelectionsDoNotMerge),
        ("a caret touching a selection merges", testCaretTouchingSelectionMerges),
        ("regions are kept sorted", testRegionsStaySorted),
        ("primary survives normalisation", testPrimarySurvivesNormalize),
        ("collapse to primary", testCollapseToPrimary),
        ("map then normalise", testMapNormalises),
        ("equality ignores goal column", testEqualityIgnoresGoalColumn),
    ])

    private static func region(_ l0: Int, _ c0: Int, _ l1: Int, _ c1: Int) -> Region {
        Region(anchor: Position(line: l0, column: c0), head: Position(line: l1, column: c1))
    }

    static func testRegionOrientation() {
        let forward = region(0, 2, 0, 6)
        expectEqual(forward.start, Position(line: 0, column: 2))
        expectEqual(forward.end, Position(line: 0, column: 6))
        expectFalse(forward.isReversed)

        let backward = region(0, 6, 0, 2)
        expectEqual(backward.start, Position(line: 0, column: 2))
        expectEqual(backward.end, Position(line: 0, column: 6))
        expectTrue(backward.isReversed)
        expectFalse(backward.isEmpty)
    }

    static func testOverlapMerges() {
        let selection = Selection(regions: [region(0, 0, 0, 5), region(0, 3, 0, 9)])
        expectEqual(selection.count, 1)
        expectEqual(selection[0].start, Position(line: 0, column: 0))
        expectEqual(selection[0].end, Position(line: 0, column: 9))
    }

    static func testAdjacentSelectionsDoNotMerge() {
        let selection = Selection(regions: [region(0, 0, 0, 5), region(0, 5, 0, 9)])
        expectEqual(selection.count, 2, "touching but non-overlapping selections stay separate")
    }

    static func testCaretTouchingSelectionMerges() {
        let caret = Region(caret: Position(line: 0, column: 5))
        let selection = Selection(regions: [region(0, 0, 0, 5), caret])
        expectEqual(selection.count, 1)

        let duplicates = Selection(regions: [caret, caret])
        expectEqual(duplicates.count, 1, "two carets at the same spot are one caret")
    }

    static func testRegionsStaySorted() {
        let selection = Selection(regions: [region(5, 0, 5, 1), region(1, 0, 1, 1), region(3, 0, 3, 1)])
        expectEqual(selection.count, 3)
        expectEqual(selection[0].start.line, 1)
        expectEqual(selection[1].start.line, 3)
        expectEqual(selection[2].start.line, 5)
    }

    static func testPrimarySurvivesNormalize() {
        let target = region(3, 0, 3, 4)
        let selection = Selection(regions: [region(9, 0, 9, 2), target, region(1, 0, 1, 2)],
                                  primaryIndex: 1)
        expectEqual(selection.primary, target, "the primary region keeps its identity after sorting")
    }

    static func testCollapseToPrimary() {
        var selection = Selection(regions: [region(0, 0, 0, 4), region(2, 0, 2, 4)], primaryIndex: 1)
        selection.collapseToPrimary()
        expectEqual(selection.count, 1)
        expectTrue(selection[0].isEmpty)
    }

    static func testMapNormalises() {
        var selection = Selection(regions: [region(0, 0, 0, 2), region(0, 6, 0, 8)])
        // Grow both by five columns so they genuinely overlap — four would only make
        // them touch, which deliberately does not merge.
        selection.map { Region(anchor: $0.anchor, head: Position(line: $0.head.line, column: $0.head.column + 5)) }
        expectEqual(selection.count, 1)
        expectEqual(selection[0].end, Position(line: 0, column: 13))
    }

    static func testEqualityIgnoresGoalColumn() {
        let a = Region(anchor: .zero, head: Position(line: 0, column: 3), goalColumn: 9)
        let b = Region(anchor: .zero, head: Position(line: 0, column: 3), goalColumn: nil)
        expectTrue(a == b, "goal column is a movement hint, not identity")
    }
}
