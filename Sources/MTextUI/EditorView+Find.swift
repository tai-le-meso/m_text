import AppKit
import MTextCore

/// Find/replace integration: match highlighting and the commands that drive the session.
///
/// The `SearchSession` holds all search state; this extension only translates between it
/// and the view (scroll to a match, select it, repaint highlights).
extension EditorView {

    var searchSession: SearchSession {
        if let existing = cachedSearchSession { return existing }
        let session = SearchSession(document: document)
        cachedSearchSession = session
        return session
    }

    // MARK: - Commands

    /// ⌘F — show the find bar, seeded from the selection.
    @objc public func performFind(_ sender: Any?) {
        onFindRequested?(false)
        seedQueryFromSelection()
    }

    /// ⌥⌘F — show find *and* replace.
    @objc public func performFindAndReplace(_ sender: Any?) {
        onFindRequested?(true)
        seedQueryFromSelection()
    }

    private func seedQueryFromSelection() {
        let selected = document.text(in: selection.primary)
        guard !selected.isEmpty, !selected.contains("\n") else { return }
        onFindSeedText?(selected)
    }

    /// ⌘G. Falls back to the ⌘D needle when the find bar has never been used, so
    /// ⌘D then ⌘G behaves the way it does in Sublime.
    @objc public func findNextMatch(_ sender: Any?) {
        if searchSession.isEmpty, let needle = lastSearchNeedle, !needle.isEmpty {
            searchSession.setQuery(.literal(needle), near: selection.primary.end)
        }
        guard let match = searchSession.selectNext(from: selection.primary.end) else {
            refreshFindStatus()
            NSSound.beep()
            return
        }
        reveal(match)
    }

    @objc public func findPreviousMatch(_ sender: Any?) {
        if searchSession.isEmpty, let needle = lastSearchNeedle, !needle.isEmpty {
            searchSession.setQuery(.literal(needle), near: selection.primary.start)
        }
        guard let match = searchSession.selectPrevious(from: selection.primary.start) else {
            refreshFindStatus()
            NSSound.beep()
            return
        }
        reveal(match)
    }

    /// One cursor at every match — the find bar's "Find All".
    @objc public func selectAllMatches(_ sender: Any?) {
        searchSession.refresh(force: true)
        let regions = searchSession.matches.map(\.region)
        guard !regions.isEmpty else {
            NSSound.beep()
            return
        }
        didMoveSelection(Selection(regions: regions, primaryIndex: regions.count - 1))
    }

    // MARK: - Driven by the find bar

    func applySearchQuery(_ query: SearchQuery) {
        searchSession.setQuery(query, near: selection.primary.start)
        refreshFindStatus()
        if let match = searchSession.currentMatch {
            // Highlight the nearest match without moving the caret while the user types.
            // `scrollToVisible` moves the clip view's bounds origin, but `NSClipView` has
            // not redrawn the newly revealed strip on its own since macOS 11
            // (`copiesOnScroll` is a no-op) — normally `clipBoundsChanged()`'s
            // `boundsDidChangeNotification` observer covers that, but here it can race a
            // fast run of keystrokes each retriggering a jump before the previous one's
            // notification has been delivered, which is exactly the failure mode that
            // needed the same explicit force in `resizeEditorForFindBarChange` for the
            // find bar's own show/hide. Forcing the layout pass and repaint here too closes
            // that gap deterministically instead of leaving the editor blank until some
            // unrelated redraw happens to touch it.
            scrollToVisible(rect(for: match.region))
            enclosingScrollView?.contentView.layoutSubtreeIfNeeded()
        }
        needsDisplay = true
    }

    func replaceCurrentMatch(with template: String) {
        guard let caret = searchSession.replaceCurrent(with: template) else {
            NSSound.beep()
            return
        }
        didEdit(newSelection: Selection(caret: caret))
        refreshFindStatus()
        if let next = searchSession.currentMatch { reveal(next) }
    }

    func replaceAllMatches(with template: String) {
        let count = searchSession.replaceAll(with: template)
        guard count > 0 else {
            NSSound.beep()
            return
        }
        // One undo step for the lot — replaceAll goes through applyEdits. The caret must
        // be re-clamped: a shrinking replacement can leave it past the new end.
        didEdit(newSelection: Selection(caret: document.clamp(selection.primary.head)))
        refreshFindStatus()
    }

    func dismissFind() {
        searchSession.clear()
        needsDisplay = true
        window?.makeFirstResponder(self)
    }

    /// Drops match highlighting **without touching first responder** — for when the shared
    /// find bar moves to the other pane and this editor's matches stop being relevant.
    ///
    /// Distinct from `dismissFind()` on purpose. That one restores focus to its own editor,
    /// which is exactly right for Escape ("close find, put me back in the text") and
    /// exactly wrong here: the reason the bar is moving is that focus went to the *other*
    /// pane, so grabbing it back would undo the focus change that triggered this and snap
    /// the user to the pane they just left.
    func clearSearchHighlights() {
        searchSession.clear()
        onFindStatusChanged?(nil, false)
        needsDisplay = true
    }

    func refreshFindStatus() {
        onFindStatusChanged?(searchSession.statusText, searchSession.errorMessage != nil)
    }

    /// Keeps the match list in step with edits made outside the find bar.
    func searchDidEdit() {
        guard !searchSession.isEmpty else { return }
        searchSession.documentChanged()
        refreshFindStatus()
    }

    private func reveal(_ match: SearchMatch) {
        didMoveSelection(Selection(match.region))
        refreshFindStatus()
    }

    // MARK: - Drawing

    func rect(for region: Region) -> NSRect {
        let start = xOffset(ofColumn: region.start.column, line: region.start.line)
        let end = region.start.line == region.end.line
            ? xOffset(ofColumn: region.end.column, line: region.end.line)
            : bounds.width
        return NSRect(x: start,
                      y: lineTop(region.start.line),
                      width: max(2, end - start),
                      height: CGFloat(region.end.line - region.start.line + 1) * lineHeight)
    }

    /// All matches get a soft highlight; the selected one gets a stronger fill and an
    /// outline, so it stands out even where the selection highlight already sits.
    func drawSearchMatches(_ visible: VisibleRows) {
        let matches = searchSession.matches
        guard !matches.isEmpty else { return }

        let soft = NSColor.systemYellow.withAlphaComponent(0.28)
        let strong = NSColor.systemOrange.withAlphaComponent(0.45)
        let current = searchSession.currentMatch?.region

        for match in matches {
            let region = match.region
            guard region.end.line >= visible.lowerBound, region.start.line <= visible.upperBound else { continue }

            let isCurrent = region == current
            (isCurrent ? strong : soft).setFill()

            // Per row, clipped to each wrapped row's column slice — and never over a
            // collapsed region (T92, T28).
            for row in visible.rows where row.line >= region.start.line && row.line <= region.end.line {
                let lineFrom = row.line == region.start.line ? region.start.column : 0
                let lineTo = row.line == region.end.line
                    ? region.end.column
                    : document.lineLength(row.line)
                let fromColumn = max(lineFrom, row.columns.lowerBound)
                let toColumn = min(lineTo, row.columns.upperBound)
                guard fromColumn <= toColumn else { continue }
                let line = row.line
                let x0 = x(forColumn: fromColumn, in: row)
                let x1 = xOffset(ofColumn: toColumn, line: line)
                let rect = NSRect(x: x0, y: lineTop(line), width: max(2, x1 - x0), height: lineHeight)
                rect.fill()

                if isCurrent {
                    NSColor.systemOrange.setStroke()
                    let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
                    path.lineWidth = 1
                    path.stroke()
                }
            }
        }
    }
}
