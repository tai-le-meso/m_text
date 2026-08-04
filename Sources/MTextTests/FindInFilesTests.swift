import Foundation
import MTextCore
import MTextTestKit

enum FindInFilesTests {

    static let suite = TestSuite("FindInFiles", [
        ("finds a literal match and reports its position", testLiteralMatch),
        ("finds every match on a line", testMultiplePerLine),
        ("searches across several files", testAcrossFiles),
        ("honours case sensitivity", testCaseSensitivity),
        ("honours whole-word", testWholeWord),
        ("supports regex patterns", testRegex),
        ("returns nothing for an empty query", testEmptyQuery),
        ("returns nothing with no roots", testNoRoots),

        ("skips a binary file", testSkipsBinary),
        ("skips a file over the size limit", testSkipsOversized),
        ("reads a non-UTF-8 file rather than skipping it", testLatin1Fallback),
        ("honours excluded directory names", testExcludes),

        ("stops at the match limit and says so", testMatchLimit),
        ("counts files searched and skipped", testSummaryCounts),
    ])

    // MARK: - Fixtures

    /// Real temp directories, matching `FileIndexTests`. `resolvingSymlinksInPath()` because
    /// `/var` is a symlink to `/private/var` on macOS — see KNOWLEDGE.md.
    private static func withTree(_ files: [String: String], _ body: (URL) -> Void) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mtext-fif-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        // Created unconditionally: a caller passing no files still needs the root to exist
        // so it can write its own fixture into it.
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? Data(contents.utf8).write(to: url)
        }
        body(root)
    }

    private static func search(_ query: SearchQuery, in root: URL,
                               configure: (inout FindInFilesRequest) -> Void = { _ in })
        -> (matches: [FileMatch], summary: FindInFilesSummary) {
        var request = FindInFilesRequest(query: query, roots: [root])
        configure(&request)
        return FindInFilesSearch().runSynchronously(request)
    }

    // MARK: - Matching

    static func testLiteralMatch() {
        withTree(["a.txt": "alpha\nbeta needle gamma\n"]) { root in
            let found = search(.literal("needle"), in: root).matches
            expectEqual(found.count, 1)
            expectEqual(found.first?.line, 1, "0-based, like Position")
            expectEqual(found.first?.column, 5)
            expectEqual(found.first?.length, 6)
            expectEqual(found.first?.lineText, "beta needle gamma")
        }
    }

    static func testMultiplePerLine() {
        withTree(["a.txt": "xx yy xx yy xx"]) { root in
            expectEqual(search(.literal("xx"), in: root).matches.count, 3)
        }
    }

    static func testAcrossFiles() {
        withTree(["a.txt": "needle", "sub/b.txt": "needle\nneedle"]) { root in
            let found = search(.literal("needle"), in: root).matches
            expectEqual(found.count, 3)
            expectEqual(Set(found.map { $0.url.lastPathComponent }), ["a.txt", "b.txt"])
        }
    }

    static func testCaseSensitivity() {
        withTree(["a.txt": "Needle needle"]) { root in
            expectEqual(search(.literal("needle", caseSensitive: true), in: root).matches.count, 1)
            expectEqual(search(.literal("needle", caseSensitive: false), in: root).matches.count, 2)
        }
    }

    static func testWholeWord() {
        withTree(["a.txt": "cat concatenate cat"]) { root in
            var query = SearchQuery(pattern: "cat")
            query.wholeWord = true
            query.isRegex = true   // whole-word is expressed as \b boundaries
            expectEqual(search(query, in: root).matches.count, 2, "not the one inside 'concatenate'")
        }
    }

    static func testRegex() {
        withTree(["a.txt": "id=17\nid=abc\nid=42"]) { root in
            var query = SearchQuery(pattern: "id=[0-9]+")
            query.isRegex = true
            expectEqual(search(query, in: root).matches.count, 2)
        }
    }

    static func testEmptyQuery() {
        withTree(["a.txt": "anything"]) { root in
            expectTrue(search(.literal(""), in: root).matches.isEmpty)
        }
    }

    static func testNoRoots() {
        let result = FindInFilesSearch().runSynchronously(
            FindInFilesRequest(query: .literal("x"), roots: []))
        expectTrue(result.matches.isEmpty)
    }

    // MARK: - Skipping

    /// A NUL byte is the binary test: extension lists miss unknown formats and wrongly
    /// exclude text files with odd names.
    static func testSkipsBinary() {
        withTree(["a.txt": "needle"]) { root in
            let binary = root.appendingPathComponent("b.bin")
            var bytes = Data("needle".utf8)
            bytes.append(0)
            bytes.append(contentsOf: Data("needle".utf8))
            try? bytes.write(to: binary)

            let result = search(.literal("needle"), in: root)
            expectEqual(result.matches.count, 1, "only the text file")
            expectEqual(result.summary.filesSkipped, 1)
        }
    }

    static func testSkipsOversized() {
        withTree(["big.txt": String(repeating: "needle\n", count: 100)]) { root in
            let result = search(.literal("needle"), in: root) { $0.maximumFileSizeBytes = 10 }
            expectTrue(result.matches.isEmpty)
            expectEqual(result.summary.filesSkipped, 1)
        }
    }

    /// A file that isn't valid UTF-8 is still searchable, the same fallback `TextEncoding`
    /// uses on load — skipping it would silently hide results.
    static func testLatin1Fallback() {
        withTree([:]) { root in
            let url = root.appendingPathComponent("latin.txt")
            var bytes = Data("caf".utf8)
            bytes.append(0xE9)                       // é in Latin-1, invalid UTF-8
            bytes.append(contentsOf: Data(" needle".utf8))
            try? bytes.write(to: url)

            let result = search(.literal("needle"), in: root)
            expectEqual(result.matches.count, 1)
            expectEqual(result.summary.filesSkipped, 0)
        }
    }

    static func testExcludes() {
        withTree(["a.txt": "needle", "node_modules/b.txt": "needle"]) { root in
            let found = search(.literal("needle"), in: root).matches
            expectEqual(found.count, 1, "node_modules is excluded by default")
            expectEqual(found.first?.url.lastPathComponent, "a.txt")
        }
    }

    // MARK: - Limits

    /// A pattern like `e` across a large tree must not fill memory before anyone sees a
    /// result — and the caller has to be able to say *why* results stopped.
    static func testMatchLimit() {
        withTree(["a.txt": String(repeating: "needle\n", count: 50)]) { root in
            let result = search(.literal("needle"), in: root) { $0.maximumMatches = 10 }
            expectEqual(result.matches.count, 10)
            expectTrue(result.summary.hitMatchLimit)
            expectFalse(result.summary.wasCancelled)
        }
    }

    static func testSummaryCounts() {
        withTree(["a.txt": "needle", "b.txt": "nothing here"]) { root in
            let result = search(.literal("needle"), in: root)
            expectEqual(result.summary.filesSearched, 2, "both were read")
            expectEqual(result.summary.matchCount, 1)
            expectFalse(result.summary.hitMatchLimit)
        }
    }
}
