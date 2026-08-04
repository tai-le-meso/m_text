import Foundation
import MTextCore
import MTextTestKit

enum MultiCursorTests {

    static let suite = TestSuite("MultiCursor", [
        ("insert at several carets", testInsertAtSeveralCarets),
        ("insert over several selections", testReplaceSeveralSelections),
        ("distribute one string per region", testDistributeReplacements),
        ("multi-cursor edit is one undo step", testMultiCursorEditIsOneUndoStep),
        ("backspace at several carets", testBackspaceAtSeveralCarets),
        ("delete word backward at several carets", testDeleteWordBackward),
        ("edits on the same line stay aligned", testSameLineEditsStayAligned),
        ("carets across lines survive line-count changes", testMultilineInsert),
        ("lines touched by a selection", testLinesTouchedBySelection),
        ("undo restores every caret's text", testUndoRestoresAllRegions),
        ("carets rebase across differing replacement lengths", testUnevenReplacementLengths),
        ("duplicate lines shifts each block independently", testDuplicateTwoBlocks),
        ("join three lines leaves one caret", testJoinThreeLines),
        ("toggle comment keeps carets on their text", testCommentKeepsCarets),
        ("join separate blocks keeps carets aligned", testJoinTwoBlocks),
        ("delete separate blocks keeps carets aligned", testDeleteTwoBlocks),
    ])

    private static func carets(_ positions: [(Int, Int)]) -> Selection {
        Selection(regions: positions.map { Region(caret: Position(line: $0.0, column: $0.1)) })
    }

    static func testInsertAtSeveralCarets() {
        let d = TextDocument(text: "aa\nbb\ncc")
        let result = d.insert("X", over: carets([(0, 1), (1, 1), (2, 1)]))
        expectEqual(d.text, "aXa\nbXb\ncXc")
        expectEqual(result.count, 3)
        expectEqual(result[0].head, Position(line: 0, column: 2))
        expectEqual(result[2].head, Position(line: 2, column: 2))
    }

    static func testReplaceSeveralSelections() {
        let d = TextDocument(text: "one two\none two")
        let selection = Selection(regions: [
            Region(anchor: Position(line: 0, column: 4), head: Position(line: 0, column: 7)),
            Region(anchor: Position(line: 1, column: 4), head: Position(line: 1, column: 7)),
        ])
        _ = d.replace(selection, withEach: "six")
        expectEqual(d.text, "one six\none six")
    }

    static func testDistributeReplacements() {
        let d = TextDocument(text: "-\n-\n-")
        let result = d.replace(carets([(0, 1), (1, 1), (2, 1)]), with: ["a", "b", "c"])
        expectEqual(d.text, "-a\n-b\n-c")
        expectEqual(result.count, 3)
    }

    static func testMultiCursorEditIsOneUndoStep() {
        let d = TextDocument(text: "aa\nbb\ncc")
        _ = d.insert("X", over: carets([(0, 1), (1, 1), (2, 1)]))
        expectEqual(d.text, "aXa\nbXb\ncXc")
        _ = d.undo()
        expectEqual(d.text, "aa\nbb\ncc", "one ⌘Z must undo all three carets")
        expectFalse(d.canUndo)
        _ = d.redo()
        expectEqual(d.text, "aXa\nbXb\ncXc")
    }

    static func testBackspaceAtSeveralCarets() {
        let d = TextDocument(text: "abc\nabc")
        let result = d.deleteBackward(over: carets([(0, 2), (1, 2)]))
        expectEqual(d.text, "ac\nac")
        expectEqual(result[0].head, Position(line: 0, column: 1))
        expectEqual(result[1].head, Position(line: 1, column: 1))
    }

    static func testDeleteWordBackward() {
        let d = TextDocument(text: "hello world\nhello world")
        _ = d.deleteWordBackward(over: carets([(0, 11), (1, 11)]))
        expectEqual(d.text, "hello \nhello ")
    }

    /// Two carets on one line: editing back-to-front must leave the earlier
    /// caret's column untouched.
    static func testSameLineEditsStayAligned() {
        let d = TextDocument(text: "a.b.c")
        let result = d.insert("!", over: carets([(0, 1), (0, 3)]))
        expectEqual(d.text, "a!.b!.c")
        expectEqual(result[0].head, Position(line: 0, column: 2))
        expectEqual(result[1].head, Position(line: 0, column: 5))
    }

    static func testMultilineInsert() {
        let d = TextDocument(text: "a\nb")
        let result = d.insert("\n-\n", over: carets([(0, 1), (1, 1)]))
        expectEqual(d.text, "a\n-\n\nb\n-\n")
        expectEqual(result.count, 2)
        // The second caret shifted down by the two lines the first insert added.
        expectEqual(result[1].head.line, 5)
    }

    static func testLinesTouchedBySelection() {
        let d = TextDocument(text: "0\n1\n2\n3\n4")
        let spanning = Selection(Region(anchor: Position(line: 1, column: 0),
                                        head: Position(line: 3, column: 1)))
        expectEqual(d.lines(touchedBy: spanning), [1, 2, 3])

        // A selection ending exactly at column 0 does not include that line.
        let toColumnZero = Selection(Region(anchor: Position(line: 1, column: 0),
                                            head: Position(line: 3, column: 0)))
        expectEqual(d.lines(touchedBy: toColumnZero), [1, 2])
    }

    /// Regression: results captured while editing region i are still shifted by the
    /// later, lower-offset edits. Uneven replacement lengths expose a missing rebase.
    static func testUnevenReplacementLengths() {
        let d = TextDocument(text: "a.b.c.d")
        let result = d.replace(carets([(0, 1), (0, 2), (0, 4)]), with: ["X", "YY", "ZZZ"])
        expectEqual(d.text, "aX.YYb.ZZZc.d")
        expectEqual(result[0].head, Position(line: 0, column: 2))
        expectEqual(result[1].head, Position(line: 0, column: 5))
        expectEqual(result[2].head, Position(line: 0, column: 10))
    }

    /// Regression: a single total line delta over-shifts carets in the topmost block.
    static func testDuplicateTwoBlocks() {
        let d = TextDocument(text: "a\nb\nc\nd")
        let selection = Selection(regions: [
            Region(caret: Position(line: 0, column: 1)),
            Region(caret: Position(line: 3, column: 1)),
        ])
        let result = d.duplicateLines(selection)
        expectEqual(d.text, "a\na\nb\nc\nd\nd")
        expectEqual(result[0].head.line, 1, "first block's caret shifts by one line")
        expectEqual(result[1].head.line, 5, "second block's caret shifts by two")
    }

    /// Regression: one caret per block, not one per joined pair.
    static func testJoinThreeLines() {
        let d = TextDocument(text: "a\nb\nc\nd")
        let selection = Selection(Region(anchor: Position(line: 0, column: 0),
                                        head: Position(line: 2, column: 1)))
        let result = d.joinLines(selection)
        expectEqual(d.text, "a b c\nd")
        expectEqual(result.count, 1, "joining three lines must not leave three carets")
        expectEqual(result[0].head, Position(line: 0, column: 1))
    }

    /// Regression: after ⌘/ the caret must still sit on its original character,
    /// not inside the inserted comment token.
    static func testCommentKeepsCarets() {
        let d = TextDocument(text: "ab\ncd")
        let selection = Selection(regions: [
            Region(caret: Position(line: 0, column: 1)),
            Region(caret: Position(line: 1, column: 1)),
        ])
        let commented = d.toggleLineComment(selection, token: "//")
        expectEqual(d.text, "// ab\n// cd")
        expectEqual(commented[0].head, Position(line: 0, column: 4))
        expectEqual(commented[1].head, Position(line: 1, column: 4))

        let uncommented = d.toggleLineComment(commented, token: "//")
        expectEqual(d.text, "ab\ncd")
        expectEqual(uncommented[0].head, Position(line: 0, column: 1))
    }

    /// Regression: blocks are joined bottom-up, so a caret recorded for a lower block
    /// must be rebased as the blocks above it collapse.
    static func testJoinTwoBlocks() {
        let d = TextDocument(text: "a\nb\nc\nd\ne\nf")
        let selection = Selection(regions: [
            Region(caret: Position(line: 0, column: 0)),
            Region(caret: Position(line: 3, column: 0)),
        ])
        let result = d.joinLines(selection)
        expectEqual(d.text, "a b\nc\nd e\nf")
        expectEqual(result.count, 2)
        expectEqual(result[0].head, Position(line: 0, column: 1))
        expectEqual(result[1].head, Position(line: 2, column: 1),
                    "the lower caret moves up by the line the block above removed")
    }

    static func testDeleteTwoBlocks() {
        let d = TextDocument(text: "a\nb\nc\nd")
        let selection = Selection(regions: [
            Region(caret: Position(line: 0, column: 0)),
            Region(caret: Position(line: 2, column: 0)),
        ])
        let result = d.deleteLines(selection)
        expectEqual(d.text, "b\nd")
        expectEqual(result.count, 2)
        expectEqual(result[0].head, Position(line: 0, column: 0))
        expectEqual(result[1].head, Position(line: 1, column: 0))
    }

    static func testUndoRestoresAllRegions() {
        let d = TextDocument(text: "one\ntwo\nthree")
        let selection = Selection(regions: [
            Region(anchor: Position(line: 0, column: 0), head: Position(line: 0, column: 3)),
            Region(anchor: Position(line: 2, column: 0), head: Position(line: 2, column: 5)),
        ])
        _ = d.replace(selection, withEach: "")
        expectEqual(d.text, "\ntwo\n")
        _ = d.undo()
        expectEqual(d.text, "one\ntwo\nthree")
    }
}
