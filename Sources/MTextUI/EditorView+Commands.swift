import AppKit
import MTextCore

/// Menu- and shortcut-driven commands. Every one is an `@objc` action so it can be
/// reached through the responder chain — the same entry point a command palette and
/// keymap engine will use in Phase 5.
extension EditorView {

    // MARK: - History

    @objc public func undo(_ sender: Any?) {
        guard let caret = document.undo() else { return }
        afterHistoryChange(caret)
    }

    @objc public func redo(_ sender: Any?) {
        guard let caret = document.redo() else { return }
        afterHistoryChange(caret)
    }

    private func afterHistoryChange(_ caret: Position) {
        markedText = ""
        markedStart = nil
        layout.invalidateAll()
        selection = Selection(caret: document.clamp(caret))
        // Undo can change any line, so re-highlight from the top rather than paint the
        // restored text with spans computed from the pre-undo content.
        highlightingDidEdit(fromLine: 0)
        updateBracketMatch()
        searchDidEdit()
        updateFrameSize()
        caretVisible = true
        needsDisplay = true
        scrollToPrimaryCaret()
        onChange?()
    }

    // MARK: - Clipboard

    /// Multi-cursor copy keeps one line per region, so pasting back into the same
    /// number of carets distributes the pieces (Sublime's behaviour).
    @objc public func copy(_ sender: Any?) {
        let pieces = document.texts(in: selection).filter { !$0.isEmpty }
        guard !pieces.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(pieces.joined(separator: "\n"), forType: .string)
    }

    @objc public func cut(_ sender: Any?) {
        guard selection.hasSelectedText else { return }
        copy(sender)
        didEdit(newSelection: document.replace(selection, withEach: ""))
    }

    @objc public func paste(_ sender: Any?) {
        guard let clipboard = NSPasteboard.general.string(forType: .string) else { return }

        // One clipboard line per caret → distribute; otherwise insert it whole
        // at every caret.
        let pieces = clipboard.components(separatedBy: "\n")
        if selection.isMultiple, pieces.count == selection.count {
            didEdit(newSelection: document.replace(selection, with: pieces))
        } else {
            didEdit(newSelection: document.replace(selection, withEach: clipboard))
        }
    }

    @objc public func delete(_ sender: Any?) {
        didEdit(newSelection: document.deleteForward(over: selection))
    }

    // MARK: - Selection

    // NSResponder picks up selectAll: from NSStandardKeyBindingResponding, so this
    // is an override rather than a new method.
    @objc public override func selectAll(_ sender: Any?) {
        didMoveSelection(Selection(Region(anchor: .zero, head: document.endPosition)), scroll: false)
    }

    @objc public func collapseToSingleCaret(_ sender: Any?) {
        var updated = selection
        updated.collapseToPrimary()
        didMoveSelection(updated)
    }

    @objc public func expandSelectionToWord(_ sender: Any?) {
        var updated = selection
        updated.map { region in
            region.isEmpty ? document.wordRange(at: region.head) : region
        }
        didMoveSelection(updated)
    }

    /// ⌘L — expand each region to whole lines, extending by one line if already there.
    @objc public func expandSelectionToLine(_ sender: Any?) {
        var updated = selection
        updated.map { region in
            let start = Position(line: region.start.line, column: 0)
            var endLine = region.end.line
            if region.start == start, region.end == self.lineStart(after: endLine) {
                endLine += 1 // already whole lines: take one more
            }
            return Region(anchor: start, head: self.lineStart(after: endLine))
        }
        didMoveSelection(updated)
    }

    private func lineStart(after lineIndex: Int) -> Position {
        lineIndex + 1 < document.lineCount
            ? Position(line: lineIndex + 1, column: 0)
            : Position(line: lineIndex, column: document.lineLength(lineIndex))
    }

    /// ⌘D — select the word under the caret, or add the next occurrence of the
    /// current selection as an extra cursor.
    @objc public func selectNextOccurrence(_ sender: Any?) {
        guard selection.hasSelectedText else {
            expandSelectionToWord(sender)
            lastSearchNeedle = document.text(in: selection.primary)
            return
        }
        let needle = document.text(in: selection.primary)
        guard !needle.isEmpty else { return }
        lastSearchNeedle = needle

        let searchFrom = selection.regions.map(\.end).max() ?? selection.primary.end
        guard let match = document.findNext(needle, after: searchFrom) else { return }
        guard !selection.regions.contains(match) else { return }

        var updated = selection
        updated.add(match)
        didMoveSelection(updated)
    }

    /// ⌥F3 / ⌃⌘G — one cursor at every occurrence.
    @objc public func selectAllOccurrences(_ sender: Any?) {
        let needle = selection.hasSelectedText
            ? document.text(in: selection.primary)
            : document.text(in: document.wordRange(at: selection.primary.head))
        guard !needle.isEmpty else { return }
        lastSearchNeedle = needle

        let matches = document.findAll(needle)
        guard !matches.isEmpty else { return }
        didMoveSelection(Selection(regions: matches, primaryIndex: matches.count - 1))
    }

    /// ⇧⌘L — one cursor at the end of every line the selection touches.
    @objc public func splitSelectionIntoLines(_ sender: Any?) {
        var regions: [Region] = []
        for region in selection.regions {
            if region.isEmpty {
                regions.append(region)
                continue
            }
            for lineIndex in region.start.line ... region.end.line {
                let from = lineIndex == region.start.line ? region.start.column : 0
                let to = lineIndex == region.end.line
                    ? region.end.column
                    : document.lineLength(lineIndex)
                regions.append(Region(anchor: Position(line: lineIndex, column: from),
                                      head: Position(line: lineIndex, column: to)))
            }
        }
        didMoveSelection(Selection(regions: regions, primaryIndex: regions.count - 1))
    }

    /// ⌃⇧↑ / ⌃⇧↓ — add a caret on the line above or below.
    @objc public func addCaretAbove(_ sender: Any?) { addCaret(delta: -1) }
    @objc public func addCaretBelow(_ sender: Any?) { addCaret(delta: 1) }

    private func addCaret(delta: Int) {
        let source = delta < 0
            ? selection.regions.map(\.head).min()
            : selection.regions.map(\.head).max()
        guard let head = source else { return }
        let targetLine = head.line + delta
        guard targetLine >= 0, targetLine < document.lineCount else { return }

        var updated = selection
        updated.add(Region(caret: document.clamp(Position(line: targetLine, column: head.column))))
        didMoveSelection(updated)
    }

    /// ⌘E — use the selected text as the find query.
    @objc public func useSelectionForFind(_ sender: Any?) {
        let needle = document.text(in: selection.primary)
        guard !needle.isEmpty else { return }
        lastSearchNeedle = needle
        searchSession.setQuery(.literal(needle), near: selection.primary.start)
        onFindSeedText?(needle)
        refreshFindStatus()
        needsDisplay = true
    }

    // MARK: - Line transforms

    @objc public func moveLineUp(_ sender: Any?) {
        didEdit(newSelection: document.moveLines(selection, up: true))
    }

    @objc public func moveLineDown(_ sender: Any?) {
        didEdit(newSelection: document.moveLines(selection, up: false))
    }

    @objc public func duplicateLine(_ sender: Any?) {
        didEdit(newSelection: document.duplicateLines(selection))
    }

    @objc public func joinLines(_ sender: Any?) {
        didEdit(newSelection: document.joinLines(selection))
    }

    @objc public func deleteLine(_ sender: Any?) {
        didEdit(newSelection: document.deleteLines(selection))
    }

    @objc public func sortLines(_ sender: Any?) {
        didEdit(newSelection: document.sortLines(selection))
    }

    @objc public func sortLinesCaseInsensitive(_ sender: Any?) {
        didEdit(newSelection: document.sortLines(selection, caseSensitive: false))
    }

    @objc public func reverseLines(_ sender: Any?) {
        didEdit(newSelection: document.reverseLines(selection))
    }

    @objc public func uniqueLines(_ sender: Any?) {
        didEdit(newSelection: document.uniqueLines(selection))
    }

    // MARK: - Case

    @objc public func uppercaseSelection(_ sender: Any?) {
        didEdit(newSelection: document.upperCase(selection))
    }

    @objc public func lowercaseSelection(_ sender: Any?) {
        didEdit(newSelection: document.lowerCase(selection))
    }

    @objc public func titlecaseSelection(_ sender: Any?) {
        didEdit(newSelection: document.titleCase(selection))
    }

    @objc public func swapCaseSelection(_ sender: Any?) {
        didEdit(newSelection: document.swapCase(selection))
    }

    // MARK: - Indentation and comments

    @objc public func indentSelection(_ sender: Any?) {
        didEdit(newSelection: document.indent(selection, using: indentUnit))
    }

    @objc public func outdentSelection(_ sender: Any?) {
        didEdit(newSelection: document.outdent(selection, using: indentUnit))
    }

    @objc public func toggleComment(_ sender: Any?) {
        didEdit(newSelection: document.toggleLineComment(selection, token: commentToken))
    }

    /// Line-comment token: from the active grammar when it declares one, otherwise
    /// guessed from the file extension.
    var commentToken: String {
        if let token = grammarCommentToken, !token.isEmpty { return token }
        switch document.fileURL?.pathExtension.lowercased() {
        case "py", "rb", "sh", "bash", "zsh", "yml", "yaml", "toml", "conf": return "#"
        case "sql", "lua", "hs": return "--"
        case "lisp", "clj", "el": return ";"
        default: return "//"
        }
    }

    // MARK: - View

    // These write into the *view* settings layer (T86) rather than assigning the property
    // directly. Assigning directly still worked, but the next settings-file reload
    // re-resolved the stack and silently undid the toggle; recorded as an override, the
    // view layer sits at the top of the stack and survives.

    @objc public func toggleGutter(_ sender: Any?) {
        setViewOverride("line_numbers", .bool(!showsGutter))
    }

    @objc public func toggleInvisibles(_ sender: Any?) {
        setViewOverride("draw_white_space", .bool(!showsInvisibles))
    }

    /// T28 — a view override like the other View-menu toggles, so a settings reload doesn't
    /// silently switch wrapping back.
    @objc public func toggleWordWrap(_ sender: Any?) {
        setViewOverride("word_wrap", .bool(!wordWrapEnabled))
    }

    /// T93 — same pattern for the minimap.
    @objc public func toggleMinimap(_ sender: Any?) {
        setViewOverride("minimap", .bool(!minimapEnabled))
    }

    // Font zoom is a view override for the same reason. It deliberately overrides only
    // `font_size` and leaves `font_face` alone, so zooming no longer discards a
    // `font_face` chosen in settings the way assigning `monospacedSystemFont` here did.

    @objc public func increaseFontSize(_ sender: Any?) {
        setViewOverride("font_size", .double(Double(min(48, font.pointSize + 1))))
    }

    @objc public func decreaseFontSize(_ sender: Any?) {
        setViewOverride("font_size", .double(Double(max(7, font.pointSize - 1))))
    }

    /// Back to whatever the settings stack says, which is not necessarily 13pt any more —
    /// so this clears the override rather than assigning a hardcoded size.
    @objc public func resetFontSize(_ sender: Any?) {
        viewOverrides.removeValue(forKey: "font_size")
        onViewOverridesChanged?()
    }

    // MARK: - Validation

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(EditorView.undo(_:)):
            return document.canUndo
        case #selector(EditorView.redo(_:)):
            return document.canRedo
        case #selector(EditorView.paste(_:)):
            return NSPasteboard.general.string(forType: .string) != nil
        case #selector(EditorView.copy(_:)), #selector(EditorView.cut(_:)):
            return selection.hasSelectedText
        case #selector(EditorView.findNextMatch(_:)), #selector(EditorView.findPreviousMatch(_:)):
            return !searchSession.isEmpty || lastSearchNeedle != nil || selection.hasSelectedText
        case #selector(EditorView.selectAllMatches(_:)):
            return !searchSession.isEmpty
        case #selector(EditorView.collapseToSingleCaret(_:)):
            return selection.isMultiple || selection.hasSelectedText
        case #selector(EditorView.toggleGutter(_:)):
            menuItem.state = showsGutter ? .on : .off
            return true
        case #selector(EditorView.toggleInvisibles(_:)):
            menuItem.state = showsInvisibles ? .on : .off
            return true
        case #selector(EditorView.toggleWordWrap(_:)):
            menuItem.state = wordWrapEnabled ? .on : .off
            return true
        case #selector(EditorView.toggleSpellCheck(_:)):
            menuItem.state = spellCheckEnabled ? .on : .off
            return true
        case #selector(EditorView.nextMisspelling(_:)):
            return spellCheckEnabled
        case #selector(EditorView.revertHunk(_:)):
            return canRevertHunk
        case #selector(EditorView.toggleMacroRecording(_:)):
            // The title carries the state, so there is no need for a checkmark or a second
            // menu item (T94).
            menuItem.title = EditorView.macroRecorder.isRecording ? "Stop Recording Macro" : "Record Macro"
            return true
        case #selector(EditorView.playbackMacro(_:)):
            return EditorView.lastMacro?.isEmpty == false
        case #selector(EditorView.toggleMinimap(_:)):
            menuItem.state = minimapEnabled ? .on : .off
            return true
        case #selector(EditorView.showCompletions(_:)):
            // Mirrors the guards in `showCompletions(_:)` itself, so the menu greys out
            // instead of offering a command that would silently do nothing (T90).
            return !selection.isMultiple && selection.primary.isEmpty && !hasMarkedText()
        default:
            return true
        }
    }
}
