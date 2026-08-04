import Foundation
import MTextCore
import MTextTestKit

enum FindResultsTests {

    static let suite = TestSuite("FindResults", [
        ("writes a heading per file", testHeadings),
        ("does not repeat a heading for the same file", testGroupsByFile),
        ("maps a buffer line back to its match", testMapping),
        ("does not map heading or blank lines", testUnmappedLines),
        ("includes context lines without mapping them", testContextLines),
        ("appends live without re-rendering", testLiveAppend),
        ("summarises counts", testSummary),
        ("says when the sweep was truncated", testTruncatedSummary),
        ("says when the sweep was cancelled", testCancelledSummary),
    ])

    private static func match(_ path: String, line: Int, text: String,
                              before: [String] = [], after: [String] = []) -> FileMatch {
        FileMatch(url: URL(fileURLWithPath: path), line: line, column: 0,
                  length: 1, lineText: text, contextBefore: before, contextAfter: after)
    }

    static func testHeadings() {
        var buffer = FindResultsBuffer()
        buffer.append([match("/a.txt", line: 0, text: "one")])
        expectTrue(buffer.text.hasPrefix("/a.txt:\n"))
        expectEqual(buffer.fileCount, 1)
    }

    static func testGroupsByFile() {
        var buffer = FindResultsBuffer()
        buffer.append([match("/a.txt", line: 0, text: "one"),
                       match("/a.txt", line: 5, text: "two"),
                       match("/b.txt", line: 1, text: "three")])
        expectEqual(buffer.fileCount, 2)
        expectEqual(buffer.text.components(separatedBy: "/a.txt:").count - 1, 1,
                    "the heading appears once, not per match")
    }

    /// Every jump goes through this map — an off-by-one sends you to the wrong place in the
    /// wrong file.
    static func testMapping() {
        var buffer = FindResultsBuffer()
        buffer.append([match("/a.txt", line: 11, text: "hit")])
        // Line 0 is the heading; line 1 is the match.
        expectNil(buffer.match(atBufferLine: 0))
        expectEqual(buffer.match(atBufferLine: 1)?.line, 11)
        expectEqual(buffer.match(atBufferLine: 1)?.url.path, "/a.txt")
    }

    static func testUnmappedLines() {
        var buffer = FindResultsBuffer()
        buffer.append([match("/a.txt", line: 0, text: "one"),
                       match("/b.txt", line: 0, text: "two")])
        // heading, match, blank, heading, match
        expectNil(buffer.match(atBufferLine: 0))
        expectTrue(buffer.match(atBufferLine: 1) != nil)
        expectNil(buffer.match(atBufferLine: 2), "the blank separator")
        expectNil(buffer.match(atBufferLine: 3), "the second heading")
        expectTrue(buffer.match(atBufferLine: 4) != nil)
    }

    /// Context is shown but not jumpable: activating a context line should do nothing rather
    /// than jump somewhere the user didn't point at.
    static func testContextLines() {
        var buffer = FindResultsBuffer()
        buffer.append([match("/a.txt", line: 5, text: "hit",
                             before: ["above"], after: ["below"])])
        expectTrue(buffer.text.contains("above"))
        expectTrue(buffer.text.contains("below"))
        expectNil(buffer.match(atBufferLine: 1), "the leading context line")
        expectEqual(buffer.match(atBufferLine: 2)?.line, 5, "the match itself")
        expectNil(buffer.match(atBufferLine: 3), "the trailing context line")
    }

    /// The search streams batches; re-rendering everything per batch would make a long
    /// sweep quadratic.
    static func testLiveAppend() {
        var buffer = FindResultsBuffer()
        buffer.append([match("/a.txt", line: 0, text: "one")])
        let afterFirst = buffer.text
        buffer.append([match("/a.txt", line: 3, text: "two")])
        expectTrue(buffer.text.hasPrefix(afterFirst), "earlier output is untouched")
        expectEqual(buffer.matchCount, 2)
        expectEqual(buffer.fileCount, 1, "same file, still one heading")
    }

    static func testSummary() {
        var buffer = FindResultsBuffer()
        buffer.append([match("/a.txt", line: 0, text: "one"),
                       match("/b.txt", line: 0, text: "two")])
        buffer.appendSummary(FindInFilesSummary())
        expectTrue(buffer.text.contains("2 matches in 2 files"))
    }

    /// A truncated sweep must say so rather than implying the tree was fully searched.
    static func testTruncatedSummary() {
        var buffer = FindResultsBuffer()
        buffer.append([match("/a.txt", line: 0, text: "one")])
        var summary = FindInFilesSummary()
        summary.hitMatchLimit = true
        summary.filesSkipped = 3
        buffer.appendSummary(summary)
        expectTrue(buffer.text.contains("stopped at the result limit"))
        expectTrue(buffer.text.contains("3 skipped"))
    }

    static func testCancelledSummary() {
        var buffer = FindResultsBuffer()
        var summary = FindInFilesSummary()
        summary.wasCancelled = true
        buffer.appendSummary(summary)
        expectTrue(buffer.text.contains("cancelled"))
    }
}
