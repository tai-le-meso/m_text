import Foundation
import MTextCore
import MTextTestKit

enum ReplaceInFilesTests {

    static let suite = TestSuite("ReplaceInFiles", [
        ("plans a replacement without writing anything", testPlanDoesNotWrite),
        ("counts replacements across files", testCounts),
        ("previews each changed line before and after", testPreview),
        ("plans nothing for a file with no matches", testNoMatches),
        ("replaces every occurrence on a line", testMultiplePerLine),
        ("expands $1 capture groups", testCaptureGroups),
        ("preserves CRLF line endings", testPreservesCRLF),
        ("skips binaries and oversized files", testSkipsUnreadable),

        ("applies a plan and writes the files", testApply),
        ("refuses a file that changed after planning", testStaleFileRefused),
        ("still writes the untouched files when one is stale", testPartialStale),
        ("reports a file it cannot write", testReportsFailure),
    ])

    private static func withTree(_ files: [String: String], _ body: (URL) -> Void) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mtext-rif-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, contents) in files {
            try? Data(contents.utf8).write(to: root.appendingPathComponent(name))
        }
        body(root)
    }

    private static func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // MARK: - Planning

    /// The whole safety model rests on planning being read-only.
    static func testPlanDoesNotWrite() {
        withTree(["a.txt": "old value"]) { root in
            let url = root.appendingPathComponent("a.txt")
            _ = ReplaceInFiles.plan(files: [url], query: .literal("old"), template: "new")
            expectEqual(read(url), "old value", "planning must not touch the file")
        }
    }

    static func testCounts() {
        withTree(["a.txt": "x x", "b.txt": "x", "c.txt": "none"]) { root in
            let urls = ["a.txt", "b.txt", "c.txt"].map { root.appendingPathComponent($0) }
            let plan = ReplaceInFiles.plan(files: urls, query: .literal("x"), template: "y")
            expectEqual(plan.fileCount, 2, "the file with no matches is not in the plan")
            expectEqual(plan.replacementCount, 3)
        }
    }

    static func testPreview() {
        withTree(["a.txt": "keep\nold value\nkeep"]) { root in
            let plan = ReplaceInFiles.plan(files: [root.appendingPathComponent("a.txt")],
                                           query: .literal("old"), template: "new")
            let previews = plan.changes.first?.previews ?? []
            expectEqual(previews.count, 1, "only the changed line is previewed")
            expectEqual(previews.first?.line, 1)
            expectEqual(previews.first?.before, "old value")
            expectEqual(previews.first?.after, "new value")
        }
    }

    static func testNoMatches() {
        withTree(["a.txt": "nothing"]) { root in
            let plan = ReplaceInFiles.plan(files: [root.appendingPathComponent("a.txt")],
                                           query: .literal("zzz"), template: "y")
            expectTrue(plan.isEmpty)
        }
    }

    /// Back-to-front application: replacing left to right would shift the columns of every
    /// later match on the line.
    static func testMultiplePerLine() {
        withTree(["a.txt": "aa bb aa bb aa"]) { root in
            let url = root.appendingPathComponent("a.txt")
            let plan = ReplaceInFiles.plan(files: [url], query: .literal("aa"), template: "LONGER")
            expectEqual(plan.replacementCount, 3)
            expectEqual(plan.changes.first?.newText, "LONGER bb LONGER bb LONGER")
        }
    }

    static func testCaptureGroups() {
        withTree(["a.txt": "id=17"]) { root in
            var query = SearchQuery(pattern: "id=([0-9]+)")
            query.isRegex = true
            let plan = ReplaceInFiles.plan(files: [root.appendingPathComponent("a.txt")],
                                           query: query, template: "number($1)")
            expectEqual(plan.changes.first?.newText, "number(17)")
        }
    }

    /// A replace must not silently convert a Windows file's line endings.
    static func testPreservesCRLF() {
        withTree(["a.txt": "old\r\nkeep\r\n"]) { root in
            let url = root.appendingPathComponent("a.txt")
            let plan = ReplaceInFiles.plan(files: [url], query: .literal("old"), template: "new")
            expectEqual(plan.changes.first?.lineEnding, .crlf)
            expectTrue(plan.changes.first?.newText.contains("\r\n") == true)
            expectFalse(plan.changes.first?.newText.contains("new\nkeep") == true)
        }
    }

    static func testSkipsUnreadable() {
        withTree([:]) { root in
            let binary = root.appendingPathComponent("b.bin")
            var bytes = Data("old".utf8)
            bytes.append(0)
            try? bytes.write(to: binary)
            let plan = ReplaceInFiles.plan(files: [binary], query: .literal("old"), template: "new")
            expectTrue(plan.isEmpty)
            expectEqual(plan.unreadable.count, 1)
        }
    }

    // MARK: - Applying

    static func testApply() {
        withTree(["a.txt": "old", "b.txt": "old old"]) { root in
            let urls = ["a.txt", "b.txt"].map { root.appendingPathComponent($0) }
            let plan = ReplaceInFiles.plan(files: urls, query: .literal("old"), template: "new")
            let result = ReplaceInFiles.apply(plan)
            expectEqual(result.written.count, 2)
            expectTrue(result.stale.isEmpty)
            expectEqual(read(urls[0]), "new")
            expectEqual(read(urls[1]), "new new")
        }
    }

    /// The core safety property: a file that changed between planning and applying must be
    /// skipped, not overwritten with a replacement computed against different text.
    static func testStaleFileRefused() {
        withTree(["a.txt": "old"]) { root in
            let url = root.appendingPathComponent("a.txt")
            let plan = ReplaceInFiles.plan(files: [url], query: .literal("old"), template: "new")
            try? Data("someone else edited this".utf8).write(to: url)

            let result = ReplaceInFiles.apply(plan)
            expectTrue(result.written.isEmpty)
            expectEqual(result.stale.count, 1)
            expectEqual(read(url), "someone else edited this", "the other edit survives")
        }
    }

    static func testPartialStale() {
        withTree(["a.txt": "old", "b.txt": "old"]) { root in
            let urls = ["a.txt", "b.txt"].map { root.appendingPathComponent($0) }
            let plan = ReplaceInFiles.plan(files: urls, query: .literal("old"), template: "new")
            try? Data("changed".utf8).write(to: urls[0])

            let result = ReplaceInFiles.apply(plan)
            expectEqual(result.stale.count, 1)
            expectEqual(result.written.count, 1, "one bad file doesn't abandon the rest")
            expectEqual(read(urls[1]), "new")
        }
    }

    static func testReportsFailure() {
        withTree(["a.txt": "old"]) { root in
            let url = root.appendingPathComponent("a.txt")
            let plan = ReplaceInFiles.plan(files: [url], query: .literal("old"), template: "new")
            try? FileManager.default.removeItem(at: url)

            let result = ReplaceInFiles.apply(plan)
            expectTrue(result.written.isEmpty)
            expectEqual(result.failed.count, 1, "a vanished file is reported, not silently skipped")
        }
    }
}
