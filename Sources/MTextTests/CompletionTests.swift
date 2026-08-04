import Foundation
import MTextCore
import MTextTestKit

enum CompletionTests {

    static let suite = TestSuite("Completion", [
        ("reads the partial word before the caret", testPrefixBeforeCaret),
        ("does not swallow the rest of the word after the caret", testPrefixIgnoresSuffix),
        ("is empty at a non-word position", testPrefixAtNonWord),
        ("collects distinct identifier words from the buffer", testBufferWords),
        ("skips words shorter than the minimum", testBufferWordsSkipsShort),
        ("splits on punctuation and whitespace", testBufferWordsSplitting),
        ("ranks prefix matches ahead of scattered ones", testRankingFavoursPrefix),
        ("never offers exactly what was already typed", testExcludesTypedWord),
        ("matches sub-sequences, not just prefixes", testFuzzyMatch),
        ("prefers a symbol over an identical buffer word", testSymbolWinsOverBufferWord),
        ("keeps symbol detail through ranking", testSymbolDetailSurvivesRanking),
        ("returns nothing when nothing matches", testNoMatches),
        ("honours the result limit", testLimit),
        ("sorts alphabetically when there is no prefix", testEmptyPrefixSorts),
        ("caches buffer words until the document changes", testBufferWordIndexCaching),
    ])

    private static func document(_ text: String) -> TextDocument {
        let document = TextDocument()
        document.setText(text, url: nil, encoding: .utf8, lineEnding: .lf, modificationDate: nil)
        return document
    }

    // MARK: - Prefix

    static func testPrefixBeforeCaret() {
        let doc = document("let someValue = 1")
        let prefix = CompletionEngine.prefix(in: doc, before: Position(line: 0, column: 8))
        expectEqual(prefix, "some")
    }

    /// The caret mid-word means the tail belongs to that word already; treating it as part
    /// of the prefix would make a commit rewrite text to the right of the caret.
    static func testPrefixIgnoresSuffix() {
        let doc = document("someValue")
        expectEqual(CompletionEngine.prefix(in: doc, before: Position(line: 0, column: 4)), "some")
    }

    static func testPrefixAtNonWord() {
        let doc = document("foo(")
        expectEqual(CompletionEngine.prefix(in: doc, before: Position(line: 0, column: 4)), "")
    }

    // MARK: - Buffer words

    static func testBufferWords() {
        let words = Set(CompletionEngine.bufferWords(in: document("""
        alpha beta
        alpha gamma
        """)))
        expectEqual(words, ["alpha", "beta", "gamma"], "distinct, order irrelevant")
    }

    static func testBufferWordsSkipsShort() {
        let words = Set(CompletionEngine.bufferWords(in: document("if in a longEnough")))
        expectEqual(words, ["longEnough"], "under \(CompletionEngine.minimumWordLength) chars is not worth offering")
    }

    static func testBufferWordsSplitting() {
        let words = Set(CompletionEngine.bufferWords(in: document("foo.barBaz(qux_quux)")))
        expectEqual(words, ["foo", "barBaz", "qux_quux"], "underscores are word characters, dots and parens are not")
    }

    // MARK: - Ranking

    static func testRankingFavoursPrefix() {
        let items = CompletionEngine.complete(prefix: "con",
                                              bufferWords: ["reconcile", "console"],
                                              symbols: [])
        expectEqual(items.first?.text, "console", "a real prefix beats a match in the middle")
        expectEqual(items.count, 2)
    }

    /// Accepting a completion identical to the typed text would be a no-op, and it would
    /// push a genuinely useful candidate off the end of the list.
    static func testExcludesTypedWord() {
        let items = CompletionEngine.complete(prefix: "alpha",
                                              bufferWords: ["alpha", "alphabet"],
                                              symbols: [])
        expectEqual(items.map(\.text), ["alphabet"])
    }

    static func testFuzzyMatch() {
        let items = CompletionEngine.complete(prefix: "sfn",
                                              bufferWords: ["someFunctionName", "unrelated"],
                                              symbols: [])
        expectEqual(items.first?.text, "someFunctionName")
        expectFalse(items.first?.matchedIndices.isEmpty ?? true, "indices drive bolding in the popup")
    }

    static func testSymbolWinsOverBufferWord() {
        let symbol = CompletionItem(text: "Widget", kind: .symbol, detail: "W.swift:3")
        let items = CompletionEngine.complete(prefix: "Wid",
                                              bufferWords: ["Widget"],
                                              symbols: [symbol])
        expectEqual(items.count, 1, "the duplicate collapses")
        expectEqual(items.first?.kind, .symbol)
        expectEqual(items.first?.detail, "W.swift:3")
    }

    static func testSymbolDetailSurvivesRanking() {
        let items = CompletionEngine.complete(
            prefix: "Th",
            bufferWords: [],
            symbols: [CompletionItem(text: "Thing", kind: .symbol, detail: "a.swift:9")]
        )
        expectEqual(items.first?.detail, "a.swift:9")
    }

    static func testNoMatches() {
        let items = CompletionEngine.complete(prefix: "zzz",
                                              bufferWords: ["alpha", "beta"],
                                              symbols: [])
        expectTrue(items.isEmpty)
    }

    static func testLimit() {
        let words = (0 ..< 100).map { "candidate\($0)" }
        let items = CompletionEngine.complete(prefix: "can", bufferWords: words, symbols: [], limit: 5)
        expectEqual(items.count, 5)
    }

    /// ⌃Space at a non-word position has no query to rank by; hash order would make the
    /// list jump around between invocations.
    static func testEmptyPrefixSorts() {
        let items = CompletionEngine.complete(prefix: "",
                                              bufferWords: ["gamma", "alpha", "beta"],
                                              symbols: [])
        expectEqual(items.map(\.text), ["alpha", "beta", "gamma"])
    }

    // MARK: - Caching

    /// Autocomplete re-queries on every keystroke, so rescanning the whole buffer each time
    /// is how typing gets slow. The cache keys on `TextDocument.generation`.
    static func testBufferWordIndexCaching() {
        let doc = document("alpha beta")
        let index = BufferWordIndex()
        expectEqual(Set(index.words(in: doc)), ["alpha", "beta"])

        // Same generation: the cached list comes back even though we ask again.
        expectEqual(Set(index.words(in: doc)), ["alpha", "beta"])

        _ = doc.insert(" gamma", at: Position(line: 0, column: 10))
        expectEqual(Set(index.words(in: doc)), ["alpha", "beta", "gamma"],
                    "an edit bumps the generation and invalidates the cache")
    }
}
