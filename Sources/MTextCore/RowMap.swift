import Foundation

/// The single source of truth for "which screen row is this, and which document line does
/// it belong to" (T28, building on T92).
///
/// Folding *removes* rows; word wrap *adds* them. Before wrap, `FoldSet` alone could answer
/// both directions with arithmetic. Once one line can occupy several rows the mapping stops
/// being closed-form and needs a cumulative index, which is what this holds.
///
/// **Rebuild cost is the whole design constraint.** The row count of every line changes when
/// the wrap width or the font changes, so the index is rebuilt wholesale then; an *edit*
/// only changes the lines it touched, so `updateLines` patches those and shifts the running
/// total for the rest. Both are O(lines), which measures in well under a millisecond even
/// for a 200k-line file — see `PerformanceTests`.
public struct RowMap: Equatable {

    /// Rows each document line occupies. 1 for every line when wrapping is off.
    private var rowsPerLine: [Int] = []
    /// `starts[i]` = the screen row line `i` begins at, **with folds already applied**.
    /// A hidden line carries its fold's start row, so a caret inside collapsed text still
    /// resolves somewhere real.
    ///
    /// Precomputed rather than derived per query: `location(ofRow:)` binary-searches this,
    /// and deriving each probe by summing the hidden lines above it would make hit testing
    /// O(hidden lines · log n) — pathological with one large region collapsed.
    private var starts: [Int] = []
    private var rowTotal = 1

    public private(set) var folds = FoldSet()
    /// Columns available per row; 0 disables wrapping entirely.
    public private(set) var wrapWidth = 0

    public init() {}

    public var isWrapping: Bool { wrapWidth > 0 }
    public var lineCount: Int { rowsPerLine.count }

    // MARK: - Building

    /// Recomputes every line's row count. Call when the wrap width, tab size, font or
    /// document identity changes.
    public mutating func rebuild(lineProvider: (Int) -> String, lineCount: Int,
                                 wrapWidth: Int, tabSize: Int) {
        self.wrapWidth = wrapWidth
        rowsPerLine = Array(repeating: 1, count: max(0, lineCount))
        if wrapWidth > 0 {
            for line in 0 ..< max(0, lineCount) {
                rowsPerLine[line] = WordWrapper.rowCount(for: lineProvider(line),
                                                         width: wrapWidth, tabSize: tabSize)
            }
        }
        rebuildStarts()
    }

    /// Patches the rows of `lines` after an edit, then shifts everything after them.
    ///
    /// Takes the *new* line count so an edit that added or removed lines resizes the index
    /// in the same pass — recomputing only the touched lines is the point, and a stale
    /// length would silently misalign every row after the edit.
    public mutating func updateLines(_ lines: Range<Int>, lineProvider: (Int) -> String,
                                     newLineCount: Int, tabSize: Int) {
        if rowsPerLine.count != newLineCount {
            rowsPerLine = resized(rowsPerLine, to: newLineCount, fill: 1)
        }
        let clamped = max(0, lines.lowerBound) ..< min(newLineCount, lines.upperBound)
        for line in clamped {
            rowsPerLine[line] = wrapWidth > 0
                ? WordWrapper.rowCount(for: lineProvider(line), width: wrapWidth, tabSize: tabSize)
                : 1
        }
        rebuildStarts()
    }

    public mutating func setFolds(_ folds: FoldSet) {
        self.folds = folds
        rebuildStarts()
    }

    /// One pass computing every line's screen row, skipping folded blocks.
    private mutating func rebuildStarts() {
        starts = Array(repeating: 0, count: rowsPerLine.count)
        var row = 0
        var line = 0
        while line < rowsPerLine.count {
            starts[line] = row
            if let region = folds.regions.first(where: { $0.startLine == line }) {
                // The start line is visible and occupies its rows; everything it hides
                // collapses onto that same row.
                row += rowsPerLine[line]
                let hiddenEnd = min(region.endLine, rowsPerLine.count - 1)
                if hiddenEnd >= line + 1 {
                    for hidden in (line + 1) ... hiddenEnd { starts[hidden] = starts[line] }
                }
                line = hiddenEnd + 1
                continue
            }
            row += rowsPerLine[line]
            line += 1
        }
        rowTotal = max(1, row)
    }

    private func resized(_ array: [Int], to count: Int, fill: Int) -> [Int] {
        if array.count == count { return array }
        if array.count > count { return Array(array.prefix(count)) }
        return array + Array(repeating: fill, count: count - array.count)
    }

    // MARK: - Queries

    public func rows(forLine line: Int) -> Int {
        guard rowsPerLine.indices.contains(line) else { return 1 }
        return folds.isHidden(line: line) ? 0 : rowsPerLine[line]
    }

    /// Total rows on screen, with folds removed and wraps counted.
    public var totalRows: Int { rowsPerLine.isEmpty ? 1 : rowTotal }

    /// First screen row of a document line. O(1).
    public func firstRow(ofLine line: Int) -> Int {
        guard starts.indices.contains(line) else { return starts.last ?? 0 }
        return starts[line]
    }

    /// Screen row of an exact caret position — the line's first row plus which wrapped row
    /// the column falls on.
    public func row(at position: Position, lineProvider: (Int) -> String, tabSize: Int) -> Int {
        let base = firstRow(ofLine: position.line)
        guard wrapWidth > 0, !folds.isHidden(line: position.line) else { return base }
        let breaks = WordWrapper.breaks(for: lineProvider(position.line),
                                        width: wrapWidth, tabSize: tabSize)
        return base + WordWrapper.row(forColumn: position.column, breaks: breaks)
    }

    /// The document line a screen row belongs to, and which of that line's wrapped rows it
    /// is. Binary search over the cumulative index rather than a scan, so hit testing near
    /// the bottom of a large file costs the same as near the top.
    public func location(ofRow row: Int) -> (line: Int, rowInLine: Int) {
        guard !rowsPerLine.isEmpty else { return (0, 0) }
        var low = 0
        var high = rowsPerLine.count - 1
        var result = high
        while low <= high {
            let mid = (low + high) / 2
            if firstRow(ofLine: mid) <= row {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        // Land on the fold's start line rather than inside collapsed text.
        if let region = folds.regions.first(where: { $0.hiddenLines.contains(result) }) {
            result = region.startLine
        }
        return (result, max(0, row - firstRow(ofLine: result)))
    }
}
