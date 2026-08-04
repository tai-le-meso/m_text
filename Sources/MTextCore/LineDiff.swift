import Foundation

/// How one line of the current buffer differs from the version on disk (T102).
public enum DiffMark: Equatable {
    /// A line that isn't in the on-disk version at all.
    case added
    /// A line that exists on disk but with different text.
    case modified
    /// Nothing was added here, but one or more lines were **deleted just above** this one.
    /// Rendered as a wedge rather than a bar, since there is no line to highlight.
    case deletedAbove
}

/// A contiguous run of differing lines, in both coordinate spaces.
public struct DiffHunk: Equatable {
    /// Lines in the current buffer. Empty for a pure deletion.
    public let newRange: Range<Int>
    /// Lines in the on-disk version. Empty for a pure addition.
    public let oldRange: Range<Int>

    public init(newRange: Range<Int>, oldRange: Range<Int>) {
        self.newRange = newRange
        self.oldRange = oldRange
    }

    public var isAddition: Bool { oldRange.isEmpty && !newRange.isEmpty }
    public var isDeletion: Bool { newRange.isEmpty && !oldRange.isEmpty }
}

/// Line-based diff between the saved file and the buffer.
///
/// **Cost is the design constraint**, because this runs against the whole document whenever
/// the gutter is drawn. Common prefix and suffix are trimmed first, which reduces the usual
/// case — a few edits in a large file — to a handful of lines. Only what remains goes through
/// the quadratic LCS, and that is capped: past `maximumLCSLines` the middle is reported as one
/// modified hunk rather than spending O(n·m) on a diff nobody is reading line by line.
public enum LineDiff {

    /// Beyond this many differing lines on either side, the middle is collapsed. 2000² is
    /// already four million cells; the gutter gains nothing from resolving further.
    public static let maximumLCSLines = 2000

    public static func hunks(old: [String], new: [String]) -> [DiffHunk] {
        // Trim the identical head and tail. Almost all of a real edit session is identical.
        var start = 0
        while start < old.count, start < new.count, old[start] == new[start] { start += 1 }

        var oldEnd = old.count
        var newEnd = new.count
        while oldEnd > start, newEnd > start, old[oldEnd - 1] == new[newEnd - 1] {
            oldEnd -= 1
            newEnd -= 1
        }
        guard start < oldEnd || start < newEnd else { return [] }

        let oldMiddle = Array(old[start ..< oldEnd])
        let newMiddle = Array(new[start ..< newEnd])

        guard oldMiddle.count <= maximumLCSLines, newMiddle.count <= maximumLCSLines else {
            // Too big to diff usefully: report the whole differing middle as one hunk.
            return [DiffHunk(newRange: start ..< newEnd, oldRange: start ..< oldEnd)]
        }
        return hunksFromLCS(oldMiddle, newMiddle, offset: start)
    }

    /// Per-line marks for the gutter, keyed by buffer line.
    ///
    /// A hunk that both removes and adds lines marks its new lines `.modified` rather than
    /// `.added`; a pure deletion marks the line that now follows it `.deletedAbove`, since
    /// there is no line of its own to colour.
    public static func marks(old: [String], new: [String]) -> [Int: DiffMark] {
        var marks: [Int: DiffMark] = [:]
        for hunk in hunks(old: old, new: new) {
            if hunk.isDeletion {
                // Clamped: a deletion at the very end has no following line, so it attaches
                // to the last one instead of falling off the document.
                let line = min(hunk.newRange.lowerBound, max(0, new.count - 1))
                if marks[line] == nil { marks[line] = .deletedAbove }
                continue
            }
            let mark: DiffMark = hunk.oldRange.isEmpty ? .added : .modified
            for line in hunk.newRange { marks[line] = mark }
        }
        return marks
    }

    /// The hunk containing `line`, for Revert Hunk.
    public static func hunk(containing line: Int, old: [String], new: [String]) -> DiffHunk? {
        hunks(old: old, new: new).first { hunk in
            hunk.newRange.contains(line)
                // A pure deletion has an empty range, so "containing" means the line it sits
                // above — otherwise a deletion could never be reverted.
                || (hunk.isDeletion && hunk.newRange.lowerBound == line)
        }
    }

    // MARK: - LCS

    private static func hunksFromLCS(_ old: [String], _ new: [String], offset: Int) -> [DiffHunk] {
        let table = lcsTable(old, new)
        var hunks: [DiffHunk] = []

        var oldIndex = 0
        var newIndex = 0
        var pendingOld: Int?
        var pendingNew: Int?

        func flush(oldEnd: Int, newEnd: Int) {
            guard let po = pendingOld, let pn = pendingNew else { return }
            hunks.append(DiffHunk(newRange: (pn + offset) ..< (newEnd + offset),
                                  oldRange: (po + offset) ..< (oldEnd + offset)))
            pendingOld = nil
            pendingNew = nil
        }

        while oldIndex < old.count || newIndex < new.count {
            if oldIndex < old.count, newIndex < new.count, old[oldIndex] == new[newIndex] {
                flush(oldEnd: oldIndex, newEnd: newIndex)
                oldIndex += 1
                newIndex += 1
                continue
            }
            if pendingOld == nil { pendingOld = oldIndex; pendingNew = newIndex }
            // Follow the LCS table: take from whichever side the longer subsequence lies on.
            if newIndex < new.count, oldIndex == old.count || table[oldIndex][newIndex + 1] >= table[oldIndex + 1][newIndex] {
                newIndex += 1
            } else {
                oldIndex += 1
            }
        }
        flush(oldEnd: oldIndex, newEnd: newIndex)
        return hunks
    }

    private static func lcsTable(_ old: [String], _ new: [String]) -> [[Int]] {
        var table = Array(repeating: Array(repeating: 0, count: new.count + 1), count: old.count + 1)
        guard !old.isEmpty, !new.isEmpty else { return table }
        for i in stride(from: old.count - 1, through: 0, by: -1) {
            for j in stride(from: new.count - 1, through: 0, by: -1) {
                table[i][j] = old[i] == new[j]
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }
        return table
    }
}
