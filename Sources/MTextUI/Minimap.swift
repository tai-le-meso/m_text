import AppKit
import MTextCore

/// The downsampled overview strip beside the editor (T93).
///
/// Draws from **highlight spans**, not from shaped text: at two points per row there is no
/// glyph to read, so what makes a minimap legible is the colour and shape of the code, which
/// is exactly what the spans already describe. That also means it costs nothing extra —
/// `HighlightService` has computed them for the visible window regardless.
///
/// Renders **rows**, via the editor's `RowMap`, rather than document lines. A minimap that
/// disagreed with what folding and wrapping put on screen would be worse than none: dragging
/// it would land somewhere other than where it pointed.
final class Minimap: NSView {

    weak var editor: EditorView?

    /// Points per row. Two is the smallest that still leaves a visible gap between rows at
    /// 1x; Sublime uses roughly the same.
    private let rowHeight: CGFloat = 2
    /// Points per character. One means a 100-column line reads as 100pt of colour, which is
    /// why the strip is ~110pt wide.
    private let columnWidth: CGFloat = 1
    /// Rows scanned per repaint. A minimap of a 200k-line file cannot draw every row, and
    /// past a few thousand the strip is a solid block anyway — see `scale`.
    private let maximumRowsDrawn = 3000

    static let preferredWidth: CGFloat = 110

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    /// How many document rows one point of minimap covers.
    ///
    /// 1 while the whole document fits. Beyond that the minimap **compresses** rather than
    /// scrolls: the entire file stays represented in the strip, which is the property that
    /// makes it useful for orientation in a large file. The cost is that individual rows stop
    /// being distinguishable, which is unavoidable at any scale.
    private var scale: CGFloat {
        guard let editor, editor.rowMap.totalRows > 0 else { return 1 }
        let needed = CGFloat(editor.rowMap.totalRows) * rowHeight
        guard needed > bounds.height, bounds.height > 0 else { return 1 }
        return needed / bounds.height
    }

    private func y(forRow row: Int) -> CGFloat {
        CGFloat(row) * rowHeight / scale
    }

    private func row(atY y: CGFloat) -> Int {
        guard rowHeight > 0 else { return 0 }
        return max(0, Int(y * scale / rowHeight))
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let editor else { return }
        editor.themeBackground.setFill()
        dirtyRect.fill()

        let total = editor.rowMap.totalRows
        guard total > 0, bounds.height > 0 else { return }

        // Sample rather than draw every row once the file is large: at scale > 1 several
        // rows share a point line, so drawing all of them is wasted work for pixels that
        // overwrite each other.
        let step = max(1, total / maximumRowsDrawn)
        var row = 0
        while row < total {
            drawRow(row, editor: editor, clip: dirtyRect)
            row += step
        }

        drawViewportBox(editor: editor)
    }

    private func drawRow(_ row: Int, editor: EditorView, clip: NSRect) {
        let y = self.y(forRow: row)
        // Vertical culling: a repaint triggered by the viewport box moving shouldn't redraw
        // the whole strip.
        guard y + rowHeight >= clip.minY, y <= clip.maxY else { return }

        let location = editor.rowMap.location(ofRow: row)
        guard location.line < editor.document.lineCount else { return }
        let text = editor.document.line(location.line)
        guard !text.isEmpty else { return }

        // Only the slice of the line this row shows, so a wrapped line reads as several
        // rows rather than one long one repeated.
        let columns: Range<Int>
        if editor.rowMap.isWrapping {
            let breaks = editor.wrapBreaks(forLine: location.line, text: text)
            columns = WordWrapper.columnRange(ofRow: location.rowInLine, breaks: breaks,
                                              lineLength: text.count)
        } else {
            columns = 0 ..< text.count
        }

        let characters = Array(text)
        let spans = editor.highlightService.spans(forLine: location.line)
        let defaultColor = (editor.colorScheme.globals.foreground?.nsColor ?? .labelColor)
            .withAlphaComponent(0.55)

        // Runs of non-space characters become one rect each: drawing per character at 1pt
        // would be thousands of fills per repaint for the same visual result.
        var index = columns.lowerBound
        while index < min(columns.upperBound, characters.count) {
            guard !characters[index].isWhitespace else { index += 1; continue }
            let runStart = index
            while index < min(columns.upperBound, characters.count), !characters[index].isWhitespace {
                index += 1
            }
            // Named to avoid shadowing `color(forColumn:spans:text:editor:)`.
            let runColor = spans.flatMap { color(forColumn: runStart, spans: $0, text: text, editor: editor) }
                ?? defaultColor
            runColor.setFill()
            let x = CGFloat(runStart - columns.lowerBound) * columnWidth
            let width = CGFloat(index - runStart) * columnWidth
            NSRect(x: x, y: y, width: width, height: max(1, rowHeight / scale * 0.8)).fill()
        }
    }

    /// The scheme colour for the span covering `column`, if highlighting has reached this
    /// line. Spans are UTF-16 ranges, so the column is converted before comparing.
    private func color(forColumn column: Int, spans: [ScopeSpan],
                       text: String, editor: EditorView) -> NSColor? {
        guard !spans.isEmpty else { return nil }
        let utf16 = editor.utf16Offset(ofColumn: column, in: text)
        for span in spans where span.start <= utf16 && utf16 < span.end {
            if let foreground = editor.colorScheme.style(for: span.scopes).foreground {
                return foreground.nsColor.withAlphaComponent(0.85)
            }
        }
        return nil
    }

    /// Box over the rows currently on screen in the editor — the part that makes the strip
    /// navigable rather than decorative.
    private func drawViewportBox(editor: EditorView) {
        guard editor.lineHeight > 0 else { return }
        let visible = editor.visibleRect
        let firstRow = max(0, Int((visible.minY - editor.topPadding) / editor.lineHeight))
        let rowsOnScreen = max(1, Int(visible.height / editor.lineHeight))

        let top = y(forRow: firstRow)
        let height = max(4, CGFloat(rowsOnScreen) * rowHeight / scale)

        NSColor.labelColor.withAlphaComponent(0.10).setFill()
        NSRect(x: 0, y: top, width: bounds.width, height: height).fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: top, width: bounds.width, height: 1).fill()
        NSRect(x: 0, y: top + height - 1, width: bounds.width, height: 1).fill()
    }

    // MARK: - Interaction

    override func mouseDown(with event: NSEvent) {
        scrollEditor(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        scrollEditor(to: convert(event.locationInWindow, from: nil))
    }

    /// Centres the clicked row in the editor, which is what makes a click feel like "take me
    /// there" rather than "put that row at the very top".
    private func scrollEditor(to point: NSPoint) {
        guard let editor, let clip = editor.enclosingScrollView?.contentView else { return }
        let targetRow = min(row(atY: point.y), max(0, editor.rowMap.totalRows - 1))
        let targetY = editor.topPadding + CGFloat(targetRow) * editor.lineHeight
        let centred = targetY - clip.bounds.height / 2
        let maxY = max(0, editor.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(max(0, centred), maxY)))
        editor.enclosingScrollView?.reflectScrolledClipView(clip)
    }

    /// Scrolling over the minimap scrolls the document, matching every other overview strip.
    override func scrollWheel(with event: NSEvent) {
        editor?.enclosingScrollView?.scrollWheel(with: event)
    }
}
