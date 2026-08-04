import Foundation
import MTextCore
import MTextTestKit

enum SpellCheckScopesTests {

    static let suite = TestSuite("SpellCheckScopes", [
        ("checks nothing in code while highlighting has not arrived", testNilSpans),
        ("still checks prose that has no spans yet", testNilSpansPlainText),
        ("checks the whole line of a plain-text document", testEmptySpans),
        ("checks comments", testComments),
        ("checks strings", testStrings),
        ("skips code outside comments and strings", testSkipsCode),
        ("merges adjacent checkable spans", testMergesAdjacent),
        ("clamps a span that runs past the line", testClampsSpans),
        ("checks nothing on an empty line", testEmptyLine),
        ("honours a custom selector list", testCustomSelectors),
    ])

    private static func span(_ start: Int, _ end: Int, _ scope: String) -> ScopeSpan {
        ScopeSpan(start: start, end: end, scopes: ScopeStack([scope]))
    }

    /// Squiggling a code file while the highlight sweep catches up would be noise.
    static func testNilSpans() {
        expectTrue(SpellCheckScopes.checkableRanges(spans: nil, lineLength: 20,
                                                    baseScope: "source.swift").isEmpty)
        expectTrue(SpellCheckScopes.checkableRanges(spans: nil, lineLength: 20).isEmpty,
                   "and with no scope at all")
    }

    /// Without this, spell check does nothing on a plain-text file that never produces
    /// spans — which is the main thing anyone turns it on for.
    static func testNilSpansPlainText() {
        expectEqual(SpellCheckScopes.checkableRanges(spans: nil, lineLength: 20,
                                                     baseScope: "text.plain"), [0 ..< 20])
    }

    static func testEmptySpans() {
        expectEqual(SpellCheckScopes.checkableRanges(spans: [], lineLength: 20), [0 ..< 20],
                    "a plain-text document is all prose")
    }

    static func testComments() {
        let spans = [span(0, 4, "source.swift"), span(4, 20, "comment.line.double-slash.swift")]
        expectEqual(SpellCheckScopes.checkableRanges(spans: spans, lineLength: 20), [4 ..< 20])
    }

    static func testStrings() {
        let spans = [span(0, 8, "source.swift"), span(8, 18, "string.quoted.double.swift")]
        expectEqual(SpellCheckScopes.checkableRanges(spans: spans, lineLength: 18), [8 ..< 18])
    }

    /// The point of the feature: every identifier and keyword would otherwise be a
    /// "misspelling" and the squiggles become noise.
    static func testSkipsCode() {
        let spans = [span(0, 10, "keyword.control.swift"),
                     span(10, 20, "variable.other.swift")]
        expectTrue(SpellCheckScopes.checkableRanges(spans: spans, lineLength: 20).isEmpty)
    }

    /// A comment is often several spans (punctuation, then content); a word straddling the
    /// boundary would be reported misspelled if they weren't merged.
    static func testMergesAdjacent() {
        let spans = [span(0, 2, "comment.line.swift"),
                     span(2, 15, "comment.line.swift")]
        expectEqual(SpellCheckScopes.checkableRanges(spans: spans, lineLength: 15), [0 ..< 15])
    }

    static func testClampsSpans() {
        let spans = [span(0, 999, "comment.line.swift")]
        expectEqual(SpellCheckScopes.checkableRanges(spans: spans, lineLength: 10), [0 ..< 10])
    }

    static func testEmptyLine() {
        expectTrue(SpellCheckScopes.checkableRanges(spans: [], lineLength: 0).isEmpty)
    }

    static func testCustomSelectors() {
        let spans = [span(0, 10, "comment.line.swift")]
        expectTrue(SpellCheckScopes.checkableRanges(spans: spans, lineLength: 10,
                                                    selectors: ["string"]).isEmpty)
        expectEqual(SpellCheckScopes.checkableRanges(spans: spans, lineLength: 10,
                                                    selectors: ["comment"]), [0 ..< 10])
    }
}
