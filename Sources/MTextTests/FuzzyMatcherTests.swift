import Foundation
import MTextCore
import MTextTestKit

enum FuzzyMatcherTests {

    static let suite = TestSuite("FuzzyMatcher", [
        ("non-subsequence does not match", testNonSubsequenceFails),
        ("empty query matches everything with score 0", testEmptyQueryMatchesAll),
        ("subsequence match records correct indices", testIndices),
        ("word-boundary match scores higher than mid-word", testBoundaryBonus),
        ("camelCase boundary scores higher than a mid-word letter", testCamelCaseBonus),
        ("consecutive run scores higher than a scattered match", testConsecutiveRunBonus),
        ("earlier start scores higher, all else equal", testLeadingPenalty),
        ("rank sorts descending by score and drops non-matches", testRank),
    ])

    static func testNonSubsequenceFails() {
        expectNil(FuzzyMatcher.match(query: "xyz", in: "main.swift"))
        expectNil(FuzzyMatcher.match(query: "swiftx", in: "main.swift"))
    }

    static func testEmptyQueryMatchesAll() {
        let match = FuzzyMatcher.match(query: "", in: "anything.txt")
        expectEqual(match?.score, 0)
        expectEqual(match?.indices ?? [-1], [])
    }

    static func testIndices() {
        // "mws" as a subsequence of "main.swift" → m(0) w(6) s(7)... actually 's' first
        // appears at index 6 ("swift" starts at 5: m-a-i-n-.-s-w-i-f-t), so trace it by
        // hand: m=0, then next 'w' at-or-after 1 is index 6 (s-w-i-f-t → w is index 6),
        // then next 's' at-or-after 7 doesn't exist (no more 's'), so use a query that
        // definitely exists in order instead.
        let match = FuzzyMatcher.match(query: "mst", in: "main.swift")
        expectEqual(match?.indices, [0, 5, 9])
    }

    static func testBoundaryBonus() {
        // "sw" matches "swift" starting right at a path boundary in "src/swift.txt"...
        // simpler: compare matching "sw" at the start of a segment after "_" versus
        // matching it mid-word.
        let boundary = FuzzyMatcher.match(query: "sw", in: "file_swift")
        let midWord = FuzzyMatcher.match(query: "sw", in: "filesswift")
        expectTrue((boundary?.score ?? 0) > (midWord?.score ?? 0),
                   "boundary \(String(describing: boundary?.score)) should beat mid-word \(String(describing: midWord?.score))")
    }

    static func testCamelCaseBonus() {
        let camel = FuzzyMatcher.match(query: "gc", in: "getCount")
        let flat = FuzzyMatcher.match(query: "gc", in: "gxxxcount")
        expectTrue((camel?.score ?? 0) > (flat?.score ?? 0))
    }

    static func testConsecutiveRunBonus() {
        let consecutive = FuzzyMatcher.match(query: "abc", in: "xabcxxxxxx")
        let scattered = FuzzyMatcher.match(query: "abc", in: "xaxxbxxcxx")
        expectTrue((consecutive?.score ?? 0) > (scattered?.score ?? 0))
    }

    static func testLeadingPenalty() {
        let early = FuzzyMatcher.match(query: "ab", in: "ab_______")
        let late = FuzzyMatcher.match(query: "ab", in: "_______ab")
        expectTrue((early?.score ?? 0) > (late?.score ?? 0))
    }

    static func testRank() {
        let candidates = ["main.swift", "TextDocument.swift", "swiftlint.yml", "readme.md"]
        let ranked = FuzzyMatcher.rank(query: "swift", candidates: candidates)
        // "readme.md" has no "swift" subsequence at all and must be dropped.
        expectEqual(ranked.count, 3)
        expectFalse(ranked.contains { candidates[$0.index] == "readme.md" })
        // Every returned score should be non-increasing down the list.
        for i in 1 ..< ranked.count {
            expectTrue(ranked[i - 1].match.score >= ranked[i].match.score)
        }
    }
}
