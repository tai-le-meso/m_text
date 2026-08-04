import Foundation

/// One region's edit: delete `range`, then insert `text` at its start.
public struct RegionEdit {
    public var range: Region
    public var text: String

    public init(range: Region, text: String) {
        self.range = range
        self.text = text
    }

    public init(caretAt position: Position, text: String) {
        self.range = Region(caret: position)
        self.text = text
    }
}

/// Multi-region editing.
///
/// Two rules make multi-cursor tractable:
///
/// 1. Apply edits **back to front**. Regions are sorted ascending and disjoint, so
///    editing the last one first leaves every earlier region's coordinates valid.
/// 2. Track results as **byte offsets and rebase them**. A result captured while
///    editing region *i* is still shifted by the later (lower-offset) edits, so each
///    edit adds its length delta to every result after it. Skipping this is what makes
///    naive implementations leave the second caret behind the text it belongs to.
///
/// The whole sweep runs in one undo transaction, so ⌘Z reverses all carets at once.
public extension TextDocument {

    /// Applies one edit per region and returns the byte range each inserted text
    /// occupies in the finished document.
    func applyEdits(_ edits: [RegionEdit]) -> [(start: Int, end: Int)] {
        guard !edits.isEmpty else { return [] }
        undoStack.beginTransaction()
        defer { undoStack.endTransaction() }

        var ranges = [(start: Int, end: Int)](repeating: (0, 0), count: edits.count)

        for i in stride(from: edits.count - 1, through: 0, by: -1) {
            let edit = edits[i]
            let startOffset = byteOffset(of: clamp(edit.range.start))
            let endOffset = byteOffset(of: clamp(edit.range.end))
            let removedBytes = max(0, endOffset - startOffset)

            var caret = clamp(edit.range.start)
            if removedBytes > 0 {
                caret = delete(from: edit.range.start, to: edit.range.end)
            }
            let base = byteOffset(of: caret)
            let insertedBytes = edit.text.utf8.count
            if insertedBytes > 0 {
                _ = insert(edit.text, at: caret)
            }
            ranges[i] = (base, base + insertedBytes)

            // Rebase every result that sits after this edit.
            let delta = insertedBytes - removedBytes
            if delta != 0, i + 1 < ranges.count {
                for j in (i + 1) ..< ranges.count {
                    ranges[j].start += delta
                    ranges[j].end += delta
                }
            }
        }
        return ranges
    }

    /// Carets placed after each inserted text.
    private func carets(from ranges: [(start: Int, end: Int)], primaryIndex: Int) -> Selection {
        guard !ranges.isEmpty else { return Selection(caret: .zero) }
        return Selection(regions: ranges.map { Region(caret: position(ofByteOffset: $0.end)) },
                         primaryIndex: primaryIndex)
    }

    /// Selections covering each inserted text.
    func selections(from ranges: [(start: Int, end: Int)], primaryIndex: Int) -> Selection {
        guard !ranges.isEmpty else { return Selection(caret: .zero) }
        return Selection(regions: ranges.map {
            Region(anchor: position(ofByteOffset: $0.start), head: position(ofByteOffset: $0.end))
        }, primaryIndex: primaryIndex)
    }

    // MARK: - Replacing

    /// Replaces each region with the corresponding string. `replacements` must have
    /// one entry per region.
    @discardableResult
    func replace(_ selection: Selection, with replacements: [String]) -> Selection {
        guard replacements.count == selection.count else {
            return replace(selection, withEach: replacements.first ?? "")
        }
        let edits = zip(selection.regions, replacements).map { RegionEdit(range: $0, text: $1) }
        return carets(from: applyEdits(edits), primaryIndex: selection.primaryIndex)
    }

    /// Replaces every region with the same string.
    @discardableResult
    func replace(_ selection: Selection, withEach text: String) -> Selection {
        replace(selection, with: Array(repeating: text, count: selection.count))
    }

    /// Insert / typing. Non-empty regions are overwritten.
    @discardableResult
    func insert(_ text: String, over selection: Selection) -> Selection {
        replace(selection, withEach: text)
    }

    /// Like `replace`, but leaves the new text selected — used by case transforms.
    @discardableResult
    func replaceKeepingSelection(_ selection: Selection, with replacements: [String]) -> Selection {
        guard replacements.count == selection.count else { return selection }
        let edits = zip(selection.regions, replacements).map { RegionEdit(range: $0, text: $1) }
        return selections(from: applyEdits(edits), primaryIndex: selection.primaryIndex)
    }

    // MARK: - Deleting

    /// Backspace. Empty regions delete the grapheme before them; non-empty regions
    /// delete their contents.
    @discardableResult
    func deleteBackward(over selection: Selection) -> Selection {
        let edits = selection.regions.map { region -> RegionEdit in
            guard region.isEmpty else { return RegionEdit(range: region, text: "") }
            return RegionEdit(range: Region(anchor: positionBefore(region.head), head: region.head),
                              text: "")
        }
        return carets(from: applyEdits(edits), primaryIndex: selection.primaryIndex)
    }

    @discardableResult
    func deleteForward(over selection: Selection) -> Selection {
        let edits = selection.regions.map { region -> RegionEdit in
            guard region.isEmpty else { return RegionEdit(range: region, text: "") }
            return RegionEdit(range: Region(anchor: region.head, head: positionAfter(region.head)),
                              text: "")
        }
        return carets(from: applyEdits(edits), primaryIndex: selection.primaryIndex)
    }

    /// Deletes from each caret back to the previous word boundary (⌥⌫).
    @discardableResult
    func deleteWordBackward(over selection: Selection) -> Selection {
        let edits = selection.regions.map { region -> RegionEdit in
            guard region.isEmpty else { return RegionEdit(range: region, text: "") }
            return RegionEdit(range: Region(anchor: wordBoundary(from: region.head, forward: false),
                                            head: region.head), text: "")
        }
        return carets(from: applyEdits(edits), primaryIndex: selection.primaryIndex)
    }

    @discardableResult
    func deleteWordForward(over selection: Selection) -> Selection {
        let edits = selection.regions.map { region -> RegionEdit in
            guard region.isEmpty else { return RegionEdit(range: region, text: "") }
            return RegionEdit(range: Region(anchor: region.head,
                                            head: wordBoundary(from: region.head, forward: true)),
                              text: "")
        }
        return carets(from: applyEdits(edits), primaryIndex: selection.primaryIndex)
    }

    // MARK: - Reading

    func text(in region: Region) -> String {
        let start = byteOffset(of: clamp(region.start))
        let end = byteOffset(of: clamp(region.end))
        guard end > start else { return "" }
        return snapshot().text(offset: start, length: end - start)
    }

    /// Each region's text, in document order — what ⌘C puts on the pasteboard.
    func texts(in selection: Selection) -> [String] {
        selection.regions.map { text(in: $0) }
    }

    /// The distinct line indices any region touches, ascending.
    func lines(touchedBy selection: Selection) -> [Int] {
        var seen = Set<Int>()
        var result: [Int] = []
        for region in selection.regions {
            // A selection ending exactly at column 0 does not include that line.
            var last = region.end.line
            if region.end.line > region.start.line && region.end.column == 0 { last -= 1 }
            for lineIndex in region.start.line ... max(region.start.line, last)
            where !seen.contains(lineIndex) {
                seen.insert(lineIndex)
                result.append(lineIndex)
            }
        }
        return result.sorted()
    }

    // MARK: - Movement

    /// Moves or extends every caret. `extend` keeps each anchor in place (shift-arrow).
    func moved(_ selection: Selection,
               extend: Bool,
               transform: (Region) -> Position) -> Selection {
        var updated = selection
        updated.map { region in
            // Collapsing a selection with an unshifted arrow lands on its edge,
            // it does not move a further character.
            if !extend && !region.isEmpty {
                if let collapsed = collapseTarget(region, transform: transform) {
                    return Region(caret: collapsed)
                }
            }
            let head = clamp(transform(region))
            return Region(anchor: extend ? region.anchor : head, head: head)
        }
        return updated
    }

    private func collapseTarget(_ region: Region, transform: (Region) -> Position) -> Position? {
        let probe = clamp(transform(Region(caret: region.head)))
        if probe < region.head { return region.start }
        if probe > region.head { return region.end }
        return nil
    }

    /// Position one grapheme left of `position`, crossing to the previous line.
    func positionBefore(_ position: Position) -> Position {
        let p = clamp(position)
        if p.column > 0 { return Position(line: p.line, column: p.column - 1) }
        guard p.line > 0 else { return p }
        return Position(line: p.line - 1, column: lineLength(p.line - 1))
    }

    func positionAfter(_ position: Position) -> Position {
        let p = clamp(position)
        if p.column < lineLength(p.line) { return Position(line: p.line, column: p.column + 1) }
        guard p.line + 1 < lineCount else { return p }
        return Position(line: p.line + 1, column: 0)
    }

    var endPosition: Position {
        Position(line: lineCount - 1, column: lineLength(lineCount - 1))
    }
}
