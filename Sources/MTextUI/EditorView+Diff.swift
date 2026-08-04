import AppKit
import MTextCore

// T102 — the diff gutter, and reverting a hunk back to what's on disk.
//
// The baseline is the file's contents as last loaded or saved, held in memory. Re-reading
// the file to diff against would mean hitting the disk on every gutter draw, and would also
// diff against a file that changed underneath the editor — which is a *different* question
// (T19's external-change detection) from "what have I changed since I opened this".
extension EditorView {

    /// Marks for the current buffer, cached against `TextDocument.generation`.
    ///
    /// Same staleness mechanism `BufferWordIndex` and `LayoutCache` use. Without it the diff
    /// would run on every gutter repaint — including every caret blink — rather than once
    /// per edit.
    var diffMarks: [Int: DiffMark] {
        guard let baseline = diffBaseline else { return [:] }
        if cachedDiffGeneration == document.generation { return cachedDiffMarks }
        let marks = LineDiff.marks(old: baseline, new: currentLines)
        cachedDiffMarks = marks
        cachedDiffGeneration = document.generation
        return marks
    }

    var currentLines: [String] {
        (0 ..< document.lineCount).map { document.line($0) }
    }

    /// Adopts the current contents as the baseline — on load, and on save, since after a
    /// save the file on disk *is* the buffer.
    func resetDiffBaseline() {
        diffBaseline = document.fileURL == nil ? nil : currentLines
        cachedDiffGeneration = nil
        cachedDiffMarks = [:]
        needsDisplay = true
    }

    // MARK: - Drawing

    /// A bar in the gutter's left edge — green added, blue modified, and a wedge for a
    /// deletion, which has no line of its own to colour.
    func drawDiffMark(forLine line: Int) {
        guard showsGutter, let mark = diffMarks[line] else { return }
        let originX = (enclosingScrollView?.contentView.bounds.origin.x).map { max(0, $0) } ?? 0
        // Sits just inside the gutter's right edge, clear of the fold triangle on the left.
        let x = originX + gutterWidth - 3
        let top = lineTop(line)

        switch mark {
        case .added:
            NSColor.systemGreen.withAlphaComponent(0.85).setFill()
            NSRect(x: x, y: top, width: 2, height: lineHeight).fill()
        case .modified:
            NSColor.systemBlue.withAlphaComponent(0.85).setFill()
            NSRect(x: x, y: top, width: 2, height: lineHeight).fill()
        case .deletedAbove:
            NSColor.systemRed.withAlphaComponent(0.85).setFill()
            // A small triangle at the boundary, since the deleted lines aren't on screen.
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x + 2, y: top))
            path.line(to: NSPoint(x: x + 2, y: top + 5))
            path.line(to: NSPoint(x: x - 3, y: top))
            path.close()
            path.fill()
        }
    }

    // MARK: - Revert

    /// Puts the hunk under the caret back to what is on disk.
    ///
    /// Goes through `didEdit`, so it is one ordinary undo step — reverting a hunk you didn't
    /// mean to revert must be undoable like any other edit, not a special irreversible action.
    @objc public func revertHunk(_ sender: Any?) {
        guard let baseline = diffBaseline else {
            NSSound.beep()
            return
        }
        let line = selection.primary.head.line
        guard let hunk = LineDiff.hunk(containing: line, old: baseline, new: currentLines) else {
            NSSound.beep()
            return
        }

        let replacement = hunk.oldRange.isEmpty
            ? ""
            : hunk.oldRange.map { baseline[$0] }.joined(separator: "\n")

        // The region to replace: the hunk's lines, plus the trailing newline when the hunk
        // is being deleted entirely, so reverting an addition doesn't leave a blank line.
        let startLine = min(hunk.newRange.lowerBound, max(0, document.lineCount - 1))
        let endLine = hunk.newRange.upperBound
        let start = Position(line: startLine, column: 0)
        let end: Position
        var text = replacement

        if hunk.newRange.isEmpty {
            // Pure deletion: re-insert the old lines above this one.
            end = start
            text = replacement + "\n"
        } else if endLine < document.lineCount {
            end = Position(line: endLine, column: 0)
            if !hunk.oldRange.isEmpty { text = replacement + "\n" }
        } else {
            end = Position(line: document.lineCount - 1,
                           column: document.lineLength(document.lineCount - 1))
        }

        let region = Region(anchor: start, head: end)
        didEdit(newSelection: document.replace(Selection(regions: [region]), withEach: text))
        didMoveSelection(Selection(caret: document.clamp(start)))
    }

    /// Greys the command out when there is nothing under the caret to revert.
    var canRevertHunk: Bool {
        guard let baseline = diffBaseline else { return false }
        return LineDiff.hunk(containing: selection.primary.head.line,
                             old: baseline, new: currentLines) != nil
    }
}
