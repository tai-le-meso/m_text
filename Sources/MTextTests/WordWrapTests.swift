import Foundation
import MTextCore
import MTextTestKit

enum WordWrapTests {

    static let suite = TestSuite("WordWrap", [
        ("a line that fits does not wrap", testFits),
        ("wraps at the last space that fits", testWrapsAtSpace),
        ("wraps repeatedly across a long line", testWrapsRepeatedly),
        ("hard-breaks a word wider than the row", testLongWord),
        ("hard-breaks only the oversized word, not the rest", testLongWordThenNormal),
        ("expands tabs when measuring", testTabs),
        ("makes progress when one character exceeds the width", testPathologicalWidth),
        ("treats width < 1 as wrapping disabled", testWidthDisabled),
        ("leaves an empty line as a single row", testEmptyLine),

        ("counts rows", testRowCount),
        ("maps a column to its wrapped row", testRowForColumn),
        ("reports the column range of each row", testColumnRange),
        ("column ranges tile the line with no gaps", testRangesTile),
    ])

    // MARK: - Breaking

    static func testFits() {
        expectEqual(WordWrapper.breaks(for: "short line", width: 40), [])
    }

    /// "aaa bbb ccc" at width 7: "aaa bbb" fits (7 columns), so the break lands after the
    /// space at index 8 — the space stays on the row it ends.
    static func testWrapsAtSpace() {
        expectEqual(WordWrapper.breaks(for: "aaa bbb ccc", width: 7), [8])
    }

    static func testWrapsRepeatedly() {
        let breaks = WordWrapper.breaks(for: "aa bb cc dd ee ff", width: 5)
        expectTrue(breaks.count >= 2, "a 17-column line at width 5 needs several rows")
        expectTrue(breaks == breaks.sorted(), "breaks must be ascending")
        expectTrue(breaks.allSatisfy { $0 > 0 && $0 < 17 }, "no break at the very start or end")
    }

    /// A long URL or a minified line must not simply vanish off the right edge.
    static func testLongWord() {
        let breaks = WordWrapper.breaks(for: String(repeating: "x", count: 10), width: 4)
        expectEqual(breaks, [4, 8])
    }

    static func testLongWordThenNormal() {
        // "xxxxxxxx" (8) then " y" — the word breaks hard, the tail wraps normally.
        let breaks = WordWrapper.breaks(for: "xxxxxxxx y", width: 4)
        expectTrue(breaks.contains(4), "the oversized word is split at the width")
        expectTrue(breaks == breaks.sorted())
    }

    static func testTabs() {
        // A tab at column 0 with tabSize 4 advances to column 4, so "\tab" is 6 columns and
        // overflows a width of 5.
        expectFalse(WordWrapper.breaks(for: "\tab", width: 5, tabSize: 4).isEmpty)
        expectTrue(WordWrapper.breaks(for: "\tab", width: 8, tabSize: 4).isEmpty)
    }

    /// A tab wider than the entire row would otherwise break at the same index forever.
    static func testPathologicalWidth() {
        let breaks = WordWrapper.breaks(for: "\t\t\t", width: 1, tabSize: 8)
        expectEqual(breaks, [1, 2], "one character per row, and it terminates")
    }

    static func testWidthDisabled() {
        expectEqual(WordWrapper.breaks(for: String(repeating: "x", count: 100), width: 0), [])
        expectEqual(WordWrapper.breaks(for: "anything", width: -5), [])
    }

    static func testEmptyLine() {
        expectEqual(WordWrapper.breaks(for: "", width: 10), [])
        expectEqual(WordWrapper.rowCount(for: "", width: 10), 1, "an empty line still occupies a row")
    }

    // MARK: - Row mapping

    static func testRowCount() {
        expectEqual(WordWrapper.rowCount(for: "short", width: 40), 1)
        expectEqual(WordWrapper.rowCount(for: String(repeating: "x", count: 10), width: 4), 3)
    }

    static func testRowForColumn() {
        let breaks = [4, 8]
        expectEqual(WordWrapper.row(forColumn: 0, breaks: breaks), 0)
        expectEqual(WordWrapper.row(forColumn: 3, breaks: breaks), 0)
        expectEqual(WordWrapper.row(forColumn: 4, breaks: breaks), 1, "a break column starts the next row")
        expectEqual(WordWrapper.row(forColumn: 7, breaks: breaks), 1)
        expectEqual(WordWrapper.row(forColumn: 8, breaks: breaks), 2)
        expectEqual(WordWrapper.row(forColumn: 99, breaks: breaks), 2, "past the end stays on the last row")
    }

    static func testColumnRange() {
        let breaks = [4, 8]
        expectEqual(WordWrapper.columnRange(ofRow: 0, breaks: breaks, lineLength: 10), 0 ..< 4)
        expectEqual(WordWrapper.columnRange(ofRow: 1, breaks: breaks, lineLength: 10), 4 ..< 8)
        expectEqual(WordWrapper.columnRange(ofRow: 2, breaks: breaks, lineLength: 10), 8 ..< 10)
    }

    /// Every column belongs to exactly one row — a gap or an overlap would make a caret
    /// land on the wrong row, or nowhere.
    static func testRangesTile() {
        let line = "the quick brown fox jumps over the lazy dog"
        let breaks = WordWrapper.breaks(for: line, width: 12)
        var expectedStart = 0
        for row in 0 ... breaks.count {
            let range = WordWrapper.columnRange(ofRow: row, breaks: breaks, lineLength: line.count)
            expectEqual(range.lowerBound, expectedStart, "row \(row) starts where the previous ended")
            expectedStart = range.upperBound
        }
        expectEqual(expectedStart, line.count, "the last row reaches the end of the line")
    }
}
