import Foundation
import MTextCore
import MTextTestKit

enum TextTransformTests {

    static let suite = TestSuite("Transforms", [
        ("word range at a position", testWordRange),
        ("word range in whitespace and punctuation", testWordRangeNonWord),
        ("word boundary movement", testWordBoundary),
        ("subword boundary movement", testSubwordBoundary),
        ("first non-blank column", testFirstNonBlank),
        ("indentation of a line", testIndentation),
        ("find next and wrap", testFindNextWraps),
        ("find all", testFindAll),
        ("case-insensitive and whole-word search", testSearchOptions),
        ("move lines up and down", testMoveLines),
        ("duplicate lines", testDuplicateLines),
        ("delete lines", testDeleteLines),
        ("join lines", testJoinLines),
        ("sort, reverse and unique lines", testSortReverseUnique),
        ("indent and outdent", testIndentOutdent),
        ("toggle line comment", testToggleComment),
        ("case transforms", testCaseTransforms),
        ("transforms are single undo steps", testTransformsAreSingleUndoSteps),
    ])

    // MARK: - Words

    static func testWordRange() {
        let d = TextDocument(text: "let value = 42")
        let region = d.wordRange(at: Position(line: 0, column: 5))
        expectEqual(d.text(in: region), "value")
    }

    static func testWordRangeNonWord() {
        let d = TextDocument(text: "a   b..c")
        expectEqual(d.text(in: d.wordRange(at: Position(line: 0, column: 2))), "   ")
        expectEqual(d.text(in: d.wordRange(at: Position(line: 0, column: 5))), "..")
    }

    static func testWordBoundary() {
        let d = TextDocument(text: "hello world")
        expectEqual(d.wordBoundary(from: Position(line: 0, column: 0), forward: true),
                    Position(line: 0, column: 5))
        expectEqual(d.wordBoundary(from: Position(line: 0, column: 5), forward: true),
                    Position(line: 0, column: 11))
        expectEqual(d.wordBoundary(from: Position(line: 0, column: 11), forward: false),
                    Position(line: 0, column: 6))

        // Crossing a line break.
        let multi = TextDocument(text: "ab\ncd")
        expectEqual(multi.wordBoundary(from: Position(line: 0, column: 2), forward: true),
                    Position(line: 1, column: 0))
        expectEqual(multi.wordBoundary(from: Position(line: 1, column: 0), forward: false),
                    Position(line: 0, column: 2))
    }

    static func testSubwordBoundary() {
        let d = TextDocument(text: "camelCaseWord")
        expectEqual(d.wordBoundary(from: Position(line: 0, column: 0), forward: true, subword: true),
                    Position(line: 0, column: 5))
        expectEqual(d.wordBoundary(from: Position(line: 0, column: 0), forward: true, subword: false),
                    Position(line: 0, column: 13))
    }

    static func testFirstNonBlank() {
        let d = TextDocument(text: "    indented\nflush\n     ")
        expectEqual(d.firstNonBlankColumn(of: 0), 4)
        expectEqual(d.firstNonBlankColumn(of: 1), 0)
        expectEqual(d.firstNonBlankColumn(of: 2), 0, "an all-blank line reports 0")
    }

    static func testIndentation() {
        let d = TextDocument(text: "\t  mixed\nnone")
        expectEqual(d.indentation(of: 0), "\t  ")
        expectEqual(d.indentation(of: 1), "")
    }

    // MARK: - Search

    static func testFindNextWraps() {
        let d = TextDocument(text: "foo\nbar\nfoo")
        let first = d.findNext("foo", after: Position(line: 0, column: 1))
        expectEqual(first?.start, Position(line: 2, column: 0))

        let wrapped = d.findNext("foo", after: Position(line: 2, column: 1))
        expectEqual(wrapped?.start, Position(line: 0, column: 0), "search wraps to the top")

        expectNil(d.findNext("foo", after: Position(line: 2, column: 1), wrap: false))
    }

    static func testFindAll() {
        let d = TextDocument(text: "aXbXc\nXd")
        let matches = d.findAll("X")
        expectEqual(matches.count, 3)
        expectEqual(matches[0].start, Position(line: 0, column: 1))
        expectEqual(matches[1].start, Position(line: 0, column: 3))
        expectEqual(matches[2].start, Position(line: 1, column: 0))
    }

    static func testSearchOptions() {
        let d = TextDocument(text: "Cat cathode CAT")

        expectEqual(d.findAll("cat", caseSensitive: false).count, 3)
        expectEqual(d.findAll("cat").count, 1, "case-sensitive by default")

        var wholeWord = SearchQuery.literal("cat", caseSensitive: false)
        wholeWord.wholeWord = true
        expectEqual(d.findAll(wholeWord).count, 2, "'cathode' must not match")
    }

    // MARK: - Line transforms

    private static func caret(_ line: Int, _ column: Int) -> Selection {
        Selection(caret: Position(line: line, column: column))
    }

    static func testMoveLines() {
        let d = TextDocument(text: "a\nb\nc")
        _ = d.moveLines(caret(1, 0), up: true)
        expectEqual(d.text, "b\na\nc")
        _ = d.moveLines(caret(0, 0), up: false)
        expectEqual(d.text, "a\nb\nc")

        // Edges are no-ops.
        _ = d.moveLines(caret(0, 0), up: true)
        expectEqual(d.text, "a\nb\nc")
        _ = d.moveLines(caret(2, 0), up: false)
        expectEqual(d.text, "a\nb\nc")
    }

    static func testDuplicateLines() {
        let d = TextDocument(text: "x\ny")
        let result = d.duplicateLines(caret(0, 1))
        expectEqual(d.text, "x\nx\ny")
        expectEqual(result.primary.head.line, 1, "the caret follows the lower copy")
    }

    static func testDeleteLines() {
        let d = TextDocument(text: "a\nb\nc")
        _ = d.deleteLines(caret(1, 0))
        expectEqual(d.text, "a\nc")

        let last = TextDocument(text: "a\nb")
        _ = last.deleteLines(caret(1, 0))
        expectEqual(last.text, "a", "deleting the last line removes the newline above it")
    }

    static func testJoinLines() {
        let d = TextDocument(text: "hello\n    world")
        _ = d.joinLines(caret(0, 0))
        expectEqual(d.text, "hello world", "the next line's indentation collapses to one space")
    }

    static func testSortReverseUnique() {
        let selection = Selection(Region(anchor: Position(line: 0, column: 0),
                                         head: Position(line: 3, column: 1)))
        let sorted = TextDocument(text: "c\na\nd\nb")
        _ = sorted.sortLines(selection)
        expectEqual(sorted.text, "a\nb\nc\nd")

        let reversed = TextDocument(text: "1\n2\n3\n4")
        _ = reversed.reverseLines(selection)
        expectEqual(reversed.text, "4\n3\n2\n1")

        let deduped = TextDocument(text: "a\nb\na\nb")
        _ = deduped.uniqueLines(selection)
        expectEqual(deduped.text, "a\nb")
    }

    static func testIndentOutdent() {
        let d = TextDocument(text: "a\nb")
        let selection = Selection(Region(anchor: Position(line: 0, column: 0),
                                         head: Position(line: 1, column: 1)))
        _ = d.indent(selection, using: "  ")
        expectEqual(d.text, "  a\n  b")
        _ = d.outdent(selection, using: "  ")
        expectEqual(d.text, "a\nb")

        // Outdenting an unindented line is a no-op, not a character loss.
        _ = d.outdent(selection, using: "  ")
        expectEqual(d.text, "a\nb")
    }

    static func testToggleComment() {
        let d = TextDocument(text: "let a = 1\nlet b = 2")
        let selection = Selection(Region(anchor: Position(line: 0, column: 0),
                                         head: Position(line: 1, column: 9)))
        _ = d.toggleLineComment(selection, token: "//")
        expectEqual(d.text, "// let a = 1\n// let b = 2")
        _ = d.toggleLineComment(selection, token: "//")
        expectEqual(d.text, "let a = 1\nlet b = 2", "toggling again uncomments")
    }

    static func testCaseTransforms() {
        let d = TextDocument(text: "hello world")
        let selection = Selection(Region(anchor: Position(line: 0, column: 0),
                                         head: Position(line: 0, column: 11)))
        _ = d.upperCase(selection)
        expectEqual(d.text, "HELLO WORLD")
        _ = d.lowerCase(selection)
        expectEqual(d.text, "hello world")
        _ = d.titleCase(selection)
        expectEqual(d.text, "Hello World")
        _ = d.swapCase(selection)
        expectEqual(d.text, "hELLO wORLD")

        // With no selection the word under the caret is transformed.
        let word = TextDocument(text: "alpha beta")
        _ = word.upperCase(caret(0, 7))
        expectEqual(word.text, "alpha BETA")
    }

    static func testTransformsAreSingleUndoSteps() {
        let d = TextDocument(text: "c\na\nb")
        let selection = Selection(Region(anchor: Position(line: 0, column: 0),
                                         head: Position(line: 2, column: 1)))
        _ = d.sortLines(selection)
        expectEqual(d.text, "a\nb\nc")
        _ = d.undo()
        expectEqual(d.text, "c\na\nb", "a sort is one undo step")
        expectFalse(d.canUndo)
    }
}
