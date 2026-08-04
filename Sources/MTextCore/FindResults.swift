import Foundation

/// Renders find-in-files matches into the text of a results buffer, and records which
/// buffer line maps back to which match (T64).
///
/// Pure and separate from the view, because the mapping is the part that must be right:
/// every jump goes through `match(atBufferLine:)`, and an off-by-one there sends you to the
/// wrong place in the wrong file. Formatting and mapping are produced in one pass so they
/// cannot disagree.
public struct FindResultsBuffer {

    public private(set) var text: String = ""
    /// Buffer line → the match it shows. Context and heading lines are absent, so activating
    /// one does nothing rather than jumping somewhere arbitrary.
    public private(set) var matchesByLine: [Int: FileMatch] = [:]
    public private(set) var fileCount = 0
    public private(set) var matchCount = 0

    public init() {}

    /// Appends a batch, grouping by file. Designed for **live append**: the search streams
    /// batches per file, and re-rendering everything on each one would make a long sweep
    /// quadratic. A file already written keeps its heading rather than repeating it.
    public mutating func append(_ matches: [FileMatch], contextLines: Int = 0) {
        for match in matches {
            if match.url != lastFile {
                if lastFile != nil { appendLine("") }
                appendLine("\(match.url.path):")
                lastFile = match.url
                fileCount += 1
            }
            // Context first, then the match line, then trailing context — the order they
            // appear in the file.
            for (offset, line) in match.contextBefore.enumerated() {
                let number = match.line - match.contextBefore.count + offset
                appendLine(Self.format(line: number, text: line, isMatch: false))
            }
            matchesByLine[lineCount] = match
            appendLine(Self.format(line: match.line, text: match.lineText, isMatch: true))
            for (offset, line) in match.contextAfter.enumerated() {
                appendLine(Self.format(line: match.line + 1 + offset, text: line, isMatch: false))
            }
            matchCount += 1
        }
    }

    /// Final summary line. Separate from `append` so it can be written once the sweep ends,
    /// after every batch — and so a truncated sweep can say so.
    public mutating func appendSummary(_ summary: FindInFilesSummary) {
        appendLine("")
        var text = "\(matchCount) match\(matchCount == 1 ? "" : "es") in \(fileCount) file\(fileCount == 1 ? "" : "s")"
        if summary.hitMatchLimit { text += " — stopped at the result limit" }
        if summary.wasCancelled { text += " — cancelled" }
        if summary.filesSkipped > 0 { text += " (\(summary.filesSkipped) skipped)" }
        appendLine(text)
    }

    public func match(atBufferLine line: Int) -> FileMatch? { matchesByLine[line] }

    // MARK: - Internals

    private var lastFile: URL?
    private var lineCount = 0

    private mutating func appendLine(_ line: String) {
        text += line + "\n"
        lineCount += 1
    }

    /// `   12: some code` — line numbers displayed 1-based, right-aligned to a fixed width
    /// so the code lines up in a monospaced buffer. A match line is marked so it reads
    /// differently from its context at a glance.
    private static func format(line: Int, text: String, isMatch: Bool) -> String {
        let number = String(line + 1)
        let padding = String(repeating: " ", count: max(0, 6 - number.count))
        return "\(padding)\(number)\(isMatch ? ": " : "  ")\(text)"
    }
}
