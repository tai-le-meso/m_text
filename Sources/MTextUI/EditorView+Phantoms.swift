import AppKit
import MTextCore

// T103 — drawing inline annotations, and keeping them attached to their lines.
//
// The layout is entirely `RowMap`'s job (a phantom occupies a row like a wrapped line does);
// this file only paints the reserved row and shifts phantoms across edits.
extension EditorView {

    /// Paints one annotation row: a tinted band with the message, indented to the line's own
    /// indentation so it reads as belonging to that line rather than to the file.
    func drawPhantom(forRow row: VisibleRow, index: Int) {
        let onLine = phantoms.phantoms(onLine: row.line)
        guard index < onLine.count else { return }
        let phantom = onLine[index]

        let y = rowTop(row.row)
        let band = NSRect(x: textOriginX, y: y,
                          width: max(0, bounds.width - textOriginX - textPadding),
                          height: lineHeight)

        let tint: NSColor
        switch phantom.kind {
        case .error: tint = .systemRed
        case .warning: tint = .systemOrange
        case .info: tint = .systemBlue
        }
        tint.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: band.insetBy(dx: 0, dy: 1), xRadius: 3, yRadius: 3).fill()
        // A bar down the leading edge, so the kind is readable without relying on the tint
        // alone — the fills are deliberately faint so they don't compete with the code.
        tint.withAlphaComponent(0.8).setFill()
        NSRect(x: band.minX, y: band.minY + 1, width: 2, height: band.height - 2).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(9, font.pointSize - 2)),
            .foregroundColor: tint.blended(withFraction: 0.25, of: .labelColor) ?? tint,
        ]
        let inset = band.minX + 8
        (phantom.text as NSString).draw(
            in: NSRect(x: inset, y: y + (lineHeight - font.pointSize) / 2 - 1,
                       width: max(0, band.maxX - inset), height: lineHeight),
            withAttributes: attributes)
    }

    /// Keeps annotations attached to their text across an edit, and drops any whose line is
    /// gone — the same rule folds follow.
    func phantomsDidEdit(fromLine: Int, linesDelta: Int) {
        guard !phantoms.isEmpty, linesDelta != 0 else { return }
        var updated = phantoms
        updated.adjust(afterEditAt: fromLine, linesDelta: linesDelta)
        phantoms = updated
    }

    /// Clears every annotation, whoever put it there.
    @objc public func clearPhantoms(_ sender: Any?) {
        guard !phantoms.isEmpty else { return }
        var updated = phantoms
        updated.removeAll()
        phantoms = updated
    }
}
