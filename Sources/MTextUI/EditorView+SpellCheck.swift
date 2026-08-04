import AppKit
import MTextCore

// T101 — spell checking, restricted to comments, strings and prose.
//
// `SpellCheckScopes` (MTextCore) decides *what* to check and is unit tested; this file is
// the AppKit half: asking `NSSpellChecker`, caching the answers, drawing the squiggles, and
// offering corrections.
extension EditorView {

    /// Misspelled ranges on one line, as UTF-16 ranges.
    ///
    /// Cached per line against `TextDocument.generation` — the same staleness mechanism the
    /// diff gutter and buffer-word index use. `NSSpellChecker` is a cross-process call, so
    /// asking it on every repaint would be far worse than the diff was: this way each line
    /// is checked once per edit, and only lines that are actually on screen are checked at all.
    func misspellings(onLine line: Int) -> [NSRange] {
        guard spellCheckEnabled else { return [] }
        if spellCheckGeneration != document.generation {
            spellCheckCache = [:]
            spellCheckGeneration = document.generation
        }
        if let cached = spellCheckCache[line] { return cached }

        let text = document.line(line)
        let utf16Length = (text as NSString).length
        let ranges = SpellCheckScopes.checkableRanges(
            spans: highlightService.spans(forLine: line),
            lineLength: utf16Length,
            baseScope: syntaxScope)

        var found: [NSRange] = []
        for range in ranges {
            found.append(contentsOf: Self.misspelledRanges(in: text,
                                                           within: NSRange(location: range.lowerBound,
                                                                           length: range.count)))
        }
        spellCheckCache[line] = found
        return found
    }

    /// Every misspelling inside `range`.
    ///
    /// `NSSpellChecker` reports one at a time, so this walks forward from each hit. The
    /// `wrap: false` matters — with wrapping it would loop back to the start of the string
    /// and never terminate.
    private static func misspelledRanges(in text: String, within range: NSRange) -> [NSRange] {
        guard range.length > 0 else { return [] }
        let checker = NSSpellChecker.shared
        var results: [NSRange] = []
        var location = range.location

        while location < range.upperBound {
            let found = checker.checkSpelling(of: text, startingAt: location, language: nil,
                                              wrap: false, inSpellDocumentWithTag: 0,
                                              wordCount: nil)
            guard found.location != NSNotFound, found.length > 0 else { break }
            // Stop once the checker walks past the region we asked about: it scans the whole
            // string, not just our slice, so a misspelling in the *code* after a comment
            // would otherwise be reported.
            guard found.location < range.upperBound else { break }
            results.append(found)
            location = found.location + found.length
        }
        return results
    }

    // MARK: - Drawing

    /// The squiggle. Drawn as a dotted underline rather than a real sine wave: at editor
    /// font sizes the two are visually indistinguishable, and this costs one fill per dot
    /// instead of a bezier path per word.
    func drawMisspellings(forRow row: VisibleRow) {
        guard spellCheckEnabled else { return }
        let ranges = misspellings(onLine: row.line)
        guard !ranges.isEmpty else { return }

        let text = document.line(row.line)
        NSColor.systemRed.withAlphaComponent(0.9).setFill()
        let y = lineTop(row.line) + lineHeight - 2

        for range in ranges {
            let startColumn = column(fromUTF16: range.location, in: text)
            let endColumn = column(fromUTF16: range.location + range.length, in: text)
            // Clipped to this row's columns, so a misspelling on a wrapped line is underlined
            // on the row it actually appears on (T28).
            let from = max(startColumn, row.columns.lowerBound)
            let to = min(endColumn, row.columns.upperBound)
            guard from < to else { continue }

            let x0 = x(forColumn: from, in: row)
            let x1 = x(forColumn: to, in: row)
            var dot = x0
            while dot < x1 {
                NSRect(x: dot, y: y, width: 1, height: 1).fill()
                dot += 2
            }
        }
    }

    // MARK: - Commands

    /// F6 — a view override like the other toggles, so a settings reload can't undo it.
    @objc public func toggleSpellCheck(_ sender: Any?) {
        setViewOverride("spell_check", .bool(!spellCheckEnabled))
    }

    /// ⌃F6 — move to the next misspelling, wrapping at the end of the document.
    @objc public func nextMisspelling(_ sender: Any?) {
        guard spellCheckEnabled, document.lineCount > 0 else {
            NSSound.beep()
            return
        }
        let caret = selection.primary.head
        let text = document.line(caret.line)
        let caretUTF16 = utf16Offset(ofColumn: caret.column, in: text)

        // Search from the caret to the end, then wrap — checking every line, not just the
        // visible ones, since the point is to find the one you *can't* see.
        for offset in 0 ... document.lineCount {
            let line = (caret.line + offset) % document.lineCount
            for range in misspellings(onLine: line)
            where !(offset == 0 && range.location <= caretUTF16) {
                let lineText = document.line(line)
                let start = column(fromUTF16: range.location, in: lineText)
                let end = column(fromUTF16: range.location + range.length, in: lineText)
                didMoveSelection(Selection(regions: [
                    Region(anchor: Position(line: line, column: start),
                           head: Position(line: line, column: end)),
                ]), scroll: true)
                return
            }
        }
        NSSound.beep()
    }

    /// Corrections for the word under the caret, for the context menu.
    func spellingSuggestions() -> [String] {
        let caret = selection.primary.head
        let text = document.line(caret.line)
        let utf16 = utf16Offset(ofColumn: caret.column, in: text)
        guard let range = misspellings(onLine: caret.line)
            .first(where: { NSLocationInRange(utf16, $0) || $0.location + $0.length == utf16 })
        else { return [] }
        return NSSpellChecker.shared.guesses(forWordRange: range, in: text,
                                             language: nil, inSpellDocumentWithTag: 0) ?? []
    }
}
