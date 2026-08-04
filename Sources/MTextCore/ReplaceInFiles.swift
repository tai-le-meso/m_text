import Foundation

/// Planning and applying a replace across many files (T65).
///
/// **Nothing here writes until `apply` is called with a plan the caller has confirmed.**
/// Replacing across a tree is the most destructive thing this app can do — it edits files
/// that are not open, that have no undo stack, and that the user may not have looked at —
/// so the flow is deliberately two-phase: build a plan, show it, and only then write.
///
/// The other half of that safety is **staleness**. A plan is built from the files as they
/// were read; between planning and applying, a file can change on disk (a build, a git
/// checkout, another editor). Each change records a checksum of the exact bytes it was
/// planned against, and `apply` refuses any file whose contents have moved since. Silently
/// writing a replacement computed against different text is precisely the failure that
/// makes a bulk edit unrecoverable.
public enum ReplaceInFiles {

    /// One file's worth of planned edits.
    public struct FileChange: Equatable {
        public let url: URL
        /// Lines that change, as `(lineNumber, before, after)` — the preview, and the only
        /// thing the UI needs to show what will happen.
        public let previews: [(line: Int, before: String, after: String)]
        public let replacementCount: Int
        /// The whole file after replacement, ready to write.
        public let newText: String
        /// Checksum of the bytes this was planned against.
        public let originalChecksum: UInt64
        /// Line ending the file used, so writing back doesn't convert the whole file.
        public let lineEnding: LineEnding

        public static func == (lhs: FileChange, rhs: FileChange) -> Bool {
            lhs.url == rhs.url && lhs.replacementCount == rhs.replacementCount
                && lhs.newText == rhs.newText
        }
    }

    public struct Plan {
        public var changes: [FileChange] = []
        /// Files that matched but could not be read or parsed.
        public var unreadable: [URL] = []

        public var fileCount: Int { changes.count }
        public var replacementCount: Int { changes.reduce(0) { $0 + $1.replacementCount } }
        public var isEmpty: Bool { changes.isEmpty }
    }

    public struct ApplyResult {
        public var written: [URL] = []
        /// Files skipped because they changed on disk after the plan was built.
        public var stale: [URL] = []
        /// Files that could not be written, with the reason.
        public var failed: [(url: URL, reason: String)] = []
    }

    // MARK: - Planning

    /// Builds a plan by re-reading each file and re-running the query against it.
    ///
    /// Re-runs the search rather than trusting the positions the results buffer holds: those
    /// were captured during the sweep and may already be stale, and re-matching means the
    /// plan describes the file as it is *now* rather than as it was.
    public static func plan(files: [URL], query: SearchQuery, template: String,
                            maximumFileSizeBytes: Int = 4 * 1024 * 1024) -> Plan {
        var plan = Plan()
        guard !query.isEmpty, let matcher = try? SearchMatcher(query) else { return plan }

        for url in Set(files).sorted(by: { $0.path < $1.path }) {
            guard let data = try? Data(contentsOf: url), data.count <= maximumFileSizeBytes,
                  !data.prefix(8000).contains(0),
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
            else {
                plan.unreadable.append(url)
                continue
            }

            // Reuses the loader's own detector rather than a second heuristic — a file must
            // round-trip through replace with the endings it arrived with.
            let lineEnding = TextEncodingDetector.detectLineEnding(text)
            // Split on \n after normalising, so a CRLF file is handled the same way and the
            // original ending is restored on write rather than silently converted.
            let normalised = text.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            var lines = normalised.components(separatedBy: "\n")
            var previews: [(line: Int, before: String, after: String)] = []
            var count = 0

            for (index, line) in lines.enumerated() {
                let matches = matcher.matches(inLine: index, text: line)
                guard !matches.isEmpty else { continue }
                var updated = line
                // Back to front, so an earlier replacement can't invalidate a later one's
                // columns — the same rule multi-cursor editing follows.
                for match in matches.reversed() {
                    let replacement = ReplacementTemplate.expand(template, match: match,
                                                                 preserveCase: query.preserveCase)
                    let start = updated.index(updated.startIndex, offsetBy: match.region.start.column)
                    let end = updated.index(updated.startIndex, offsetBy: min(updated.count, match.region.end.column))
                    updated.replaceSubrange(start ..< end, with: replacement)
                    count += 1
                }
                previews.append((line: index, before: line, after: updated))
                lines[index] = updated
            }

            guard count > 0 else { continue }
            plan.changes.append(FileChange(url: url,
                                           previews: previews,
                                           replacementCount: count,
                                           newText: lines.joined(separator: lineEnding.string),
                                           originalChecksum: checksum(data),
                                           lineEnding: lineEnding))
        }
        return plan
    }

    // MARK: - Applying

    /// Writes the plan. Every file is re-read and re-checksummed first; any that moved since
    /// planning is **skipped**, not overwritten, and reported back so the caller can say so.
    public static func apply(_ plan: Plan) -> ApplyResult {
        var result = ApplyResult()
        for change in plan.changes {
            guard let current = try? Data(contentsOf: change.url) else {
                result.failed.append((change.url, "could not re-read the file"))
                continue
            }
            guard checksum(current) == change.originalChecksum else {
                result.stale.append(change.url)
                continue
            }
            do {
                // Atomic, so a failure part-way through leaves the original intact rather
                // than a half-written file.
                try Data(change.newText.utf8).write(to: change.url, options: .atomic)
                result.written.append(change.url)
            } catch {
                result.failed.append((change.url, error.localizedDescription))
            }
        }
        return result
    }

    /// FNV-1a over the file's bytes. Not cryptographic — it only has to notice that a file
    /// changed between planning and applying, within one run of the app, which it does far
    /// more cheaply than keeping every original in memory.
    static func checksum(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}
