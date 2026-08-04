import AppKit
import MTextCore

/// Keyboard handling and input-method support.
extension EditorView {

    public override func keyDown(with event: NSEvent) {
        // Mid-composition (an IME candidate window is open), every keystroke belongs to
        // the input method, not the keymap engine — a plain `escape`/`enter`/`tab` (or
        // any function-row key some IMEs use for conversion mode) would otherwise be
        // eligible to match a user-defined binding and corrupt the composition instead
        // of reaching it. `context` predicates are intentionally unevaluated elsewhere
        // in this feature (see `KeymapParser`), but this one check is cheap and safe
        // regardless of what's loaded, so it isn't gated behind that same limitation.
        guard !hasMarkedText() else {
            interpretKeyEvents([event])
            return
        }
        switch keymapEngine.match(event) {
        case .command(let name, let args):
            onKeymapCommand?(name, args)
            return
        case .pendingChord:
            // Swallow the keystroke silently — same as AppKit's own menu system
            // swallows the first key of a would-be menu shortcut.
            return
        case .noMatch:
            break
        }
        interpretKeyEvents([event])
    }

    public override func doCommand(by selector: Selector) {
        // Autocomplete gets first refusal (T90): while the list is open, Tab/Enter commit,
        // Escape dismisses, and the arrows move the selection instead of the caret. The
        // popup never takes first responder, so this is the only place those keys can be
        // reinterpreted. `false` means "not consumed" — including for the movement keys,
        // which dismiss the list *and* still move the caret.
        if handleCompletionCommand(selector) { return }

        switch selector {

        // MARK: Insertion
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertLineBreak(_:)):
            insertNewlineWithIndent()
        case #selector(NSResponder.insertTab(_:)):
            insertTabOrIndent()
        case #selector(NSResponder.insertBacktab(_:)):
            // Shift-Tab steps *back* through snippet stops before it means outdent (T91).
            if retreatSnippet() { return }
            didEdit(newSelection: document.outdent(selection, using: indentUnit))

        // MARK: Deletion
        case #selector(NSResponder.deleteBackward(_:)):
            deleteBackwardHandlingPairs()
        case #selector(NSResponder.deleteForward(_:)):
            didEdit(newSelection: document.deleteForward(over: selection))
        case #selector(NSResponder.deleteWordBackward(_:)):
            didEdit(newSelection: document.deleteWordBackward(over: selection))
        case #selector(NSResponder.deleteWordForward(_:)):
            didEdit(newSelection: document.deleteWordForward(over: selection))
        case #selector(NSResponder.deleteToBeginningOfLine(_:)):
            deleteToLineEdge(start: true)
        case #selector(NSResponder.deleteToEndOfLine(_:)):
            deleteToLineEdge(start: false)

        // MARK: Horizontal movement
        case #selector(NSResponder.moveLeft(_:)):
            move(extend: false) { self.document.positionBefore($0.head) }
        case #selector(NSResponder.moveRight(_:)):
            move(extend: false) { self.document.positionAfter($0.head) }
        case #selector(NSResponder.moveLeftAndModifySelection(_:)):
            move(extend: true) { self.document.positionBefore($0.head) }
        case #selector(NSResponder.moveRightAndModifySelection(_:)):
            move(extend: true) { self.document.positionAfter($0.head) }

        // MARK: Word movement
        case #selector(NSResponder.moveWordLeft(_:)),
             #selector(NSResponder.moveWordBackward(_:)):
            move(extend: false) { self.document.wordBoundary(from: $0.head, forward: false) }
        case #selector(NSResponder.moveWordRight(_:)),
             #selector(NSResponder.moveWordForward(_:)):
            move(extend: false) { self.document.wordBoundary(from: $0.head, forward: true) }
        case #selector(NSResponder.moveWordLeftAndModifySelection(_:)),
             #selector(NSResponder.moveWordBackwardAndModifySelection(_:)):
            move(extend: true) { self.document.wordBoundary(from: $0.head, forward: false) }
        case #selector(NSResponder.moveWordRightAndModifySelection(_:)),
             #selector(NSResponder.moveWordForwardAndModifySelection(_:)):
            move(extend: true) { self.document.wordBoundary(from: $0.head, forward: true) }

        // MARK: Vertical movement
        case #selector(NSResponder.moveUp(_:)):
            moveVertically(by: -1, extend: false)
        case #selector(NSResponder.moveDown(_:)):
            moveVertically(by: 1, extend: false)
        case #selector(NSResponder.moveUpAndModifySelection(_:)):
            moveVertically(by: -1, extend: true)
        case #selector(NSResponder.moveDownAndModifySelection(_:)):
            moveVertically(by: 1, extend: true)
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)):
            moveVertically(by: -visibleLineCount, extend: false)
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)):
            moveVertically(by: visibleLineCount, extend: false)
        case #selector(NSResponder.pageUpAndModifySelection(_:)):
            moveVertically(by: -visibleLineCount, extend: true)
        case #selector(NSResponder.pageDownAndModifySelection(_:)):
            moveVertically(by: visibleLineCount, extend: true)

        // MARK: Line and document edges
        case #selector(NSResponder.moveToBeginningOfLine(_:)),
             #selector(NSResponder.moveToLeftEndOfLine(_:)):
            move(extend: false) { self.smartLineStart($0.head) }
        case #selector(NSResponder.moveToBeginningOfLineAndModifySelection(_:)),
             #selector(NSResponder.moveToLeftEndOfLineAndModifySelection(_:)):
            move(extend: true) { self.smartLineStart($0.head) }
        case #selector(NSResponder.moveToEndOfLine(_:)),
             #selector(NSResponder.moveToRightEndOfLine(_:)):
            move(extend: false) { Position(line: $0.head.line, column: self.document.lineLength($0.head.line)) }
        case #selector(NSResponder.moveToEndOfLineAndModifySelection(_:)),
             #selector(NSResponder.moveToRightEndOfLineAndModifySelection(_:)):
            move(extend: true) { Position(line: $0.head.line, column: self.document.lineLength($0.head.line)) }
        case #selector(NSResponder.moveToBeginningOfDocument(_:)):
            move(extend: false) { _ in .zero }
        case #selector(NSResponder.moveToBeginningOfDocumentAndModifySelection(_:)):
            move(extend: true) { _ in .zero }
        case #selector(NSResponder.moveToEndOfDocument(_:)):
            move(extend: false) { _ in self.document.endPosition }
        case #selector(NSResponder.moveToEndOfDocumentAndModifySelection(_:)):
            move(extend: true) { _ in self.document.endPosition }

        // MARK: Selection
        case #selector(NSResponder.selectAll(_:)):
            selectAll(nil)
        case #selector(NSResponder.selectWord(_:)):
            expandSelectionToWord(nil)
        case #selector(NSResponder.selectLine(_:)):
            expandSelectionToLine(nil)
        case #selector(NSResponder.cancelOperation(_:)):
            // Escape abandons the snippet first — leaving the text as it stands, which is
            // what you want after typing the parts you cared about (T91).
            if isSnippetActive {
                endSnippetSession()
                return
            }
            collapseToSingleCaret(nil)

        default:
            break // unhandled selectors are ignored on purpose (no beep)
        }
    }

    // MARK: - Movement helpers

    func move(extend: Bool, _ transform: @escaping (Region) -> Position) {
        didMoveSelection(document.moved(selection, extend: extend, transform: transform))
    }

    /// Home toggles between the first non-blank column and column 0.
    func smartLineStart(_ position: Position) -> Position {
        let firstNonBlank = document.firstNonBlankColumn(of: position.line)
        let target = position.column == firstNonBlank ? 0 : firstNonBlank
        return Position(line: position.line, column: target)
    }

    /// Vertical movement keeps a goal column per region, so travelling through a
    /// short line and back out returns to the original column.
    /// Up/down move by **visual row**, so a collapsed region counts as one step rather
    /// than as however many lines it hides (T92). With nothing folded this is exactly the
    /// old line arithmetic, since row == line.
    /// Position `delta` visual rows from `origin`, keeping `goalColumn` as the target
    /// column *within the destination row* — so moving down a wrapped line steps through its
    /// rows rather than jumping over the whole line (T28).
    func position(movedBy delta: Int, from origin: Position, goalColumn: Int) -> Position {
        let currentRow = rowMap.row(at: origin,
                                    lineProvider: { [document] in document.line($0) },
                                    tabSize: foldTabSize)
        let targetRow = max(0, min(rowMap.totalRows - 1, currentRow + delta))
        let location = rowMap.location(ofRow: targetRow)
        guard rowMap.isWrapping else {
            return document.clamp(Position(line: location.line, column: goalColumn))
        }
        let text = document.line(location.line)
        let breaks = wrapBreaks(forLine: location.line, text: text)
        let columns = WordWrapper.columnRange(ofRow: location.rowInLine, breaks: breaks,
                                              lineLength: text.count)
        // The goal column is measured from the *line's* start, so offset it into the
        // destination row and clamp to that row's span.
        let originBreaks = wrapBreaks(forLine: origin.line)
        let originRowStart = WordWrapper.columnRange(
            ofRow: WordWrapper.row(forColumn: origin.column, breaks: originBreaks),
            breaks: originBreaks,
            lineLength: document.lineLength(origin.line)).lowerBound
        let withinRow = max(0, goalColumn - originRowStart)
        let column = min(columns.lowerBound + withinRow, columns.upperBound)
        return document.clamp(Position(line: location.line, column: column))
    }

    func moveVertically(by delta: Int, extend: Bool) {
        var updated = selection
        updated.map { region in
            let goal = region.goalColumn ?? region.head.column
            let head = position(movedBy: delta, from: region.head, goalColumn: goal)
            return Region(anchor: extend ? region.anchor : head, head: head, goalColumn: goal)
        }
        didMoveSelection(updated)
    }

    // MARK: - Insertion helpers

    /// Newline that copies the current indentation, adds a level after an opening
    /// brace, and puts a closing brace on its own line when typed between a pair.
    func insertNewlineWithIndent() {
        var replacements: [String] = []
        /// True for regions typed between an opening and closing brace, where the
        /// caret must end up on the blank middle line rather than after the closer.
        var openedBlock: [Bool] = []

        for region in selection.regions {
            let lineIndex = region.start.line
            var indent = document.indentation(of: lineIndex)
            let before = prefix(of: lineIndex, upTo: region.start.column)
            let after = suffix(of: region.end.line, from: region.end.column)

            if let last = before.trimmingCharacters(in: .whitespaces).last,
               EditorView.openingBrackets.contains(last) {
                indent += indentUnit
                if let next = after.trimmingCharacters(in: .whitespaces).first,
                   EditorView.closingBrackets.contains(next) {
                    replacements.append("\n" + indent + "\n" + document.indentation(of: lineIndex))
                    openedBlock.append(true)
                    continue
                }
            }
            replacements.append("\n" + indent)
            openedBlock.append(false)
        }

        // Use the byte ranges directly: the inserted text for a block ends at column 0
        // of the closing-brace line, and the caret belongs at the end of the line above.
        let ranges = document.applyEdits(zip(selection.regions, replacements).map {
            RegionEdit(range: $0, text: $1)
        })
        let regions = zip(ranges, openedBlock).map { range, isBlock -> Region in
            let end = document.position(ofByteOffset: range.end)
            guard isBlock, end.line > 0 else { return Region(caret: end) }
            let middle = end.line - 1
            return Region(caret: Position(line: middle, column: document.lineLength(middle)))
        }
        didEdit(newSelection: Selection(regions: regions, primaryIndex: selection.primaryIndex))
    }

    /// Tab indents when a selection spans lines or there are multiple carets,
    /// otherwise inserts an indent unit.
    /// Tab means four different things depending on context, in this order (T91):
    /// move to the next snippet stop, expand a tab trigger, indent a multi-line selection,
    /// or insert an indent. The snippet cases come first because being inside a snippet is
    /// the most specific state — and because Sublime orders them the same way.
    func insertTabOrIndent() {
        if advanceSnippet() { return }
        if expandSnippetTrigger() { return }

        let spansLines = selection.regions.contains { $0.start.line != $0.end.line }
        if spansLines {
            didEdit(newSelection: document.indent(selection, using: indentUnit))
        } else {
            insertText(indentUnit, replacementRange: notFoundRange)
        }
    }

    /// Backspace deletes both halves of an empty auto-inserted pair.
    func deleteBackwardHandlingPairs() {
        let expanded: [Region] = selection.regions.map { region in
            guard region.isEmpty, region.head.column > 0 else { return region }
            let text = document.line(region.head.line)
            let characters = Array(text)
            let index = region.head.column - 1
            guard index < characters.count,
                  let closer = EditorView.pairs[characters[index]],
                  index + 1 < characters.count,
                  characters[index + 1] == closer
            else { return region }
            return Region(anchor: Position(line: region.head.line, column: index),
                          head: Position(line: region.head.line, column: index + 2))
        }
        let target = Selection(regions: expanded, primaryIndex: selection.primaryIndex)
        // T91: describe the deletion for the snippet session. An empty region deletes the
        // character *before* the caret, so the replaced range is derived from
        // `positionBefore` rather than from the region itself.
        if snippetSession != nil, !isApplyingSnippetMirrors, !target.isMultiple {
            let region = target.primary
            let lower = region.isEmpty
                ? document.byteOffset(of: document.positionBefore(region.head))
                : document.byteOffset(of: region.start)
            let upper = document.byteOffset(of: region.isEmpty ? region.head : region.end)
            pendingSnippetEdit = (lower ..< upper, 0)
        }
        didEdit(newSelection: document.deleteBackward(over: target))
        refreshCompletionsIfVisible()
    }

    func deleteToLineEdge(start: Bool) {
        let expanded: [Region] = selection.regions.map { region in
            let lineIndex = region.head.line
            return start
                ? Region(anchor: Position(line: lineIndex, column: 0), head: region.head)
                : Region(anchor: region.head,
                         head: Position(line: lineIndex, column: document.lineLength(lineIndex)))
        }
        let target = Selection(regions: expanded, primaryIndex: selection.primaryIndex)
        didEdit(newSelection: document.replace(target, withEach: ""))
    }

    func prefix(of lineIndex: Int, upTo column: Int) -> String {
        let text = document.line(lineIndex)
        return String(text.prefix(max(0, min(column, text.count))))
    }

    func suffix(of lineIndex: Int, from column: Int) -> String {
        let text = document.line(lineIndex)
        return String(text.dropFirst(max(0, min(column, text.count))))
    }

    // MARK: - Bracket pairing

    static let pairs: [Character: Character] = [
        "(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`",
    ]
    static let openingBrackets: Set<Character> = ["(", "[", "{"]
    static let closingBrackets: Set<Character> = [")", "]", "}"]

    /// Returns the text to insert for each region, applying auto-pairing rules,
    /// or nil when the input needs no special treatment.
    func autoPairedReplacements(for input: String) -> [String]? {
        guard input.count == 1, let character = input.first else { return nil }

        if let closer = EditorView.pairs[character] {
            return selection.regions.map { region in
                region.isEmpty
                    ? String(character) + String(closer)          // type the pair
                    : String(character) + document.text(in: region) + String(closer) // wrap
            }
        }
        return nil
    }

    /// True when typing `character` should just step over an existing closer.
    func shouldStepOverCloser(_ character: Character) -> Bool {
        guard EditorView.pairs.values.contains(character) else { return false }
        return selection.regions.allSatisfy { region in
            guard region.isEmpty else { return false }
            let text = document.line(region.head.line)
            let characters = Array(text)
            return region.head.column < characters.count && characters[region.head.column] == character
        }
    }

    // MARK: - NSTextInputClient
    //
    // The character space handed to the input system is UTF-16 offsets within the
    // primary caret's line. That is self-consistent across markedRange /
    // selectedRange / firstRect / characterIndex, which is what multi-stage IMEs
    // (Telex, Kotoeri, Pinyin) need to place their candidate window. A document-wide
    // UTF-16 index would need its own index structure — deferred (T16).

    var notFoundRange: NSRange { NSRange(location: NSNotFound, length: 0) }

    var caretUTF16Offset: Int {
        let head = selection.primary.head
        return utf16Offset(ofColumn: head.column, in: document.line(head.line))
    }

    public func insertText(_ string: Any, replacementRange: NSRange) {
        let input = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        deleteMarkedText()
        guard !input.isEmpty else { return }

        // T90. `defer` because this method returns from several branches (step-over-closer,
        // auto-pair, plain insert) and all of them are typing. Deliberately hooked here
        // rather than in `didEdit`, which also runs for paste, line transforms, undo and
        // Replace All — a completion list popping up after "Sort Lines" would be nonsense.
        defer { updateCompletionsAfterEdit() }

        if let character = input.first, input.count == 1, shouldStepOverCloser(character) {
            move(extend: false) { self.document.positionAfter($0.head) }
            return
        }

        if let paired = autoPairedReplacements(for: input) {
            let wrapped = selection.hasSelectedText
            let result = document.replace(selection, with: paired)
            if wrapped {
                didEdit(newSelection: result)
            } else {
                // Land the caret between the two halves.
                var inner = result
                inner.map { Region(caret: self.document.positionBefore($0.head)) }
                didEdit(newSelection: inner)
            }
            return
        }

        // T91: the one insertion path that can describe its own edit precisely — plain
        // typing over the current selection. The auto-pair and step-over-closer branches
        // above deliberately don't, so using them inside a snippet ends the session rather
        // than rebasing stops against an edit whose real length differs from `input`.
        if snippetSession != nil, !isApplyingSnippetMirrors, !selection.isMultiple {
            let start = document.byteOffset(of: selection.primary.start)
            let end = document.byteOffset(of: selection.primary.end)
            pendingSnippetEdit = (start ..< end, input.utf8.count)
        }
        didEdit(newSelection: document.insert(input, over: selection))
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let input = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        deleteMarkedText()
        // Composition applies to the primary caret only.
        var single = selection
        single.collapseToPrimary()
        let anchor = document.byteOffset(of: single.primary.head)
        let result = document.insert(input, over: single)
        markedText = input
        markedStart = input.isEmpty ? nil : anchor
        didEdit(newSelection: result)
    }

    public func unmarkText() {
        markedText = ""
        markedStart = nil
    }

    func deleteMarkedText() {
        defer {
            markedText = ""
            markedStart = nil
        }
        guard !markedText.isEmpty, let anchor = markedStart else { return }
        let start = document.position(ofByteOffset: anchor)
        let head = selection.primary.head
        guard start < head else { return }
        let removed = document.delete(from: start, to: head)
        selection = Selection(caret: removed)
    }

    public func hasMarkedText() -> Bool { !markedText.isEmpty }

    public func markedRange() -> NSRange {
        guard hasMarkedText() else { return notFoundRange }
        let length = markedText.utf16.count
        return NSRange(location: max(0, caretUTF16Offset - length), length: length)
    }

    public func selectedRange() -> NSRange {
        let region = selection.primary
        guard !region.isEmpty, region.start.line == region.end.line else {
            return NSRange(location: caretUTF16Offset, length: 0)
        }
        let text = document.line(region.start.line)
        let from = utf16Offset(ofColumn: region.start.column, in: text)
        let to = utf16Offset(ofColumn: region.end.column, in: text)
        return NSRange(location: from, length: max(0, to - from))
    }

    public func attributedSubstring(forProposedRange range: NSRange,
                                    actualRange: NSRangePointer?) -> NSAttributedString? {
        let text = document.line(selection.primary.head.line)
        let utf16 = text.utf16
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
              range.location <= utf16.count, range.length <= utf16.count - range.location,
              let start = utf16.index(utf16.startIndex, offsetBy: range.location, limitedBy: utf16.endIndex),
              let end = utf16.index(start, offsetBy: range.length, limitedBy: utf16.endIndex),
              let from = start.samePosition(in: text),
              let to = end.samePosition(in: text)
        else { return nil }
        actualRange?.pointee = range
        return NSAttributedString(string: String(text[from ..< to]))
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// Screen rect of the range's first character, so the IME candidate window
    /// appears under the text being composed rather than under the caret.
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        let head = selection.primary.head
        let text = document.line(head.line)
        var rect = caretRect(for: head)
        if range.location != NSNotFound, range.location <= text.utf16.count {
            let col = column(fromUTF16: range.location, in: text)
            rect = NSRect(x: xOffset(ofColumn: col, line: head.line),
                          y: rect.origin.y, width: 1.5, height: lineHeight)
            actualRange?.pointee = NSRange(location: range.location, length: 0)
        }
        return window.convertToScreen(convert(rect, to: nil))
    }

    public func characterIndex(for point: NSPoint) -> Int {
        let local = convert(window?.convertPoint(fromScreen: point) ?? point, from: nil)
        let p = position(at: local)
        // The documented index space is the primary caret's line; a point on any
        // other line has no representable index here.
        guard p.line == selection.primary.head.line else { return NSNotFound }
        return utf16Offset(ofColumn: p.column, in: document.line(p.line))
    }
}
