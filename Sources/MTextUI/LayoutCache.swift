import AppKit
import CoreText
import MTextCore

/// Caches the shaped `CTLine` for each line.
///
/// Shaping is the expensive part of drawing and scrolling re-draws the same lines over
/// and over, so entries are keyed by line index and dropped when the document
/// generation, the font, or a line's highlighting changes.
final class LayoutCache {

    struct Entry {
        let text: String
        let ctLine: CTLine
        /// False when the line was shaped before its syntax spans arrived, so the
        /// renderer knows to rebuild it once they do.
        let isHighlighted: Bool
    }

    private var entries: [Int: Entry] = [:]
    private var generation: UInt64 = .max
    private let limit = 2_000

    var font: NSFont { didSet { invalidateAll() } }

    init(font: NSFont) {
        self.font = font
    }

    func invalidateAll() {
        entries.removeAll(keepingCapacity: true)
    }

    func invalidate(lines range: ClosedRange<Int>) {
        for line in range { entries[line] = nil }
    }

    /// Returns the shaped line, building it via `makeAttributed` on a miss.
    ///
    /// `makeAttributed` returns nil when the line has no highlighting yet; the plain
    /// fallback is shaped instead and the entry is marked un-highlighted so it is
    /// rebuilt when spans arrive.
    func entry(forLine index: Int,
               in document: TextDocument,
               plainAttributes: [NSAttributedString.Key: Any],
               makeAttributed: (Int, String) -> NSAttributedString?) -> Entry {
        if document.generation != generation {
            generation = document.generation
            entries.removeAll(keepingCapacity: true)
        }
        if let cached = entries[index], cached.isHighlighted { return cached }

        let text = document.line(index)
        let attributed = makeAttributed(index, text)
        let string = attributed ?? NSAttributedString(string: text, attributes: plainAttributes)
        let ctLine = CTLineCreateWithAttributedString(string)
        let entry = Entry(text: text, ctLine: ctLine, isHighlighted: attributed != nil)

        if entries.count >= limit { entries.removeAll(keepingCapacity: true) }
        entries[index] = entry
        return entry
    }

    /// For strings that are not a document line (gutter numbers, measuring).
    func makeCTLine(_ string: String, color: NSColor) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
    }
}
