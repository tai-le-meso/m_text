import Foundation

/// A foldable block: `startLine` stays on screen, `startLine + 1 ... endLine` collapse.
///
/// Indent-based rather than syntax-based, matching Sublime's default. It costs nothing per
/// language — every one of the 48 grammars folds correctly on day one — and it degrades
/// sensibly on languages the grammars don't model well. Brace-aware folding would be more
/// precise for C-family code and is a plausible later refinement; the region model here
/// wouldn't change.
public struct FoldRegion: Equatable {
    public let startLine: Int
    public let endLine: Int

    public init(startLine: Int, endLine: Int) {
        self.startLine = startLine
        self.endLine = endLine
    }

    /// The lines that disappear. Never empty: a region is only built when `endLine > startLine`.
    public var hiddenLines: ClosedRange<Int> { (startLine + 1) ... endLine }
    public var hiddenCount: Int { endLine - startLine }
}

/// Finds indent-based fold regions.
public enum FoldFinder {

    /// Visual indent width, expanding tabs. nil for a blank or whitespace-only line, which
    /// is what lets a blank line sit *inside* a fold without ending it — otherwise every
    /// paragraph break would chop a function into pieces.
    public static func indentWidth(_ line: String, tabSize: Int) -> Int? {
        var width = 0
        for character in line {
            if character == "\t" {
                width += tabSize - (width % tabSize)
            } else if character == " " {
                width += 1
            } else {
                return width
            }
        }
        return nil
    }

    /// The region starting at `line`, or nil when the following line isn't more indented.
    ///
    /// Scans forward while lines are blank or more indented, then trims trailing blanks —
    /// so folding a function doesn't swallow the empty lines between it and the next one.
    public static func region(startingAt line: Int, in document: TextDocument, tabSize: Int) -> FoldRegion? {
        guard line >= 0, line < document.lineCount else { return nil }
        guard let baseIndent = indentWidth(document.line(line), tabSize: tabSize) else { return nil }

        var last = line
        var index = line + 1
        while index < document.lineCount {
            let text = document.line(index)
            guard let indent = indentWidth(text, tabSize: tabSize) else {
                index += 1          // blank: might be interior, so keep looking
                continue
            }
            if indent > baseIndent {
                last = index
                index += 1
            } else {
                break
            }
        }
        return last > line ? FoldRegion(startLine: line, endLine: last) : nil
    }

    /// Every foldable region in the document, outermost first.
    ///
    /// O(n·depth) rather than O(n²): each line's region is found by scanning forward, but
    /// only lines that actually start one are scanned from. Callers that just need the
    /// gutter arrows for what's on screen should use `region(startingAt:)` per visible line
    /// instead — this is for Fold All and fold-by-level.
    public static func allRegions(in document: TextDocument, tabSize: Int) -> [FoldRegion] {
        var regions: [FoldRegion] = []
        for line in 0 ..< document.lineCount {
            if let region = region(startingAt: line, in: document, tabSize: tabSize) {
                regions.append(region)
            }
        }
        return regions
    }

    /// Nesting depth of a region, counting how many regions enclose it. Used by
    /// "Fold Level N", where level 1 is the outermost.
    public static func level(of region: FoldRegion, among all: [FoldRegion]) -> Int {
        all.reduce(1) { depth, other in
            (other.startLine < region.startLine && other.endLine >= region.endLine) ? depth + 1 : depth
        }
    }
}

/// Which regions are currently collapsed, and the document-line ↔ visual-row mapping that
/// follows from it.
///
/// **This mapping is the whole point.** Once anything can be folded, a document line is no
/// longer the same thing as a row on screen, and every piece of geometry — drawing, hit
/// testing, vertical movement, scroll height — has to go through here. Word wrap (T28) is
/// deferred to land against this same abstraction, since it needs the identical split
/// between "line in the file" and "row on screen".
public struct FoldSet: Equatable {

    /// Sorted by `startLine`, never overlapping — `fold(_:)` enforces both.
    public private(set) var regions: [FoldRegion] = []

    public init(regions: [FoldRegion] = []) {
        self.regions = []
        for region in regions.sorted(by: { $0.startLine < $1.startLine }) { fold(region) }
    }

    public var isEmpty: Bool { regions.isEmpty }

    // MARK: - Mutation

    /// Collapses `region`. Ignored when it overlaps an existing fold *partially*; a region
    /// wholly inside a collapsed one is dropped because it's already invisible, and one
    /// that encloses existing folds absorbs them.
    public mutating func fold(_ region: FoldRegion) {
        guard region.endLine > region.startLine else { return }
        if regions.contains(where: { $0.startLine <= region.startLine && $0.endLine >= region.endLine }) {
            return
        }
        var kept: [FoldRegion] = []
        for existing in regions {
            let enclosed = region.startLine <= existing.startLine && region.endLine >= existing.endLine
            if enclosed { continue }
            let overlaps = existing.startLine <= region.endLine && region.startLine <= existing.endLine
            if overlaps { return }      // partial overlap: not a sane nesting, leave it alone
            kept.append(existing)
        }
        kept.append(region)
        regions = kept.sorted { $0.startLine < $1.startLine }
    }

    @discardableResult
    public mutating func unfold(startingAt line: Int) -> Bool {
        guard let index = regions.firstIndex(where: { $0.startLine == line }) else { return false }
        regions.remove(at: index)
        return true
    }

    public mutating func unfoldAll() { regions.removeAll() }

    /// Folds a line if it isn't folded, unfolds it if it is. Returns whether anything moved.
    @discardableResult
    public mutating func toggle(_ region: FoldRegion) -> Bool {
        if unfold(startingAt: region.startLine) { return true }
        let before = regions.count
        fold(region)
        return regions.count != before
    }

    // MARK: - Queries

    public func isFolded(startLine line: Int) -> Bool {
        regions.contains { $0.startLine == line }
    }

    public func isHidden(line: Int) -> Bool {
        regions.contains { $0.hiddenLines.contains(line) }
    }

    /// Total hidden lines — the difference between document height and screen height.
    public var hiddenLineCount: Int {
        regions.reduce(0) { $0 + $1.hiddenCount }
    }

    public func visibleLineCount(totalLines: Int) -> Int {
        max(1, totalLines - hiddenLineCount)
    }

    /// Screen row for a document line. A hidden line reports the row of the fold that hides
    /// it, so a caret left inside a collapsed region still resolves somewhere sensible
    /// rather than off the end of the document.
    public func visualRow(forLine line: Int) -> Int {
        var row = line
        for region in regions {
            if region.hiddenLines.contains(line) {
                return visualRow(forLine: region.startLine)
            }
            if region.endLine < line { row -= region.hiddenCount }
        }
        return row
    }

    /// Document line for a screen row — the inverse of `visualRow(forLine:)`.
    public func line(forVisualRow row: Int) -> Int {
        var line = row
        for region in regions where region.startLine < line {
            // Skipping the block pushes the line further down the document; re-check the
            // same region afterwards is unnecessary because regions are sorted and
            // non-overlapping.
            line += region.hiddenCount
        }
        return line
    }

    // MARK: - Editing

    /// Keeps folds attached to their text after lines are inserted or removed at
    /// `fromLine`.
    ///
    /// A fold *containing* the edit grows or shrinks; one entirely after it shifts. A fold
    /// whose start line was itself deleted is **dropped**, not resized: its text is gone, so
    /// there is nothing left to justify hiding the lines that followed it.
    public mutating func adjust(afterEditAt fromLine: Int, linesDelta: Int) {
        guard linesDelta != 0 else { return }
        var updated: [FoldRegion] = []
        for region in regions {
            if region.endLine < fromLine {
                updated.append(region)
            } else if region.startLine >= fromLine {
                let start = region.startLine + linesDelta
                let end = region.endLine + linesDelta
                if start < 0 || end <= start { continue }
                updated.append(FoldRegion(startLine: start, endLine: end))
            } else {
                let end = region.endLine + linesDelta
                if end <= region.startLine { continue }   // collapsed to nothing
                updated.append(FoldRegion(startLine: region.startLine, endLine: end))
            }
        }
        regions = updated.sorted { $0.startLine < $1.startLine }
    }
}
