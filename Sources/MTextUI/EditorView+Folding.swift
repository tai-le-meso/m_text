import AppKit
import MTextCore

// T92 — fold commands, gutter arrows, and keeping folds attached to their text.
//
// The mapping itself lives in `FoldSet` (MTextCore) and is unit tested; this file is the
// AppKit half: menu commands, the gutter triangle and its hit area, and the rules for when
// a fold has to open on its own.
extension EditorView {

    /// Tab width folding measures indentation with. Derived from `indentUnit` so it follows
    /// the `tab_size` setting (T86) rather than being hardcoded.
    var foldTabSize: Int { indentUnit == "\t" ? 4 : max(1, indentUnit.count) }

    /// The region that would fold at `line`, if any — what decides whether the gutter shows
    /// a triangle there.
    func foldRegion(at line: Int) -> FoldRegion? {
        FoldFinder.region(startingAt: line, in: document, tabSize: foldTabSize)
    }

    // MARK: - Commands

    /// ⌥⌘[ — fold the innermost region containing the caret.
    ///
    /// Walks *outward* from the caret line rather than only trying the caret's own line:
    /// pressing fold with the cursor inside a function body should fold that function,
    /// which is what you meant, not do nothing because the cursor wasn't on the `def`.
    @objc public func foldAtCaret(_ sender: Any?) {
        let caretLine = selection.primary.head.line
        var line = caretLine
        while line >= 0 {
            if let region = foldRegion(at: line), region.endLine >= caretLine, region.startLine <= caretLine {
                var updated = folds
                updated.fold(region)
                folds = updated
                // Leaving the caret inside collapsed text would hide it entirely; park it
                // on the fold's visible start line.
                if region.hiddenLines.contains(caretLine) {
                    didMoveSelection(Selection(caret: Position(line: region.startLine, column: 0)))
                }
                return
            }
            line -= 1
        }
        NSSound.beep()
    }

    /// ⌥⌘] — unfold the region at (or containing) the caret.
    @objc public func unfoldAtCaret(_ sender: Any?) {
        let caretLine = selection.primary.head.line
        var updated = folds
        if updated.unfold(startingAt: caretLine) {
            folds = updated
            return
        }
        guard let region = folds.regions.first(where: { $0.hiddenLines.contains(caretLine) || $0.startLine == caretLine })
        else {
            NSSound.beep()
            return
        }
        updated.unfold(startingAt: region.startLine)
        folds = updated
    }

    @objc public func foldAll(_ sender: Any?) {
        var updated = FoldSet()
        // Outermost first: `FoldSet.fold` drops anything already hidden, so this naturally
        // collapses to the top level rather than to a tangle of nested folds.
        for region in FoldFinder.allRegions(in: document, tabSize: foldTabSize)
            .sorted(by: { $0.startLine < $1.startLine }) {
            updated.fold(region)
        }
        folds = updated
        revealCaretIfFolded()
    }

    @objc public func unfoldAll(_ sender: Any?) {
        var updated = folds
        updated.unfoldAll()
        folds = updated
    }

    /// Fold everything at a given nesting depth — View ▸ Fold Level 1…4, matching Sublime's
    /// ⌘K ⌘1…⌘4.
    @objc public func foldLevel(_ sender: Any?) {
        let level = (sender as? NSMenuItem)?.tag ?? 1
        let all = FoldFinder.allRegions(in: document, tabSize: foldTabSize)
        var updated = FoldSet()
        for region in all.sorted(by: { $0.startLine < $1.startLine })
            where FoldFinder.level(of: region, among: all) >= level {
            updated.fold(region)
        }
        folds = updated
        revealCaretIfFolded()
    }

    // MARK: - Gutter interaction

    /// Rect of the fold triangle for `line`, inside the gutter.
    func foldTriangleRect(forLine line: Int) -> NSRect {
        let originX = (enclosingScrollView?.contentView.bounds.origin.x).map { max(0, $0) } ?? 0
        let size = min(lineHeight * 0.5, 10)
        return NSRect(x: originX + 2,
                      y: lineTop(line) + (lineHeight - size) / 2,
                      width: size,
                      height: size)
    }

    /// Handles a click in the gutter's fold column. Returns true when it toggled something,
    /// so the mouse handler knows not to also move the caret.
    func handleFoldClick(at point: NSPoint) -> Bool {
        guard showsGutter, let visible = visibleLines(in: visibleRect) else { return false }
        for line in visible.lines where foldTriangleRect(forLine: line).insetBy(dx: -3, dy: -3).contains(point) {
            guard let region = foldRegion(at: line) else { continue }
            var updated = folds
            updated.toggle(region)
            folds = updated
            revealCaretIfFolded()
            return true
        }
        return false
    }

    /// Draws the triangle: pointing down when open, right when collapsed.
    func drawFoldTriangle(forLine line: Int, folded: Bool) {
        let rect = foldTriangleRect(forLine: line)
        let path = NSBezierPath()
        if folded {
            path.move(to: NSPoint(x: rect.minX, y: rect.minY))
            path.line(to: NSPoint(x: rect.maxX, y: rect.midY))
            path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
        } else {
            path.move(to: NSPoint(x: rect.minX, y: rect.minY))
            path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
            path.line(to: NSPoint(x: rect.midX, y: rect.maxY))
        }
        path.close()
        // Stronger when collapsed: a closed fold hides text, so it should be noticeable
        // rather than blend into the gutter the way an open one can.
        themeGutterForeground.withAlphaComponent(folded ? 0.9 : 0.45).setFill()
        path.fill()
    }

    /// The "⋯" badge drawn after a folded line's text, standing in for what's hidden.
    func drawFoldedIndicator(forLine line: Int) {
        guard folds.isFolded(startLine: line) else { return }
        let entry = cachedLine(line)
        let x = xOffset(ofColumn: entry.text.count, line: line) + charWidth * 0.5
        let rect = NSRect(x: x, y: lineTop(line) + lineHeight * 0.25,
                          width: charWidth * 2.2, height: lineHeight * 0.5)
        NSColor.separatorColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()

        themeGutterForeground.setFill()
        let dot = min(2.0, lineHeight * 0.1)
        for index in 0 ..< 3 {
            let cx = rect.minX + rect.width * (CGFloat(index) + 1) / 4 - dot / 2
            NSRect(x: cx, y: rect.midY - dot / 2, width: dot, height: dot).fill()
        }
    }

    // MARK: - Staying consistent

    /// Opens any fold hiding the caret. Called after commands that can leave it buried —
    /// a caret you can't see is worse than a fold that reopened.
    func revealCaretIfFolded() {
        let line = selection.primary.head.line
        guard folds.isHidden(line: line) else { return }
        var updated = folds
        for region in folds.regions where region.hiddenLines.contains(line) {
            updated.unfold(startingAt: region.startLine)
        }
        folds = updated
    }

    /// Shifts folds to follow an edit, and drops them entirely when the edit was large
    /// enough that they can no longer describe the text.
    func foldsDidEdit(fromLine: Int) {
        let delta = document.lineCount - lastKnownLineCount
        lastKnownLineCount = document.lineCount
        guard !folds.isEmpty else { return }
        if delta != 0 {
            var updated = folds
            updated.adjust(afterEditAt: fromLine, linesDelta: delta)
            folds = updated
        }
        revealCaretIfFolded()
    }
}
