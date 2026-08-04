import Foundation
import MTextCore
import MTextTestKit

enum FoldingTests {

    static let suite = TestSuite("Folding", [
        ("measures indent width, expanding tabs", testIndentWidth),
        ("reports no indent for a blank line", testIndentBlank),
        ("finds a region where the next line is deeper", testFindRegion),
        ("declines a line with nothing indented under it", testNoRegion),
        ("keeps blank lines inside a region", testBlanksInside),
        ("trims trailing blanks off a region", testTrailingBlanks),
        ("finds nested regions", testNestedRegions),
        ("computes nesting level", testLevels),

        ("maps lines to visual rows across a fold", testVisualRow),
        ("maps visual rows back to lines", testLineForRow),
        ("round-trips every visible line", testRoundTrip),
        ("reports a hidden line at its fold's row", testHiddenLineRow),
        ("counts visible lines", testVisibleLineCount),

        ("absorbs a region enclosed by a new outer fold", testFoldAbsorbsInner),
        ("ignores a region already hidden inside a fold", testFoldIgnoresHidden),
        ("refuses a partially overlapping region", testFoldRefusesOverlap),
        ("toggles a region on and off", testToggle),

        ("shifts folds after lines are inserted above", testAdjustInsertAbove),
        ("grows a fold when lines are added inside it", testAdjustInsertInside),
        ("leaves folds before the edit alone", testAdjustBeforeFold),
        ("drops a fold collapsed to nothing by a deletion", testAdjustDropsEmptied),
    ])

    private static func document(_ text: String) -> TextDocument {
        let document = TextDocument()
        document.setText(text, url: nil, encoding: .utf8, lineEnding: .lf, modificationDate: nil)
        return document
    }

    // MARK: - Finding

    static func testIndentWidth() {
        expectEqual(FoldFinder.indentWidth("no indent", tabSize: 4), 0)
        expectEqual(FoldFinder.indentWidth("    four", tabSize: 4), 4)
        expectEqual(FoldFinder.indentWidth("\ttab", tabSize: 4), 4)
        expectEqual(FoldFinder.indentWidth("  \ttab after two spaces", tabSize: 4), 4,
                    "a tab advances to the next stop, not by a full tab width")
    }

    /// Blank lines must report nil so they can sit *inside* a fold — otherwise every
    /// paragraph break would chop a function into pieces.
    static func testIndentBlank() {
        expectNil(FoldFinder.indentWidth("", tabSize: 4))
        expectNil(FoldFinder.indentWidth("   ", tabSize: 4))
    }

    static func testFindRegion() {
        let doc = document("def f():\n    a\n    b\nafter")
        let region = FoldFinder.region(startingAt: 0, in: doc, tabSize: 4)
        expectEqual(region, FoldRegion(startLine: 0, endLine: 2))
        expectEqual(region?.hiddenLines, 1 ... 2)
    }

    static func testNoRegion() {
        let doc = document("one\ntwo\nthree")
        expectNil(FoldFinder.region(startingAt: 0, in: doc, tabSize: 4))
        expectNil(FoldFinder.region(startingAt: 2, in: doc, tabSize: 4), "last line")
    }

    static func testBlanksInside() {
        let doc = document("def f():\n    a\n\n    b\nafter")
        expectEqual(FoldFinder.region(startingAt: 0, in: doc, tabSize: 4),
                    FoldRegion(startLine: 0, endLine: 3))
    }

    /// Folding a function shouldn't swallow the empty lines separating it from the next.
    static func testTrailingBlanks() {
        let doc = document("def f():\n    a\n\n\nafter")
        expectEqual(FoldFinder.region(startingAt: 0, in: doc, tabSize: 4),
                    FoldRegion(startLine: 0, endLine: 1))
    }

    static func testNestedRegions() {
        let doc = document("class C:\n    def f():\n        a\n    def g():\n        b")
        let regions = FoldFinder.allRegions(in: doc, tabSize: 4)
        expectTrue(regions.contains(FoldRegion(startLine: 0, endLine: 4)), "the class")
        expectTrue(regions.contains(FoldRegion(startLine: 1, endLine: 2)), "the first method")
        expectTrue(regions.contains(FoldRegion(startLine: 3, endLine: 4)), "the second method")
    }

    static func testLevels() {
        let doc = document("class C:\n    def f():\n        a")
        let all = FoldFinder.allRegions(in: doc, tabSize: 4)
        let outer = all.first { $0.startLine == 0 }!
        let inner = all.first { $0.startLine == 1 }!
        expectEqual(FoldFinder.level(of: outer, among: all), 1)
        expectEqual(FoldFinder.level(of: inner, among: all), 2)
    }

    // MARK: - Mapping

    /// Lines 1–2 hidden: line 3 is the second visible row.
    private static var folded: FoldSet { FoldSet(regions: [FoldRegion(startLine: 0, endLine: 2)]) }

    static func testVisualRow() {
        let set = folded
        expectEqual(set.visualRow(forLine: 0), 0)
        expectEqual(set.visualRow(forLine: 3), 1)
        expectEqual(set.visualRow(forLine: 4), 2)
    }

    static func testLineForRow() {
        let set = folded
        expectEqual(set.line(forVisualRow: 0), 0)
        expectEqual(set.line(forVisualRow: 1), 3)
        expectEqual(set.line(forVisualRow: 2), 4)
    }

    static func testRoundTrip() {
        let set = FoldSet(regions: [FoldRegion(startLine: 2, endLine: 4),
                                    FoldRegion(startLine: 8, endLine: 10)])
        for line in [0, 1, 2, 5, 6, 7, 8, 11, 12] {
            expectEqual(set.line(forVisualRow: set.visualRow(forLine: line)), line,
                        "line \(line) should survive the round trip")
        }
    }

    /// A caret left inside a collapsed region has to resolve somewhere sensible rather
    /// than off the end of the document.
    static func testHiddenLineRow() {
        expectEqual(folded.visualRow(forLine: 1), 0)
        expectEqual(folded.visualRow(forLine: 2), 0)
        expectTrue(folded.isHidden(line: 1))
        expectFalse(folded.isHidden(line: 0), "the start line stays visible")
        expectFalse(folded.isHidden(line: 3))
    }

    static func testVisibleLineCount() {
        expectEqual(folded.hiddenLineCount, 2)
        expectEqual(folded.visibleLineCount(totalLines: 10), 8)
    }

    // MARK: - Fold set mutation

    static func testFoldAbsorbsInner() {
        var set = FoldSet(regions: [FoldRegion(startLine: 2, endLine: 3)])
        set.fold(FoldRegion(startLine: 0, endLine: 5))
        expectEqual(set.regions, [FoldRegion(startLine: 0, endLine: 5)],
                    "the outer fold replaces the one it encloses")
    }

    static func testFoldIgnoresHidden() {
        var set = FoldSet(regions: [FoldRegion(startLine: 0, endLine: 5)])
        set.fold(FoldRegion(startLine: 2, endLine: 3))
        expectEqual(set.regions.count, 1, "already invisible, so nothing to add")
    }

    static func testFoldRefusesOverlap() {
        var set = FoldSet(regions: [FoldRegion(startLine: 0, endLine: 5)])
        set.fold(FoldRegion(startLine: 3, endLine: 8))
        expectEqual(set.regions, [FoldRegion(startLine: 0, endLine: 5)],
                    "a partial overlap isn't sane nesting; leave the existing fold alone")
    }

    static func testToggle() {
        var set = FoldSet()
        let region = FoldRegion(startLine: 1, endLine: 4)
        expectTrue(set.toggle(region))
        expectTrue(set.isFolded(startLine: 1))
        expectTrue(set.toggle(region))
        expectFalse(set.isFolded(startLine: 1))
    }

    // MARK: - Editing

    static func testAdjustInsertAbove() {
        var set = FoldSet(regions: [FoldRegion(startLine: 5, endLine: 8)])
        set.adjust(afterEditAt: 0, linesDelta: 3)
        expectEqual(set.regions, [FoldRegion(startLine: 8, endLine: 11)])
    }

    static func testAdjustInsertInside() {
        var set = FoldSet(regions: [FoldRegion(startLine: 2, endLine: 6)])
        set.adjust(afterEditAt: 4, linesDelta: 2)
        expectEqual(set.regions, [FoldRegion(startLine: 2, endLine: 8)],
                    "the fold grows around the inserted lines")
    }

    static func testAdjustBeforeFold() {
        var set = FoldSet(regions: [FoldRegion(startLine: 10, endLine: 12)])
        set.adjust(afterEditAt: 20, linesDelta: 5)
        expectEqual(set.regions, [FoldRegion(startLine: 10, endLine: 12)])
    }

    /// Deleting a fold's whole body leaves nothing to hide, so the fold goes rather than
    /// lingering as a zero-height region.
    static func testAdjustDropsEmptied() {
        var set = FoldSet(regions: [FoldRegion(startLine: 2, endLine: 5)])
        set.adjust(afterEditAt: 3, linesDelta: -3)
        expectTrue(set.isEmpty)
    }
}
