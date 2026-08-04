import Foundation
import MTextCore
import MTextTestKit

enum PieceTreeTests {

    static let suite = TestSuite("PieceTree", [
        ("empty tree", testEmpty),
        ("insert and read", testInsertAndRead),
        ("repeated middle inserts", testInsertInMiddleRepeatedly),
        ("delete", testDelete),
        ("replace", testReplace),
        ("line index", testLineIndex),
        ("trailing newline makes an empty last line", testTrailingNewlineMakesEmptyLastLine),
        ("lineOfOffset", testLineOfOffset),
        ("line index survives edits", testLineIndexAfterEdits),
        ("multibyte boundaries", testMultibyteBoundaries),
        ("chunking across a large insert", testChunkingAcrossLargeInsert),
        ("stays balanced under many inserts", testStaysBalancedUnderManyInserts),
        ("snapshot is independent", testSnapshotIsIndependent),
        ("fuzz against a reference string", testFuzzAgainstReferenceString),
    ])

    static func testEmpty() {
        let t = PieceTree()
        expectEqual(t.byteCount, 0)
        expectEqual(t.lineCount, 1)
        expectEqual(t.text, "")
        expectEqual(t.lineText(0), "")
        expectTrue(t.validate())
    }

    static func testInsertAndRead() {
        var t = PieceTree()
        t.insert("hello", at: 0)
        t.insert(" world", at: 5)
        t.insert("say: ", at: 0)
        expectEqual(t.text, "say: hello world")
        expectEqual(t.text(offset: 5, length: 5), "hello")
        expectTrue(t.validate())
    }

    static func testInsertInMiddleRepeatedly() {
        var t = PieceTree(text: "ad")
        t.insert("b", at: 1)
        t.insert("c", at: 2)
        expectEqual(t.text, "abcd")
        expectTrue(t.validate())
    }

    static func testDelete() {
        var t = PieceTree(text: "0123456789")
        t.delete(offset: 3, length: 4)
        expectEqual(t.text, "012789")
        t.delete(offset: 0, length: 100)
        expectEqual(t.text, "")
        expectEqual(t.lineCount, 1)
        expectTrue(t.validate())
    }

    static func testReplace() {
        var t = PieceTree(text: "the quick fox")
        t.replace(offset: 4, length: 5, with: "slow")
        expectEqual(t.text, "the slow fox")
        expectTrue(t.validate())
    }

    static func testLineIndex() {
        let t = PieceTree(text: "alpha\nbeta\n\ngamma")
        expectEqual(t.lineCount, 4)
        expectEqual(t.lineText(0), "alpha")
        expectEqual(t.lineText(1), "beta")
        expectEqual(t.lineText(2), "")
        expectEqual(t.lineText(3), "gamma")
        expectEqual(t.offsetOfLine(0), 0)
        expectEqual(t.offsetOfLine(1), 6)
        expectEqual(t.offsetOfLine(2), 11)
        expectEqual(t.offsetOfLine(3), 12)
    }

    static func testTrailingNewlineMakesEmptyLastLine() {
        let t = PieceTree(text: "a\n")
        expectEqual(t.lineCount, 2)
        expectEqual(t.lineText(1), "")
    }

    static func testLineOfOffset() {
        let t = PieceTree(text: "ab\ncd\nef")
        expectEqual(t.lineOfOffset(0), 0)
        expectEqual(t.lineOfOffset(2), 0, "the '\\n' itself belongs to line 0")
        expectEqual(t.lineOfOffset(3), 1)
        expectEqual(t.lineOfOffset(6), 2)
        expectEqual(t.lineOfOffset(8), 2)
    }

    static func testLineIndexAfterEdits() {
        var t = PieceTree(text: "one\ntwo")
        t.insert("\nzero", at: 0)
        expectEqual(t.text, "\nzeroone\ntwo")
        expectEqual(t.lineCount, 3)
        expectEqual(t.lineText(0), "")
        expectEqual(t.lineText(1), "zeroone")
        expectEqual(t.lineText(2), "two")
        t.delete(offset: 0, length: 1)
        expectEqual(t.lineCount, 2)
        expectEqual(t.lineText(0), "zeroone")
        expectTrue(t.validate())
    }

    static func testMultibyteBoundaries() {
        var t = PieceTree(text: "Tiếng Việt")
        expectEqual(t.text, "Tiếng Việt")
        let prefixBytes = "Tiếng ".utf8.count
        t.insert("🇻🇳 ", at: prefixBytes)
        expectEqual(t.text, "Tiếng 🇻🇳 Việt")
        expectTrue(t.validate())
    }

    static func testChunkingAcrossLargeInsert() {
        var t = PieceTree()
        let block = String(repeating: "abcdefghij\n", count: 20_000) // ~220 KB, > chunkSize
        t.insert(block, at: 0)
        expectEqual(t.byteCount, block.utf8.count)
        expectEqual(t.lineCount, 20_001)
        expectEqual(t.lineText(0), "abcdefghij")
        expectEqual(t.lineText(19_999), "abcdefghij")
        expectEqual(t.lineText(20_000), "")
        expectTrue(t.validate())
    }

    static func testStaysBalancedUnderManyInserts() {
        var t = PieceTree()
        for i in 0 ..< 3_000 { t.insert("x", at: i / 2) }
        expectTrue(t.validate())
        expectLessThan(t.treeHeight, 60, "AVL height must stay logarithmic")
    }

    static func testSnapshotIsIndependent() {
        var t = PieceTree(text: "original")
        let snap = t
        t.insert(" changed", at: 8)
        expectEqual(snap.text, "original")
        expectEqual(t.text, "original changed")
    }

    // MARK: - Fuzz against a naive reference implementation

    static func testFuzzAgainstReferenceString() {
        var rng = SplitMix64(seed: 0xC0FFEE)
        var tree = PieceTree()
        var reference = ""

        let words = ["a", "bb", "ccc", "\n", "hé\n", "🇻🇳", "  ", "line\ntext"]

        for step in 0 ..< 1_500 {
            let bytes = Array(reference.utf8)
            let doInsert = reference.isEmpty || rng.next() % 100 < 60

            if doInsert {
                let word = words[Int(rng.next() % UInt64(words.count))]
                var offset = bytes.isEmpty ? 0 : Int(rng.next() % UInt64(bytes.count + 1))
                // Never split a UTF-8 sequence — offsets must be scalar-aligned.
                while offset < bytes.count && (bytes[offset] & 0xC0) == 0x80 { offset += 1 }
                tree.insert(word, at: offset)
                reference = insert(word, into: reference, atByte: offset)
            } else {
                var offset = Int(rng.next() % UInt64(bytes.count))
                while offset < bytes.count && (bytes[offset] & 0xC0) == 0x80 { offset += 1 }
                var length = Int(rng.next() % UInt64(max(1, bytes.count - offset))) + 1
                var end = offset + length
                while end < bytes.count && (bytes[end] & 0xC0) == 0x80 { end += 1 }
                length = end - offset
                tree.delete(offset: offset, length: length)
                reference = delete(from: reference, atByte: offset, length: length)
            }

            if tree.text != reference {
                fail("text diverged at step \(step)")
                return
            }
            if !tree.validate() {
                fail("tree invariants broken at step \(step)")
                return
            }
        }

        // The line index must agree with the reference too.
        let referenceLines = reference.components(separatedBy: "\n")
        expectEqual(tree.lineCount, referenceLines.count)
        for i in 0 ..< min(tree.lineCount, referenceLines.count) {
            expectEqual(tree.lineText(i), referenceLines[i], "line \(i)")
        }
    }

    private static func insert(_ s: String, into base: String, atByte offset: Int) -> String {
        var bytes = Array(base.utf8)
        bytes.insert(contentsOf: Array(s.utf8), at: min(offset, bytes.count))
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func delete(from base: String, atByte offset: Int, length: Int) -> String {
        var bytes = Array(base.utf8)
        let start = min(offset, bytes.count)
        let end = min(offset + length, bytes.count)
        guard start < end else { return base }
        bytes.removeSubrange(start ..< end)
        return String(decoding: bytes, as: UTF8.self)
    }
}
