import AppKit
import MTextCore

/// Pointer selection: drag, double/triple click, ⌘-click to add a caret,
/// ⌥-drag for rectangular selection.
extension EditorView {

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        // A click on a gutter fold triangle toggles the fold and goes no further — it must
        // not also move the caret to that line (T92).
        if handleFoldClick(at: point) { return }
        let clicked = position(at: point)
        // T64: a double-click in a results buffer opens the match rather than selecting the
        // word under the pointer.
        if isFindResultsBuffer, event.clickCount == 2, activateResult(atLine: clicked.line) {
            return
        }
        let additive = event.modifierFlags.contains(.command)
        let extending = event.modifierFlags.contains(.shift)
        let rectangular = event.modifierFlags.contains(.option)

        dragOrigin = clicked
        dragBaseRegions = additive ? selection.regions : []

        if rectangular {
            dragMode = .column
            dragOriginRegion = Region(caret: clicked)
            didMoveSelection(Selection(caret: clicked), scroll: false)
            return
        }

        switch event.clickCount {
        case 1 where extending:
            // Shift-click extends the primary region from its existing anchor.
            dragMode = .character
            var updated = selection
            let anchor = updated.primary.anchor
            updated.primary = Region(anchor: anchor, head: clicked)
            dragOriginRegion = Region(anchor: anchor, head: clicked)
            didMoveSelection(updated, scroll: false)

        case 1:
            dragMode = .character
            let region = Region(caret: clicked)
            dragOriginRegion = region
            didMoveSelection(newSelection(adding: region, additive: additive), scroll: false)

        case 2:
            dragMode = .word
            let region = document.wordRange(at: clicked)
            dragOriginRegion = region
            didMoveSelection(newSelection(adding: region, additive: additive), scroll: false)

        default:
            dragMode = .line
            let region = document.lineRegion(at: clicked)
            dragOriginRegion = region
            didMoveSelection(newSelection(adding: region, additive: additive), scroll: false)
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        autoscroll(with: event)

        if dragMode == .column {
            didMoveSelection(columnSelection(from: dragOrigin, toPoint: point), scroll: false)
            return
        }

        guard let origin = dragOriginRegion else { return }
        let current = position(at: point)
        let extended: Region

        switch dragMode {
        case .word:
            let word = document.wordRange(at: current)
            extended = current < origin.start
                ? Region(anchor: origin.end, head: word.start)
                : Region(anchor: origin.start, head: word.end)
        case .line:
            let lineRegion = document.lineRegion(at: current)
            extended = current < origin.start
                ? Region(anchor: origin.end, head: lineRegion.start)
                : Region(anchor: origin.start, head: lineRegion.end)
        case .character, .column:
            extended = Region(anchor: origin.anchor, head: current)
        }

        var updated = Selection(regions: dragBaseRegions + [extended], primaryIndex: dragBaseRegions.count)
        if dragBaseRegions.isEmpty { updated = Selection(extended) }
        didMoveSelection(updated, scroll: false)
    }

    public override func mouseUp(with event: NSEvent) {
        dragOriginRegion = nil
        dragBaseRegions = []
        dragMode = .character
        document.breakUndoCoalescing()
    }

    /// ⌘-click adds a caret; a plain click replaces the selection. Clicking an
    /// existing caret with ⌘ held removes it, matching Sublime.
    private func newSelection(adding region: Region, additive: Bool) -> Selection {
        guard additive else { return Selection(region) }

        if region.isEmpty, selection.count > 1,
           let index = selection.regions.firstIndex(where: { $0.contains(region.head) }) {
            var remaining = selection.regions
            remaining.remove(at: index)
            return Selection(regions: remaining, primaryIndex: max(0, index - 1))
        }
        var updated = selection
        updated.add(region)
        return updated
    }

    /// One region per line between the drag origin and the current point, at the
    /// same x range — Sublime's ⌥-drag column selection.
    private func columnSelection(from origin: Position, toPoint point: NSPoint) -> Selection {
        let originX = xOffset(ofColumn: origin.column, line: origin.line)
        let target = position(at: point)

        let topLine = min(origin.line, target.line)
        let bottomLine = max(origin.line, target.line)
        let leftX = min(originX, point.x)
        let rightX = max(originX, point.x)

        var regions: [Region] = []
        for lineIndex in topLine ... bottomLine {
            let length = document.lineLength(lineIndex)
            let from = min(column(atX: leftX, line: lineIndex), length)
            let to = min(column(atX: rightX, line: lineIndex), length)
            // Lines too short to reach the left edge still get a caret at their end,
            // so typing lands on every line of the block.
            regions.append(Region(anchor: Position(line: lineIndex, column: from),
                                  head: Position(line: lineIndex, column: to)))
        }
        let primaryIndex = target.line >= origin.line ? regions.count - 1 : 0
        return Selection(regions: regions, primaryIndex: primaryIndex)
    }

    // MARK: - Cursor

    public override func resetCursorRects() {
        discardCursorRects()
        // Cursor rects are in document coordinates, but the gutter is painted pinned
        // to the viewport's left edge — so the arrow region must follow the scroll.
        let originX = max(0, visibleRect.origin.x)
        let textStart = originX + gutterWidth + textPadding
        addCursorRect(NSRect(x: textStart, y: 0,
                             width: max(0, bounds.width - textStart), height: bounds.height),
                      cursor: .iBeam)
        if showsGutter {
            addCursorRect(NSRect(x: originX, y: 0, width: gutterWidth, height: bounds.height),
                          cursor: .arrow)
        }
    }
}
