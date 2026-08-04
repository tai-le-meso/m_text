import Foundation
import MTextCore
import MTextTestKit

/// Guards the budgets in PLAN.md §2.4. Wall-clock assertions with generous margins,
/// so they fail only on real regressions.
///
/// Run these against an optimised build — `make test-release` — a debug build is
/// several times slower and the numbers are meaningless.
enum PerformanceTests {

    static let suite = TestSuite("Performance", [
        ("opening a large document is fast", testOpenLargeDocumentIsFast),
        ("random edits stay fast", testRandomEditsStayFast),
        ("random line lookups are logarithmic", testRandomLineLookupsAreLogarithmic),
        ("tree height stays logarithmic", testTreeHeightStaysLogarithmic),
        ("fuzzy ranking 100k entries per keystroke is fast", testFuzzyRanking100kEntriesIsFast),
        ("autocomplete on a large buffer stays within a keystroke", testCompletionOnLargeBufferIsFast),
        ("word-wrap row map rebuilds and patches fast enough", testRowMapIsFast),
    ])

    private static func makeLargeText(lines: Int) -> String {
        var s = String()
        s.reserveCapacity(lines * 60)
        for i in 0 ..< lines {
            s += "func example\(i)() { return \(i) * 2 } // filler text here\n"
        }
        return s
    }

    static func testOpenLargeDocumentIsFast() {
        let text = makeLargeText(lines: 200_000) // ~11 MB
        let start = Date()
        let doc = TextDocument(text: text)
        let elapsed = Date().timeIntervalSince(start)
        expectEqual(doc.lineCount, 200_001)
        expectLessThan(elapsed, 4.0, String(format: "loading 200k lines took %.2fs", elapsed))
    }

    static func testRandomEditsStayFast() {
        var tree = PieceTree(text: makeLargeText(lines: 100_000))
        var rng = SplitMix64(seed: 7)
        let start = Date()
        for _ in 0 ..< 5_000 {
            tree.insert("x", at: Int(rng.next() % UInt64(tree.byteCount)))
        }
        let elapsed = Date().timeIntervalSince(start)
        expectLessThan(elapsed, 5.0, String(format: "5k random inserts took %.2fs", elapsed))
        expectTrue(tree.validate())
    }

    static func testRandomLineLookupsAreLogarithmic() {
        let tree = PieceTree(text: makeLargeText(lines: 200_000))
        var rng = SplitMix64(seed: 11)
        let start = Date()
        for _ in 0 ..< 20_000 {
            _ = tree.lineText(Int(rng.next() % 200_000))
        }
        let elapsed = Date().timeIntervalSince(start)
        expectLessThan(elapsed, 4.0, String(format: "20k random line lookups took %.2fs", elapsed))
    }

    static func testTreeHeightStaysLogarithmic() {
        var tree = PieceTree(text: makeLargeText(lines: 50_000))
        var rng = SplitMix64(seed: 13)
        for _ in 0 ..< 10_000 {
            tree.insert("y", at: Int(rng.next() % UInt64(tree.byteCount)))
        }
        // ~2.8 MB in 64 KB chunks plus 10k edits: a balanced tree stays well under 60.
        expectLessThan(tree.treeHeight, 60, "height \(tree.treeHeight) suggests lost balance")
    }

    /// T70's budget: Goto Anything re-ranks the whole file index on every keystroke, so
    /// a project with a six-figure file count still needs to feel instant.
    static func testFuzzyRanking100kEntriesIsFast() {
        var rng = SplitMix64(seed: 17)
        let segments = ["src", "lib", "test", "vendor", "internal", "pkg", "cmd", "app"]
        let names = ["main", "index", "utils", "helper", "model", "controller", "service",
                     "router", "config", "client", "server", "types", "constants"]
        let extensions = ["swift", "ts", "js", "go", "py", "rs", "java", "md"]

        var candidates: [String] = []
        candidates.reserveCapacity(100_000)
        for _ in 0 ..< 100_000 {
            let a = segments[Int(rng.next() % UInt64(segments.count))]
            let b = segments[Int(rng.next() % UInt64(segments.count))]
            let n = names[Int(rng.next() % UInt64(names.count))]
            let e = extensions[Int(rng.next() % UInt64(extensions.count))]
            candidates.append("\(a)/\(b)/\(n)\(rng.next() % 1000).\(e)")
        }

        let start = Date()
        let ranked = FuzzyMatcher.rank(query: "svctl", candidates: candidates)
        let elapsed = Date().timeIntervalSince(start)
        expectLessThan(elapsed, 0.25, String(format: "ranking 100k entries took %.3fs", elapsed))
        if ranked.count > 1 {
            for i in 1 ..< ranked.count {
                expectTrue(ranked[i - 1].match.score >= ranked[i].match.score, "ranked results must stay sorted")
            }
        }
    }

    /// T90's budget. Autocomplete runs on the *keystroke* path, so it is the one feature
    /// where an over-eager full-buffer scan is felt directly as typing lag.
    ///
    /// Measures the two halves separately because they have very different shapes: the
    /// word scan is O(document) and happens once per edit, while ranking runs against the
    /// cached word list on every keystroke. The second number is the one that has to stay
    /// small — and the cached re-query is asserted to be far cheaper than the cold scan,
    /// which is the whole reason `BufferWordIndex` keys on the document generation.
    static func testCompletionOnLargeBufferIsFast() {
        let document = TextDocument(text: makeLargeText(lines: 100_000))
        let index = BufferWordIndex()

        let scanStart = Date()
        let words = index.words(in: document)
        let scanElapsed = Date().timeIntervalSince(scanStart)
        expectTrue(words.count > 1000, "a 100k-line buffer should yield plenty of words")
        expectLessThan(scanElapsed, 2.0, String(format: "cold word scan took %.3fs", scanElapsed))

        let cachedStart = Date()
        for _ in 0 ..< 20 { _ = index.words(in: document) }
        let cachedElapsed = Date().timeIntervalSince(cachedStart)
        expectLessThan(cachedElapsed, scanElapsed,
                       String(format: "20 cached lookups (%.4fs) must beat one cold scan (%.3fs)",
                              cachedElapsed, scanElapsed))

        // One keystroke's worth of work: rank the cached list against the current prefix.
        let rankStart = Date()
        let items = CompletionEngine.complete(prefix: "exa", bufferWords: words, symbols: [])
        let rankElapsed = Date().timeIntervalSince(rankStart)
        expectFalse(items.isEmpty)
        expectLessThan(rankElapsed, 0.1, String(format: "ranking one keystroke took %.3fs", rankElapsed))
    }

    /// T28's design constraint, measured rather than assumed. A full rebuild happens on
    /// every window resize and font change; `updateLines` runs per edit, so it is the one
    /// that must stay off the keystroke critical path.
    static func testRowMapIsFast() {
        let lineCount = 200_000
        let lines = (0 ..< lineCount).map { "func example\($0)() { return \($0) * 2 } // filler text here" }
        var map = RowMap()

        let rebuildStart = Date()
        map.rebuild(lineProvider: { lines[$0] }, lineCount: lineCount, wrapWidth: 40, tabSize: 4)
        let rebuildElapsed = Date().timeIntervalSince(rebuildStart)
        expectTrue(map.totalRows > lineCount, "wrapping at 40 columns must add rows")
        expectLessThan(rebuildElapsed, 3.0,
                       String(format: "rebuilding 200k wrapped lines took %.3fs", rebuildElapsed))

        // One edit: re-wrap a single line and re-index. This is what a keystroke costs.
        let editStart = Date()
        for _ in 0 ..< 50 {
            map.updateLines(1000 ..< 1001, lineProvider: { lines[$0] },
                            newLineCount: lineCount, tabSize: 4)
        }
        let editElapsed = Date().timeIntervalSince(editStart) / 50
        expectLessThan(editElapsed, 0.02,
                       String(format: "one edit re-index took %.4fs", editElapsed))

        // Hit testing is binary search, so a row at the end must cost the same as one at
        // the start — a linear scan here would be invisible until a big file arrived.
        let lookupStart = Date()
        for row in stride(from: 0, to: map.totalRows, by: max(1, map.totalRows / 5000)) {
            _ = map.location(ofRow: row)
        }
        let lookupElapsed = Date().timeIntervalSince(lookupStart)
        expectLessThan(lookupElapsed, 0.5,
                       String(format: "5000 row lookups took %.3fs", lookupElapsed))
    }
}
