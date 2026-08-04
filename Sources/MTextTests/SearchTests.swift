import Foundation
import MTextCore
import MTextTestKit

enum SearchTests {

    static let suite = TestSuite("Search", [
        ("literal search", testLiteralSearch),
        ("case sensitivity", testCaseSensitivity),
        ("whole word", testWholeWord),
        ("regex search", testRegexSearch),
        ("regex whole word wraps the pattern", testRegexWholeWord),
        ("regex captures are kept", testRegexCaptures),
        ("invalid regex is reported, not thrown", testInvalidRegex),
        ("zero-width regex still advances", testZeroWidthRegex),
        ("find next wraps", testFindNextWraps),
        ("find previous wraps", testFindPreviousWraps),
        ("find in selection", testFindInSelection),
        ("multibyte columns are correct", testMultibyteColumns),
        ("template expands groups", testTemplateGroups),
        ("template escapes", testTemplateEscapes),
        ("preserve case", testPreserveCase),
        ("session cycles matches", testSessionCycling),
        ("session reports status", testSessionStatus),
        ("replace current advances", testReplaceCurrent),
        ("replace all is one undo step", testReplaceAllUndo),
        ("replace all handles length changes", testReplaceAllLengthChanges),
        ("replace all with regex captures", testReplaceAllRegex),
        ("session follows document edits", testSessionFollowsEdits),
        ("changing the query discards old matches", testQueryChangeInvalidates),
        ("adjacent matches are reachable", testAdjacentMatches),
    ])

    // MARK: - Matching

    static func testLiteralSearch() {
        let d = TextDocument(text: "one two\nthree two")
        let matches = d.findAll(SearchQuery.literal("two"))
        expectEqual(matches.count, 2)
        expectEqual(matches[0].region.start, Position(line: 0, column: 4))
        expectEqual(matches[1].region.start, Position(line: 1, column: 6))
        expectEqual(matches[0].text, "two")
    }

    static func testCaseSensitivity() {
        let d = TextDocument(text: "Cat cat CAT")
        expectEqual(d.findAll(SearchQuery.literal("cat")).count, 1)
        expectEqual(d.findAll(SearchQuery.literal("cat", caseSensitive: false)).count, 3)
    }

    static func testWholeWord() {
        let d = TextDocument(text: "cat cathode concat cat")
        var query = SearchQuery.literal("cat")
        query.wholeWord = true
        expectEqual(d.findAll(query).count, 2)
    }

    static func testRegexSearch() {
        let d = TextDocument(text: "a1 b22 c333")
        var query = SearchQuery(pattern: "[a-z](\\d+)")
        query.isRegex = true
        let matches = d.findAll(query)
        expectEqual(matches.count, 3)
        expectEqual(matches[1].text, "b22")
        expectEqual(matches[2].region.start, Position(line: 0, column: 7))
    }

    static func testRegexWholeWord() {
        let d = TextDocument(text: "cat cathode")
        var query = SearchQuery(pattern: "cat|dog")
        query.isRegex = true
        query.wholeWord = true
        // The alternation must be grouped, or \b binds only to the first branch.
        let matches = d.findAll(query)
        expectEqual(matches.count, 1)
        expectEqual(matches[0].region.start, Position(line: 0, column: 0))
    }

    static func testRegexCaptures() {
        let d = TextDocument(text: "key = value")
        var query = SearchQuery(pattern: "(\\w+)\\s*=\\s*(\\w+)")
        query.isRegex = true
        guard let match = d.findAll(query).first else {
            fail("no match")
            return
        }
        expectEqual(match.groups[0], "key = value")
        expectEqual(match.groups[1], "key")
        expectEqual(match.groups[2], "value")
    }

    static func testInvalidRegex() {
        var query = SearchQuery(pattern: "(unclosed")
        query.isRegex = true
        expectTrue(SearchMatcher.validate(query) != nil, "a bad pattern reports an error")
        // And the document API returns nothing rather than trapping.
        let d = TextDocument(text: "text")
        expectEqual(d.findAll(query).count, 0)
    }

    static func testZeroWidthRegex() {
        let d = TextDocument(text: "abc")
        var query = SearchQuery(pattern: "x*")
        query.isRegex = true
        let matches = d.findAll(query)
        // One empty match per position, not an infinite loop.
        expectTrue(matches.count >= 3 && matches.count <= 4, "got \(matches.count)")
    }

    static func testFindNextWraps() {
        let d = TextDocument(text: "foo\nbar\nfoo")
        let query = SearchQuery.literal("foo")
        expectEqual(d.findNext(query, after: Position(line: 0, column: 1))?.region.start,
                    Position(line: 2, column: 0))
        expectEqual(d.findNext(query, after: Position(line: 2, column: 1))?.region.start,
                    Position(line: 0, column: 0))

        var noWrap = query
        noWrap.wrap = false
        expectNil(d.findNext(noWrap, after: Position(line: 2, column: 1)))
    }

    static func testFindPreviousWraps() {
        let d = TextDocument(text: "foo\nbar\nfoo")
        let query = SearchQuery.literal("foo")
        expectEqual(d.findPrevious(query, before: Position(line: 2, column: 0))?.region.start,
                    Position(line: 0, column: 0))
        expectEqual(d.findPrevious(query, before: Position(line: 0, column: 0))?.region.start,
                    Position(line: 2, column: 0), "wraps to the bottom")
    }

    static func testFindInSelection() {
        let d = TextDocument(text: "x\nfoo\nfoo\nx")
        let region = Region(anchor: Position(line: 1, column: 0), head: Position(line: 2, column: 3))
        expectEqual(d.findAll(SearchQuery.literal("foo"), in: region).count, 2)

        let narrow = Region(anchor: Position(line: 1, column: 0), head: Position(line: 1, column: 3))
        expectEqual(d.findAll(SearchQuery.literal("foo"), in: narrow).count, 1)
    }

    static func testMultibyteColumns() {
        let d = TextDocument(text: "ếxếy")
        let matches = d.findAll(SearchQuery.literal("x"))
        expectEqual(matches.count, 1)
        expectEqual(matches[0].region.start, Position(line: 0, column: 1),
                    "columns count graphemes, not UTF-16 units")

        var regex = SearchQuery(pattern: "x|y")
        regex.isRegex = true
        let both = d.findAll(regex)
        expectEqual(both.count, 2)
        expectEqual(both[0].region.start.column, 1)
        expectEqual(both[1].region.start.column, 3)
    }

    // MARK: - Replacement templates

    private static func match(_ groups: [Int: String], text: String) -> SearchMatch {
        SearchMatch(region: Region(caret: .zero), text: text, groups: groups)
    }

    static func testTemplateGroups() {
        let m = match([0: "a=b", 1: "a", 2: "b"], text: "a=b")
        expectEqual(ReplacementTemplate.expand("$2=$1", match: m), "b=a")
        expectEqual(ReplacementTemplate.expand("\\2=\\1", match: m), "b=a")
        expectEqual(ReplacementTemplate.expand("${2}x", match: m), "bx")
        expectEqual(ReplacementTemplate.expand("[$0]", match: m), "[a=b]")
        expectEqual(ReplacementTemplate.expand("$9", match: m), "", "missing groups expand to nothing")
    }

    static func testTemplateEscapes() {
        let m = match([0: "x", 1: "x"], text: "x")
        expectEqual(ReplacementTemplate.expand("a\\nb", match: m), "a\nb")
        expectEqual(ReplacementTemplate.expand("a\\tb", match: m), "a\tb")
        expectEqual(ReplacementTemplate.expand("$$1", match: m), "$1", "$$ is a literal dollar")
        expectEqual(ReplacementTemplate.expand("100$", match: m), "100$")
        expectEqual(ReplacementTemplate.expand("a\\\\b", match: m), "a\\b")
    }

    static func testPreserveCase() {
        expectEqual(ReplacementTemplate.expand("dog", match: match([:], text: "CAT"),
                                               preserveCase: true), "DOG")
        expectEqual(ReplacementTemplate.expand("dog", match: match([:], text: "Cat"),
                                               preserveCase: true), "Dog")
        expectEqual(ReplacementTemplate.expand("DOG", match: match([:], text: "cat"),
                                               preserveCase: true), "dog")
        // Mixed case is left alone.
        expectEqual(ReplacementTemplate.expand("dog", match: match([:], text: "cAt"),
                                               preserveCase: true), "dog")
        // A single capital is "capitalised", not "all caps".
        expectEqual(ReplacementTemplate.expand("dog", match: match([:], text: "C"),
                                               preserveCase: true), "Dog")
    }

    // MARK: - Session

    static func testSessionCycling() {
        let d = TextDocument(text: "a\na\na")
        let session = SearchSession(document: d)
        session.setQuery(.literal("a"), near: .zero)
        expectEqual(session.matchCount, 3)

        expectEqual(session.selectNext()?.region.start.line, 1)
        expectEqual(session.selectNext()?.region.start.line, 2)
        expectEqual(session.selectNext()?.region.start.line, 0, "wraps")
        expectEqual(session.selectPrevious()?.region.start.line, 2, "wraps backwards")
    }

    static func testSessionStatus() {
        let d = TextDocument(text: "a b a")
        let session = SearchSession(document: d)
        expectNil(session.statusText, "no query, no status")

        session.setQuery(.literal("a"), near: .zero)
        expectEqual(session.statusText, "1 of 2")

        session.setQuery(.literal("zzz"), near: .zero)
        expectEqual(session.statusText, "No results")

        var bad = SearchQuery(pattern: "(")
        bad.isRegex = true
        session.setQuery(bad, near: .zero)
        expectTrue(session.errorMessage != nil)
    }

    static func testReplaceCurrent() {
        let d = TextDocument(text: "cat cat cat")
        let session = SearchSession(document: d)
        session.setQuery(.literal("cat"), near: .zero)

        _ = session.replaceCurrent(with: "dog")
        expectEqual(d.text, "dog cat cat")
        _ = session.replaceCurrent(with: "dog")
        expectEqual(d.text, "dog dog cat", "the second replace hits the next match, not the first")
    }

    static func testReplaceAllUndo() {
        let d = TextDocument(text: "a\na\na")
        let session = SearchSession(document: d)
        session.setQuery(.literal("a"), near: .zero)

        expectEqual(session.replaceAll(with: "b"), 3)
        expectEqual(d.text, "b\nb\nb")
        _ = d.undo()
        expectEqual(d.text, "a\na\na", "replace all must undo in one step")
        expectFalse(d.canUndo)
    }

    /// Regression guard for the multi-region rebasing rule: replacements of a different
    /// length must not shift the matches still to be processed.
    static func testReplaceAllLengthChanges() {
        let d = TextDocument(text: "x.x.x")
        let session = SearchSession(document: d)
        session.setQuery(.literal("x"), near: .zero)
        expectEqual(session.replaceAll(with: "LONG"), 3)
        expectEqual(d.text, "LONG.LONG.LONG")

        let shrink = TextDocument(text: "abc abc abc")
        let session2 = SearchSession(document: shrink)
        session2.setQuery(.literal("abc"), near: .zero)
        expectEqual(session2.replaceAll(with: "z"), 3)
        expectEqual(shrink.text, "z z z")
    }

    static func testReplaceAllRegex() {
        let d = TextDocument(text: "a=1\nb=2")
        let session = SearchSession(document: d)
        var query = SearchQuery(pattern: "(\\w+)=(\\d+)")
        query.isRegex = true
        session.setQuery(query, near: .zero)

        expectEqual(session.replaceAll(with: "$2:$1"), 2)
        expectEqual(d.text, "1:a\n2:b")
    }

    /// Regression: refresh keyed only on the document generation let a new query reuse
    /// the previous query's matches — so Replace could overwrite non-matching text.
    static func testQueryChangeInvalidates() {
        let d = TextDocument(text: "cat cat dog")
        let session = SearchSession(document: d)

        session.setQuery(.literal("cat"), near: .zero)
        expectEqual(session.matchCount, 2)
        expectEqual(session.statusText, "1 of 2")

        // Same document generation, previous query had matches and a selection.
        session.setQuery(.literal("dog"), near: .zero)
        expectEqual(session.matchCount, 1, "the new query must be recomputed")
        expectEqual(session.currentMatch?.region.start, Position(line: 0, column: 8))

        session.setQuery(.literal("zzz"), near: .zero)
        expectEqual(session.statusText, "No results")

        var bad = SearchQuery(pattern: "(")
        bad.isRegex = true
        session.setQuery(bad, near: .zero)
        expectTrue(session.errorMessage != nil, "an invalid pattern must be reported")
        expectEqual(session.matchCount, 0)

        // And a replace against a stale list must be impossible.
        session.setQuery(.literal("dog"), near: .zero)
        _ = session.replaceCurrent(with: "wolf")
        expectEqual(d.text, "cat cat wolf")
    }

    /// Regression: a strict `>` on the boundary made back-to-back matches unreachable.
    static func testAdjacentMatches() {
        let d = TextDocument(text: "aaaa")
        let session = SearchSession(document: d)
        session.setQuery(.literal("aa"), near: .zero)
        expectEqual(session.matchCount, 2)

        // Walking by the end of each match must reach both, then wrap.
        var reached: [Int] = []
        var cursor = Position.zero
        for _ in 0 ..< 3 {
            guard let match = session.selectNext(from: cursor) else { break }
            reached.append(match.region.start.column)
            cursor = match.region.end
        }
        expectEqual(reached, [0, 2, 0], "both matches reachable, then wrap")
    }

    static func testSessionFollowsEdits() {
        let d = TextDocument(text: "a a")
        let session = SearchSession(document: d)
        session.setQuery(.literal("a"), near: .zero)
        expectEqual(session.matchCount, 2)

        _ = d.insert(" a", at: Position(line: 0, column: 3))
        session.documentChanged()
        expectEqual(session.matchCount, 3, "the match list follows the document")

        // "a a a" is exactly five characters, so deleting [0,4) leaves a single "a".
        _ = d.delete(from: .zero, to: Position(line: 0, column: 4))
        session.documentChanged()
        expectEqual(session.matchCount, 1)
    }
}
