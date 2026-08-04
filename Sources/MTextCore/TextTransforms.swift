import Foundation

/// Line and text transforms — the Edit ▸ Line and Edit ▸ Convert Case commands.
/// Each runs as one undo step and returns the selection to install afterwards.
public extension TextDocument {

    // MARK: - Case

    @discardableResult
    func transformCase(_ selection: Selection, _ transform: (String) -> String) -> Selection {
        // Operate on words when nothing is selected, which is what users expect.
        let targets = selection.regions.map { region -> Region in
            region.isEmpty ? wordRange(at: region.head) : region
        }
        let working = Selection(regions: targets, primaryIndex: selection.primaryIndex)
        let replacements = working.regions.map { transform(text(in: $0)) }
        return replaceKeepingSelection(working, with: replacements)
    }

    @discardableResult
    func upperCase(_ selection: Selection) -> Selection {
        transformCase(selection) { $0.uppercased() }
    }

    @discardableResult
    func lowerCase(_ selection: Selection) -> Selection {
        transformCase(selection) { $0.lowercased() }
    }

    @discardableResult
    func titleCase(_ selection: Selection) -> Selection {
        transformCase(selection) { $0.capitalized }
    }

    @discardableResult
    func swapCase(_ selection: Selection) -> Selection {
        transformCase(selection) { text in
            // Appending strings rather than building Characters: "ß".uppercased()
            // is "SS", and Character(_:) traps on more than one grapheme cluster.
            text.reduce(into: "") { result, character in
                if character.isUppercase {
                    result += character.lowercased()
                } else if character.isLowercase {
                    result += character.uppercased()
                } else {
                    result.append(character)
                }
            }
        }
    }

    // MARK: - Line operations

    /// Contiguous runs of touched lines, so a multi-cursor selection spanning
    /// separate blocks moves each block independently.
    private func lineBlocks(_ selection: Selection) -> [ClosedRange<Int>] {
        let touched = lines(touchedBy: selection)
        guard !touched.isEmpty else { return [] }
        var blocks: [ClosedRange<Int>] = []
        var start = touched[0]
        var previous = touched[0]
        for lineIndex in touched.dropFirst() {
            if lineIndex == previous + 1 {
                previous = lineIndex
            } else {
                blocks.append(start ... previous)
                start = lineIndex
                previous = lineIndex
            }
        }
        blocks.append(start ... previous)
        return blocks
    }

    /// Replaces whole lines `range` with `newLines`, as one edit.
    private func replaceLines(_ range: ClosedRange<Int>, with newLines: [String]) {
        let start = Position(line: range.lowerBound, column: 0)
        let hasTrailingNewline = range.upperBound + 1 < lineCount
        let end = hasTrailingNewline
            ? Position(line: range.upperBound + 1, column: 0)
            : Position(line: range.upperBound, column: lineLength(range.upperBound))
        _ = delete(from: start, to: end)
        var text = newLines.joined(separator: "\n")
        if hasTrailingNewline { text += "\n" }
        if !text.isEmpty { _ = insert(text, at: start) }
    }

    private func currentLines(_ range: ClosedRange<Int>) -> [String] {
        range.map { line($0) }
    }

    /// Moves each touched block of lines up or down by one (⌃⌘↑ / ⌃⌘↓).
    @discardableResult
    func moveLines(_ selection: Selection, up: Bool) -> Selection {
        let blocks = lineBlocks(selection)
        guard !blocks.isEmpty else { return selection }
        if up && blocks[0].lowerBound == 0 { return selection }
        if !up && blocks[blocks.count - 1].upperBound >= lineCount - 1 { return selection }

        undoStack.beginTransaction()
        defer { undoStack.endTransaction() }

        // Process bottom-up so earlier line numbers stay valid.
        for block in blocks.reversed() {
            if up {
                let span = (block.lowerBound - 1) ... block.upperBound
                var lines = currentLines(span)
                let moved = lines.removeFirst()
                lines.append(moved)
                replaceLines(span, with: lines)
            } else {
                let span = block.lowerBound ... (block.upperBound + 1)
                var lines = currentLines(span)
                let moved = lines.removeLast()
                lines.insert(moved, at: 0)
                replaceLines(span, with: lines)
            }
        }

        let delta = up ? -1 : 1
        var shifted = selection
        shifted.map { region in
            Region(anchor: clamp(Position(line: region.anchor.line + delta, column: region.anchor.column)),
                   head: clamp(Position(line: region.head.line + delta, column: region.head.column)))
        }
        return shifted
    }

    /// Duplicates the touched lines below themselves (⇧⌘D).
    @discardableResult
    func duplicateLines(_ selection: Selection) -> Selection {
        let blocks = lineBlocks(selection)
        guard !blocks.isEmpty else { return selection }

        undoStack.beginTransaction()
        defer { undoStack.endTransaction() }

        for block in blocks.reversed() {
            let copy = currentLines(block)
            let insertAt = Position(line: block.lowerBound, column: 0)
            _ = insert(copy.joined(separator: "\n") + "\n", at: insertAt)
        }

        // Carets follow the lower copy, shifted only by the blocks at or above them —
        // a single total would over-shift carets in the topmost block.
        func shift(_ position: Position) -> Position {
            let lines = blocks.reduce(0) { $0 + ($1.lowerBound <= position.line ? $1.count : 0) }
            return clamp(Position(line: position.line + lines, column: position.column))
        }
        var shifted = selection
        shifted.map { Region(anchor: shift($0.anchor), head: shift($0.head)) }
        return shifted
    }

    /// Joins each touched line with the one below, collapsing indentation (⌘J).
    @discardableResult
    func joinLines(_ selection: Selection) -> Selection {
        let blocks = lineBlocks(selection)
        guard !blocks.isEmpty else { return selection }

        undoStack.beginTransaction()
        defer { undoStack.endTransaction() }

        // Caret offsets are tracked in bytes and rebased as blocks above them collapse,
        // the same rule `applyEdits` uses.
        var offsets: [Int] = []
        for block in blocks.reversed() {
            // One join per gap inside the block; a bare caret joins the line below it.
            let target = block.count > 1 ? block.upperBound - 1 : block.lowerBound
            let last = max(block.lowerBound, min(target, lineCount - 2))
            guard block.lowerBound <= last, block.lowerBound + 1 < lineCount else { continue }

            // The caret lands at the first join point, captured before any join —
            // intermediate positions get collapsed away by the joins below it.
            let caretColumn = lineLength(block.lowerBound)
            let bytesBefore = byteCount

            for lineIndex in stride(from: last, through: block.lowerBound, by: -1) {
                guard lineIndex + 1 < lineCount else { continue }
                let end = Position(line: lineIndex, column: lineLength(lineIndex))
                let nextIndent = firstNonBlankColumn(of: lineIndex + 1)
                let joinEnd = Position(line: lineIndex + 1, column: nextIndent)
                let separator = lineLength(lineIndex) == 0 || nextIndent == lineLength(lineIndex + 1) ? "" : " "
                _ = delete(from: end, to: joinEnd)
                if !separator.isEmpty { _ = insert(separator, at: end) }
            }

            // Everything recorded so far sits below this block, so it shifts up.
            let removed = bytesBefore - byteCount
            if removed != 0 {
                for i in offsets.indices { offsets[i] -= removed }
            }
            offsets.append(byteOffset(of: clamp(Position(line: block.lowerBound, column: caretColumn))))
        }
        guard !offsets.isEmpty else { return selection }
        return Selection(regions: offsets.map { Region(caret: position(ofByteOffset: $0)) })
    }

    /// Deletes the touched lines outright (⌃⇧K).
    @discardableResult
    func deleteLines(_ selection: Selection) -> Selection {
        let blocks = lineBlocks(selection)
        guard !blocks.isEmpty else { return selection }

        undoStack.beginTransaction()
        defer { undoStack.endTransaction() }

        // As in joinLines: byte offsets, rebased as blocks above are removed.
        var offsets: [Int] = []
        for block in blocks.reversed() {
            let start = Position(line: block.lowerBound, column: 0)
            let bytesBefore = byteCount
            let caret: Position
            if block.upperBound + 1 < lineCount {
                // Take the block plus its trailing newline.
                caret = delete(from: start, to: Position(line: block.upperBound + 1, column: 0))
            } else {
                // Last block: take the newline *above* it instead, so the previous
                // line does not gain a stray empty line below it.
                let documentEnd = Position(line: lineCount - 1, column: lineLength(lineCount - 1))
                let from = block.lowerBound > 0
                    ? Position(line: block.lowerBound - 1, column: lineLength(block.lowerBound - 1))
                    : start
                caret = delete(from: from, to: documentEnd)
            }
            let removed = bytesBefore - byteCount
            if removed != 0 {
                for i in offsets.indices { offsets[i] -= removed }
            }
            offsets.append(byteOffset(of: clamp(caret)))
        }
        guard !offsets.isEmpty else { return selection }
        return Selection(regions: offsets.map { Region(caret: position(ofByteOffset: $0)) })
    }

    /// Sorts the touched lines. One undo step; the selection is preserved.
    @discardableResult
    func sortLines(_ selection: Selection, ascending: Bool = true, caseSensitive: Bool = true) -> Selection {
        transformBlocks(selection) { lines in
            lines.sorted { a, b in
                let result = caseSensitive
                    ? a.compare(b) == .orderedAscending
                    : a.lowercased().compare(b.lowercased()) == .orderedAscending
                return ascending ? result : !result
            }
        }
    }

    @discardableResult
    func reverseLines(_ selection: Selection) -> Selection {
        transformBlocks(selection) { $0.reversed() }
    }

    /// Removes duplicate lines, keeping first occurrences in order.
    @discardableResult
    func uniqueLines(_ selection: Selection) -> Selection {
        transformBlocks(selection) { lines in
            var seen = Set<String>()
            return lines.filter { seen.insert($0).inserted }
        }
    }

    private func transformBlocks(_ selection: Selection,
                                 _ transform: ([String]) -> [String]) -> Selection {
        let blocks = lineBlocks(selection)
        guard !blocks.isEmpty else { return selection }

        undoStack.beginTransaction()
        defer { undoStack.endTransaction() }

        for block in blocks.reversed() {
            replaceLines(block, with: transform(currentLines(block)))
        }
        var updated = selection
        updated.map { Region(anchor: clamp($0.anchor), head: clamp($0.head)) }
        return updated
    }

    // MARK: - Indentation

    @discardableResult
    func indent(_ selection: Selection, using unit: String = "    ") -> Selection {
        let touched = lines(touchedBy: selection)
        guard !touched.isEmpty else { return selection }

        undoStack.beginTransaction()
        defer { undoStack.endTransaction() }

        for lineIndex in touched.reversed() where lineLength(lineIndex) > 0 || touched.count == 1 {
            _ = insert(unit, at: Position(line: lineIndex, column: 0))
        }
        let width = unit.count
        var updated = selection
        updated.map { region in
            Region(anchor: clamp(Position(line: region.anchor.line, column: region.anchor.column + width)),
                   head: clamp(Position(line: region.head.line, column: region.head.column + width)))
        }
        return updated
    }

    @discardableResult
    func outdent(_ selection: Selection, using unit: String = "    ") -> Selection {
        let touched = lines(touchedBy: selection)
        guard !touched.isEmpty else { return selection }

        undoStack.beginTransaction()
        defer { undoStack.endTransaction() }

        var removed: [Int: Int] = [:]
        for lineIndex in touched.reversed() {
            let text = line(lineIndex)
            var count = 0
            if text.hasPrefix(unit) {
                count = unit.count
            } else if text.hasPrefix("\t") {
                count = 1
            } else {
                count = text.prefix(unit.count).prefix { $0 == " " }.count
            }
            guard count > 0 else { continue }
            _ = delete(from: Position(line: lineIndex, column: 0),
                       to: Position(line: lineIndex, column: count))
            removed[lineIndex] = count
        }
        var updated = selection
        updated.map { region in
            Region(anchor: shiftLeft(region.anchor, by: removed[region.anchor.line] ?? 0),
                   head: shiftLeft(region.head, by: removed[region.head.line] ?? 0))
        }
        return updated
    }

    private func shiftLeft(_ position: Position, by amount: Int) -> Position {
        clamp(Position(line: position.line, column: max(0, position.column - amount)))
    }

    // MARK: - Comments

    /// Toggles a line comment on the touched lines. If every non-blank line is
    /// already commented, they are uncommented instead.
    @discardableResult
    func toggleLineComment(_ selection: Selection, token: String = "//") -> Selection {
        let touched = lines(touchedBy: selection).filter { !line($0).trimmingCharacters(in: .whitespaces).isEmpty }
        guard !touched.isEmpty else { return selection }

        let prefix = token + " "
        let allCommented = touched.allSatisfy {
            line($0).trimmingCharacters(in: .whitespaces).hasPrefix(token)
        }

        undoStack.beginTransaction()
        defer { undoStack.endTransaction() }

        // Per-line column shifts, so carets stay on the text they were on rather than
        // ending up inside the comment token.
        var shifts: [Int: (from: Int, by: Int)] = [:]

        if allCommented {
            for lineIndex in touched.reversed() {
                let text = line(lineIndex)
                guard let range = text.range(of: token) else { continue }
                let startColumn = text.distance(from: text.startIndex, to: range.lowerBound)
                let extra = text[range.upperBound...].hasPrefix(" ") ? 1 : 0
                let width = token.count + extra
                _ = delete(from: Position(line: lineIndex, column: startColumn),
                           to: Position(line: lineIndex, column: startColumn + width))
                shifts[lineIndex] = (from: startColumn, by: -width)
            }
        } else {
            // Align every comment at the shallowest indentation in the block.
            let column = touched.map { firstNonBlankColumn(of: $0) }.min() ?? 0
            for lineIndex in touched.reversed() {
                _ = insert(prefix, at: clamp(Position(line: lineIndex, column: column)))
                shifts[lineIndex] = (from: column, by: prefix.count)
            }
        }

        func shift(_ position: Position) -> Position {
            guard let entry = shifts[position.line], position.column >= entry.from else {
                return clamp(position)
            }
            return clamp(Position(line: position.line,
                                  column: max(entry.from, position.column + entry.by)))
        }
        var updated = selection
        updated.map { Region(anchor: shift($0.anchor), head: shift($0.head)) }
        return updated
    }
}
