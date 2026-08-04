import Foundation
import MTextCore
import MTextTestKit

enum TextDocumentTests {

    static let suite = TestSuite("TextDocument", [
        ("empty document", testEmptyDocument),
        ("insert returns the position after", testInsertReturnsPositionAfter),
        ("multiline insert returns the position after", testInsertMultilineReturnsPositionAfter),
        ("delete backward within a line", testDeleteBackwardWithinLine),
        ("delete backward joins lines", testDeleteBackwardJoinsLines),
        ("delete backward at start is a no-op", testDeleteBackwardAtStartIsNoop),
        ("delete forward", testDeleteForward),
        ("delete range across lines", testDeleteRangeAcrossLines),
        ("grapheme columns", testGraphemeColumns),
        ("byte offset round trip", testByteOffsetRoundTrip),
        ("clamp", testClamp),
        ("longest line length", testLongestLineLength),
        ("undo/redo a single insert", testUndoRedoSingleInsert),
        ("typing coalesces into one undo step", testTypingIsCoalescedIntoOneUndoStep),
        ("caret move breaks coalescing", testCaretMoveBreaksCoalescing),
        ("delete is its own undo step", testDeleteIsItsOwnUndoStep),
        ("undo across a multiline edit", testUndoAcrossMultilineEdit),
        ("a new edit clears redo", testNewEditClearsRedo),
        ("dirty flag", testDirtyFlag),
        ("undo then retype stays dirty", testUndoThenRetypeStaysDirty),
        ("save without a destination throws", testSaveWithoutDestinationThrows),
        ("undo shrinks the longest line", testUndoShrinksLongestLine),
        ("combining mark merges with the previous character", testCombiningMarkMergesWithPreviousCharacter),
        ("byte offset round trip with combining marks", testByteOffsetRoundTripWithCombiningMarks),
        ("undo/redo fuzz round trip", testUndoRedoFuzzRoundTrip),
    ])

    static func testEmptyDocument() {
        let d = TextDocument()
        expectEqual(d.lineCount, 1)
        expectEqual(d.text, "")
        expectFalse(d.isDirty)
        expectFalse(d.canUndo)
    }

    static func testInsertReturnsPositionAfter() {
        let d = TextDocument()
        let p = d.insert("hello", at: .zero)
        expectEqual(d.text, "hello")
        expectEqual(p, Position(line: 0, column: 5))
    }

    static func testInsertMultilineReturnsPositionAfter() {
        let d = TextDocument(text: "ad")
        let p = d.insert("b\nc", at: Position(line: 0, column: 1))
        expectEqual(d.text, "ab\ncd")
        expectEqual(p, Position(line: 1, column: 1))
        expectEqual(d.line(0), "ab")
        expectEqual(d.line(1), "cd")
    }

    static func testDeleteBackwardWithinLine() {
        let d = TextDocument(text: "abc")
        let p = d.deleteBackward(at: Position(line: 0, column: 2))
        expectEqual(d.text, "ac")
        expectEqual(p, Position(line: 0, column: 1))
    }

    static func testDeleteBackwardJoinsLines() {
        let d = TextDocument(text: "ab\ncd")
        let p = d.deleteBackward(at: Position(line: 1, column: 0))
        expectEqual(d.text, "abcd")
        expectEqual(p, Position(line: 0, column: 2))
    }

    static func testDeleteBackwardAtStartIsNoop() {
        let d = TextDocument(text: "a")
        let p = d.deleteBackward(at: .zero)
        expectEqual(d.text, "a")
        expectEqual(p, .zero)
    }

    static func testDeleteForward() {
        let d = TextDocument(text: "ab\ncd")
        _ = d.deleteForward(at: Position(line: 0, column: 2))
        expectEqual(d.text, "abcd")
    }

    static func testDeleteRangeAcrossLines() {
        let d = TextDocument(text: "one\ntwo\nthree")
        let p = d.delete(from: Position(line: 0, column: 1), to: Position(line: 2, column: 2))
        expectEqual(d.text, "oree")
        expectEqual(p, Position(line: 0, column: 1))
    }

    static func testGraphemeColumns() {
        let d = TextDocument(text: "ế🇻🇳x")
        expectEqual(d.lineLength(0), 3, "3 grapheme clusters (\"ế\", the flag, \"x\")")
        let p = d.deleteBackward(at: Position(line: 0, column: 2))
        expectEqual(d.text, "ếx")
        expectEqual(p, Position(line: 0, column: 1))
    }

    static func testByteOffsetRoundTrip() {
        let d = TextDocument(text: "ế\nTiếng Việt\nend")
        for line in 0 ..< d.lineCount {
            for col in 0 ... d.lineLength(line) {
                let p = Position(line: line, column: col)
                expectEqual(d.position(ofByteOffset: d.byteOffset(of: p)), p)
            }
        }
    }

    static func testClamp() {
        let d = TextDocument(text: "ab\nc")
        expectEqual(d.clamp(Position(line: 9, column: 9)), Position(line: 1, column: 1))
        expectEqual(d.clamp(Position(line: -1, column: -1)), .zero)
    }

    static func testLongestLineLength() {
        let d = TextDocument(text: "a\nlonger line\nbb")
        expectEqual(d.longestLineLength, 11)
        _ = d.insert("xxxxxxxxxxxxxxxxxxxx", at: Position(line: 0, column: 1))
        expectEqual(d.longestLineLength, 21)
    }

    // MARK: - Undo / redo

    static func testUndoRedoSingleInsert() {
        let d = TextDocument()
        _ = d.insert("hello", at: .zero)
        expectTrue(d.canUndo)
        let caret = d.undo()
        expectEqual(d.text, "")
        expectEqual(caret, Position.zero)
        let redoCaret = d.redo()
        expectEqual(d.text, "hello")
        expectEqual(redoCaret, Position(line: 0, column: 5))
    }

    static func testTypingIsCoalescedIntoOneUndoStep() {
        let d = TextDocument()
        var p = Position.zero
        for ch in "hello" { p = d.insert(String(ch), at: p) }
        expectEqual(d.text, "hello")
        _ = d.undo()
        expectEqual(d.text, "", "a typing run should undo as one step")
        expectFalse(d.canUndo)
    }

    static func testCaretMoveBreaksCoalescing() {
        let d = TextDocument()
        var p = d.insert("ab", at: .zero)
        d.breakUndoCoalescing()
        p = d.insert("cd", at: p)
        expectEqual(d.text, "abcd")
        _ = d.undo()
        expectEqual(d.text, "ab")
        _ = d.undo()
        expectEqual(d.text, "")
    }

    static func testDeleteIsItsOwnUndoStep() {
        let d = TextDocument(text: "abc")
        _ = d.deleteBackward(at: Position(line: 0, column: 3))
        _ = d.deleteBackward(at: Position(line: 0, column: 2))
        expectEqual(d.text, "a")
        _ = d.undo()
        expectEqual(d.text, "ab")
        _ = d.undo()
        expectEqual(d.text, "abc")
    }

    static func testUndoAcrossMultilineEdit() {
        let d = TextDocument(text: "one\ntwo\nthree")
        _ = d.delete(from: Position(line: 0, column: 1), to: Position(line: 2, column: 2))
        expectEqual(d.text, "oree")
        _ = d.undo()
        expectEqual(d.text, "one\ntwo\nthree")
        expectEqual(d.lineCount, 3)
    }

    static func testNewEditClearsRedo() {
        let d = TextDocument()
        _ = d.insert("a", at: .zero)
        _ = d.undo()
        expectTrue(d.canRedo)
        _ = d.insert("b", at: .zero)
        expectFalse(d.canRedo)
    }

    static func testDirtyFlag() {
        let d = TextDocument(text: "x")
        expectFalse(d.isDirty)
        _ = d.insert("y", at: .zero)
        expectTrue(d.isDirty)
        _ = d.undo()
        expectFalse(d.isDirty, "undoing back to the save point makes the document clean again")
    }

    /// Regression: the save point is a group identity, not a stack depth. Undoing
    /// and then making a *different* edit lands at the same depth but must stay dirty.
    static func testUndoThenRetypeStaysDirty() {
        let d = TextDocument(text: "x")
        _ = d.insert("a", at: .zero)
        _ = d.undo()
        expectFalse(d.isDirty)
        d.breakUndoCoalescing()
        _ = d.insert("b", at: .zero)
        expectEqual(d.text, "bx")
        expectTrue(d.isDirty, "a different edit at the same undo depth is not the save point")
    }

    static func testSaveWithoutDestinationThrows() {
        let d = TextDocument(text: "unsaved")
        expectThrows({ try d.save() }) { error in
            expectTrue(error is TextDocumentError, "got \(error)")
        }
    }

    /// Regression: undo must shrink the tracked line width back down, or the view
    /// keeps a phantom horizontal scroll range.
    static func testUndoShrinksLongestLine() {
        let d = TextDocument(text: "short")
        _ = d.insert(String(repeating: "w", count: 200), at: .zero)
        expectEqual(d.longestLineLength, 205)
        _ = d.undo()
        expectEqual(d.longestLineLength, 5)
        _ = d.redo()
        expectEqual(d.longestLineLength, 205)
    }

    /// A combining mark merges with the character before it, so the caret advances
    /// by zero columns. The document must not treat that as a failed insert.
    static func testCombiningMarkMergesWithPreviousCharacter() {
        let d = TextDocument(text: "e")
        let after = d.insert("\u{0301}", at: Position(line: 0, column: 1))
        expectEqual(d.text, "é")
        expectEqual(d.lineLength(0), 1, "e + combining acute is one grapheme cluster")
        expectEqual(after, Position(line: 0, column: 1))
        let p = d.deleteBackward(at: after)
        expectEqual(d.text, "")
        expectEqual(p, .zero)
    }

    static func testByteOffsetRoundTripWithCombiningMarks() {
        let d = TextDocument(text: "e\u{0301}x\nquốc ngữ")
        for line in 0 ..< d.lineCount {
            for col in 0 ... d.lineLength(line) {
                let p = Position(line: line, column: col)
                expectEqual(d.position(ofByteOffset: d.byteOffset(of: p)), p)
            }
        }
    }

    static func testUndoRedoFuzzRoundTrip() {
        let d = TextDocument()
        var rng = SplitMix64(seed: 42)
        var snapshots: [String] = [""]

        for _ in 0 ..< 200 {
            d.breakUndoCoalescing()
            let line = Int(rng.next() % UInt64(d.lineCount))
            let column = Int(rng.next() % UInt64(d.lineLength(line) + 1))
            let p = Position(line: line, column: column)
            if rng.next() % 3 == 0, d.byteCount > 0 {
                _ = d.deleteBackward(at: p)
            } else {
                _ = d.insert(["q", "\n", "ü", "ab"][Int(rng.next() % 4)], at: p)
            }
            // No-op edits (backspace at the very start) record no undo group.
            if d.text != snapshots[snapshots.count - 1] { snapshots.append(d.text) }
        }

        let finalText = snapshots[snapshots.count - 1]
        var expected = snapshots
        while d.canUndo {
            expected.removeLast()
            _ = d.undo()
            if d.text != expected[expected.count - 1] {
                fail("undo diverged with \(expected.count - 1) steps remaining")
                return
            }
        }
        expectEqual(d.text, "")

        while d.canRedo { _ = d.redo() }
        expectEqual(d.text, finalText)
    }
}
