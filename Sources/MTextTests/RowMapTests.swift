import Foundation
import MTextCore
import MTextTestKit

enum RowMapTests {

    static let suite = TestSuite("RowMap", [
        ("with wrap off, row == line", testNoWrap),
        ("a wrapped line occupies several rows", testWrapRows),
        ("later lines shift down by the wrapped rows above", testWrapShifts),
        ("maps a row back to its line and wrapped row", testLocation),
        ("round-trips every line through row and back", testRoundTrip),
        ("places a caret on the right wrapped row", testCaretRow),

        ("folds remove rows even when lines wrap", testFoldsWithWrap),
        ("a hidden line reports its fold's row", testHiddenLineRow),
        ("a row inside a fold resolves to the fold's start line", testRowInsideFold),

        ("an edit re-wraps only the lines it touched", testUpdateLines),
        ("an edit that adds lines resizes the index", testUpdateGrows),
        ("an edit that removes lines resizes the index", testUpdateShrinks),
        ("total rows stays at least one for an empty document", testEmptyDocument),
    ])

    /// Lines of a fixed width, so row counts are easy to reason about by hand.
    private static func map(_ lines: [String], wrapWidth: Int, folds: FoldSet = FoldSet()) -> RowMap {
        var map = RowMap()
        map.rebuild(lineProvider: { lines[$0] }, lineCount: lines.count,
                    wrapWidth: wrapWidth, tabSize: 4)
        map.setFolds(folds)
        return map
    }

    // MARK: - Wrapping

    static func testNoWrap() {
        let map = map(["aaaaaaaaaa", "b", "c"], wrapWidth: 0)
        expectFalse(map.isWrapping)
        expectEqual(map.totalRows, 3)
        for line in 0 ..< 3 { expectEqual(map.firstRow(ofLine: line), line) }
    }

    static func testWrapRows() {
        // 10 chars at width 4 → 3 rows.
        let map = map([String(repeating: "x", count: 10)], wrapWidth: 4)
        expectTrue(map.isWrapping)
        expectEqual(map.rows(forLine: 0), 3)
        expectEqual(map.totalRows, 3)
    }

    static func testWrapShifts() {
        let map = map([String(repeating: "x", count: 10), "short", "also short"], wrapWidth: 4)
        expectEqual(map.firstRow(ofLine: 0), 0)
        expectEqual(map.firstRow(ofLine: 1), 3, "after the 3 rows of the wrapped line")
        expectEqual(map.firstRow(ofLine: 2), 5, "\"short\" is 5 chars → 2 rows at width 4")
    }

    static func testLocation() {
        let map = map([String(repeating: "x", count: 10), "b"], wrapWidth: 4)
        expectEqual(map.location(ofRow: 0).line, 0)
        expectEqual(map.location(ofRow: 0).rowInLine, 0)
        expectEqual(map.location(ofRow: 2).line, 0)
        expectEqual(map.location(ofRow: 2).rowInLine, 2, "third wrapped row of the first line")
        expectEqual(map.location(ofRow: 3).line, 1)
        expectEqual(map.location(ofRow: 3).rowInLine, 0)
    }

    /// Every line must be reachable from its own first row, or hit testing lands elsewhere.
    static func testRoundTrip() {
        let lines = ["a very long line that will certainly wrap several times over",
                     "short", "", "another quite long line needing more than one row", "x"]
        let map = map(lines, wrapWidth: 12)
        for line in lines.indices {
            expectEqual(map.location(ofRow: map.firstRow(ofLine: line)).line, line,
                        "line \(line) should round-trip")
        }
    }

    static func testCaretRow() {
        let lines = [String(repeating: "x", count: 10)]
        let map = map(lines, wrapWidth: 4)
        func row(_ column: Int) -> Int {
            map.row(at: Position(line: 0, column: column), lineProvider: { lines[$0] }, tabSize: 4)
        }
        expectEqual(row(0), 0)
        expectEqual(row(3), 0)
        expectEqual(row(4), 1, "the break column starts the next row")
        expectEqual(row(9), 2)
    }

    // MARK: - Folds combined with wrap

    /// The interaction that makes a unified map necessary: folding removes *rows*, not
    /// lines, so a collapsed block of wrapped lines removes more than one row each.
    static func testFoldsWithWrap() {
        let long = String(repeating: "x", count: 10)   // 3 rows at width 4
        let map = map(["head", long, long, "tail"], wrapWidth: 4,
                      folds: FoldSet(regions: [FoldRegion(startLine: 0, endLine: 2)]))
        // "head" is 4 chars → 1 row; the two long lines (3 rows each) are hidden.
        expectEqual(map.firstRow(ofLine: 0), 0)
        expectEqual(map.firstRow(ofLine: 3), 1, "tail follows head directly")
        expectEqual(map.totalRows, 2)
    }

    static func testHiddenLineRow() {
        let map = map(["a", "b", "c", "d"], wrapWidth: 0,
                      folds: FoldSet(regions: [FoldRegion(startLine: 0, endLine: 2)]))
        expectEqual(map.firstRow(ofLine: 1), 0, "hidden lines carry their fold's row")
        expectEqual(map.firstRow(ofLine: 2), 0)
        expectEqual(map.rows(forLine: 1), 0, "and occupy none of their own")
    }

    static func testRowInsideFold() {
        let map = map(["a", "b", "c", "d"], wrapWidth: 0,
                      folds: FoldSet(regions: [FoldRegion(startLine: 0, endLine: 2)]))
        expectEqual(map.location(ofRow: 0).line, 0)
        expectEqual(map.location(ofRow: 1).line, 3, "row 1 is the line after the fold")
    }

    // MARK: - Edits

    static func testUpdateLines() {
        var lines = ["short", "short", "short"]
        var map = map(lines, wrapWidth: 4)
        expectEqual(map.totalRows, 6, "\"short\" is 5 chars → 2 rows each")

        lines[1] = "x"
        map.updateLines(1 ..< 2, lineProvider: { lines[$0] }, newLineCount: lines.count, tabSize: 4)
        expectEqual(map.rows(forLine: 1), 1)
        expectEqual(map.totalRows, 5)
        expectEqual(map.firstRow(ofLine: 2), 3, "the line after shifts up")
    }

    static func testUpdateGrows() {
        var lines = ["a", "b"]
        var map = map(lines, wrapWidth: 0)
        lines = ["a", "b", "c", "d"]
        map.updateLines(2 ..< 4, lineProvider: { lines[$0] }, newLineCount: 4, tabSize: 4)
        expectEqual(map.lineCount, 4)
        expectEqual(map.totalRows, 4)
        expectEqual(map.firstRow(ofLine: 3), 3)
    }

    static func testUpdateShrinks() {
        var lines = ["a", "b", "c", "d"]
        var map = map(lines, wrapWidth: 0)
        lines = ["a", "b"]
        map.updateLines(0 ..< 2, lineProvider: { lines[$0] }, newLineCount: 2, tabSize: 4)
        expectEqual(map.lineCount, 2)
        expectEqual(map.totalRows, 2)
    }

    static func testEmptyDocument() {
        var map = RowMap()
        map.rebuild(lineProvider: { _ in "" }, lineCount: 0, wrapWidth: 40, tabSize: 4)
        expectEqual(map.totalRows, 1, "never zero — the caret has to sit somewhere")
        expectEqual(map.location(ofRow: 0).line, 0)
    }
}
