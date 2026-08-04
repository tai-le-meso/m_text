import Foundation
import MTextCore
import MTextTestKit

enum PhantomTests {

    static let suite = TestSuite("Phantom", [
        ("counts one row per phantom", testRowsPerLine),
        ("stacks several phantoms on one line", testStacking),
        ("removes only one owner's phantoms", testRemoveByOwner),
        ("shifts phantoms after an insertion above", testAdjustInsert),
        ("drops a phantom whose line was deleted away", testAdjustDelete),
        ("leaves phantoms above the edit alone", testAdjustAbove),

        ("a phantom adds a row to the document", testRowMapAddsRow),
        ("later lines shift down by the phantom rows", testRowMapShifts),
        ("a phantom row is distinguishable from a text row", testIsPhantomRow),
        ("a folded line contributes no phantom rows", testFoldedPhantomsHidden),
        ("phantoms combine with wrapped lines", testWithWrapping),
    ])

    private static func phantom(_ line: Int, _ text: String, owner: String = "build") -> Phantom {
        Phantom(line: line, text: text, kind: .error, owner: owner)
    }

    // MARK: - Set

    static func testRowsPerLine() {
        let set = PhantomSet([phantom(3, "boom")])
        expectEqual(set.rowsPerLine, [3: 1])
    }

    static func testStacking() {
        let set = PhantomSet([phantom(3, "one"), phantom(3, "two")])
        expectEqual(set.rowsPerLine, [3: 2])
        expectEqual(set.phantoms(onLine: 3).count, 2)
    }

    /// A build clearing its errors must not remove a different source's annotations.
    static func testRemoveByOwner() {
        var set = PhantomSet([phantom(1, "a", owner: "build"),
                              phantom(2, "b", owner: "lint")])
        set.removeAll(owner: "build")
        expectEqual(set.phantoms.count, 1)
        expectEqual(set.phantoms.first?.owner, "lint")
    }

    static func testAdjustInsert() {
        var set = PhantomSet([phantom(5, "x")])
        set.adjust(afterEditAt: 0, linesDelta: 3)
        expectEqual(set.phantoms.first?.line, 8)
    }

    /// An annotation whose line is gone has nothing left to annotate — the same rule
    /// `FoldSet.adjust` follows.
    static func testAdjustDelete() {
        var set = PhantomSet([phantom(2, "x")])
        set.adjust(afterEditAt: 0, linesDelta: -5)
        expectTrue(set.isEmpty)
    }

    static func testAdjustAbove() {
        var set = PhantomSet([phantom(1, "x")])
        set.adjust(afterEditAt: 10, linesDelta: 4)
        expectEqual(set.phantoms.first?.line, 1)
    }

    // MARK: - RowMap integration

    private static func map(lines: [String], wrapWidth: Int = 0,
                            phantoms: PhantomSet = PhantomSet(),
                            folds: FoldSet = FoldSet()) -> RowMap {
        var map = RowMap()
        map.rebuild(lineProvider: { lines[$0] }, lineCount: lines.count,
                    wrapWidth: wrapWidth, tabSize: 4)
        map.setFolds(folds)
        map.setPhantomRows(phantoms.rowsPerLine)
        return map
    }

    static func testRowMapAddsRow() {
        let plain = map(lines: ["a", "b", "c"])
        expectEqual(plain.totalRows, 3)

        let annotated = map(lines: ["a", "b", "c"], phantoms: PhantomSet([phantom(1, "x")]))
        expectEqual(annotated.totalRows, 4, "the phantom takes a row of its own")
        expectEqual(annotated.rows(forLine: 1), 2, "the line plus its annotation")
    }

    static func testRowMapShifts() {
        let annotated = map(lines: ["a", "b", "c"], phantoms: PhantomSet([phantom(0, "x")]))
        expectEqual(annotated.firstRow(ofLine: 0), 0)
        expectEqual(annotated.firstRow(ofLine: 1), 2, "pushed down past the annotation")
        expectEqual(annotated.firstRow(ofLine: 2), 3)
    }

    /// Drawing needs to know whether a row is text or annotation; phantom rows come after
    /// the line's own wrapped rows, so it reads as sitting below.
    static func testIsPhantomRow() {
        let annotated = map(lines: ["a", "b"], phantoms: PhantomSet([phantom(0, "x")]))
        expectFalse(annotated.isPhantomRow(line: 0, rowInLine: 0), "the line's own text")
        expectTrue(annotated.isPhantomRow(line: 0, rowInLine: 1), "its annotation")
        expectEqual(annotated.location(ofRow: 1).line, 0)
        expectEqual(annotated.location(ofRow: 1).rowInLine, 1)
    }

    /// A phantom on a collapsed line would otherwise float free of the text it annotates.
    static func testFoldedPhantomsHidden() {
        let annotated = map(lines: ["a", "b", "c", "d"],
                            phantoms: PhantomSet([phantom(1, "x")]),
                            folds: FoldSet(regions: [FoldRegion(startLine: 0, endLine: 2)]))
        expectEqual(annotated.rows(forLine: 1), 0)
        expectEqual(annotated.totalRows, 2, "the fold's start line and the line after it")
    }

    static func testWithWrapping() {
        // 10 chars at width 4 → 3 wrapped rows, plus one phantom row.
        let annotated = map(lines: [String(repeating: "x", count: 10), "b"],
                            wrapWidth: 4,
                            phantoms: PhantomSet([phantom(0, "note")]))
        expectEqual(annotated.wrapRows(forLine: 0), 3)
        expectEqual(annotated.rows(forLine: 0), 4)
        expectTrue(annotated.isPhantomRow(line: 0, rowInLine: 3))
        expectFalse(annotated.isPhantomRow(line: 0, rowInLine: 2), "still the wrapped text")
        expectEqual(annotated.firstRow(ofLine: 1), 4)
    }
}
