import AppKit
import MTextCore

// T90 — autocomplete: buffer words plus indexed symbols, fuzzy ranked, in an inline popup.
//
// The popup never takes first responder (see `CompletionPopup`), so every key that drives
// it arrives here first, in the editor. That is what lets Tab/Enter/Escape/arrows mean
// something different while the list is up without installing a second event monitor or
// fighting the responder chain.
extension EditorView {

    /// Shortest prefix that opens the list *by itself*. One character matches nearly every
    /// word in the buffer, so the list would be noise and would pop up constantly;
    /// ⌃Space still forces it open at any length, including zero.
    static let minimumAutoTriggerPrefix = 2

    var isCompletionVisible: Bool { completionPopup?.isVisible ?? false }

    // MARK: - Keeping the word index fresh

    /// How long editing must pause before the buffer is rescanned for completion words.
    /// Long enough that a burst of typing rescans once at the end rather than repeatedly,
    /// short enough that a word is offered by the time anyone could want to complete it.
    static let bufferWordRefreshDelay: TimeInterval = 0.4

    /// Rescans the buffer for completion words once editing goes quiet.
    ///
    /// Called from `didEdit`, but the scan itself deliberately happens *later*, on a timer:
    /// it is O(buffer) and used to run inside the keypress, which made typing in a large
    /// file stall on every character (see `BufferWordIndex`). Each edit pushes the timer
    /// back, so continuous typing costs nothing and the rescan lands in the pause after it.
    func scheduleBufferWordRefresh() {
        bufferWordRefreshTimer?.invalidate()
        guard autoCompleteEnabled else { return }
        bufferWordRefreshTimer = Timer.scheduledTimer(
            withTimeInterval: EditorView.bufferWordRefreshDelay, repeats: false
        ) { [weak self] _ in
            guard let self else { return }
            if self.bufferWordIndex.isStale(for: self.document) {
                self.bufferWordIndex.refresh(in: self.document)
            }
            if self.cachedCompletionSymbolsGeneration != self.document.generation {
                self.refreshCompletionSymbols()
            }
        }
    }

    // MARK: - Triggering

    /// Called after any edit that could change what should be offered. Re-queries when the
    /// caret is in a word long enough to auto-trigger, and otherwise dismisses — an open
    /// list that no longer relates to what's being typed is worse than none.
    func updateCompletionsAfterEdit() {
        guard autoCompleteEnabled, !hasMarkedText() else {
            hideCompletions()
            return
        }
        // Multi-caret typing has no single prefix to complete, and committing would have to
        // pick one caret's word to apply everywhere. Sublime declines here too.
        guard !selection.isMultiple, selection.primary.isEmpty else {
            hideCompletions()
            return
        }
        let prefix = CompletionEngine.prefix(in: document, before: selection.primary.head)
        guard prefix.count >= EditorView.minimumAutoTriggerPrefix else {
            // Out of a word entirely (typed a space, a bracket, a newline): the next word
            // is a fresh start, so an earlier Escape stops applying.
            if prefix.isEmpty { suppressedCompletionWord = nil }
            hideCompletions()
            return
        }
        // Escape suppresses the list for the word it was pressed in, *and* for anything
        // that word grows into — dismissing at "col" then typing "our" should stay
        // dismissed rather than popping back up on the next keystroke. Starting a
        // different word (cleared above) or asking explicitly with ⌃Space overrides it.
        if let suppressed = suppressedCompletionWord, prefix.hasPrefix(suppressed) { return }
        showCompletions(prefix: prefix)
    }

    /// Deletion path: keeps an open list in step with a shrinking word, but never *opens*
    /// one. Backspacing is how you get out of a bad completion; having the list appear
    /// because of it would be the opposite of helpful.
    func refreshCompletionsIfVisible() {
        guard isCompletionVisible else { return }
        updateCompletionsAfterEdit()
    }

    /// ⌃Space — force the list open regardless of prefix length, and clear any Escape
    /// suppression, since asking for it explicitly overrides having dismissed it.
    @objc public func showCompletions(_ sender: Any?) {
        guard !hasMarkedText(), !selection.isMultiple, selection.primary.isEmpty else { return }
        suppressedCompletionWord = nil
        showCompletions(prefix: CompletionEngine.prefix(in: document, before: selection.primary.head))
    }

    private func showCompletions(prefix: String) {
        guard let window else { return }
        let items = CompletionEngine.complete(
            prefix: prefix,
            bufferWords: bufferWordIndex.words(in: document),
            symbols: completionSymbols()
        )
        guard !items.isEmpty else {
            hideCompletions()
            return
        }

        let popup = ensureCompletionPopup()
        // The caret rect is in document coordinates; the popup positions in screen
        // coordinates, so it goes through the view and the window in turn.
        let caret = caretRect(for: selection.primary.head)
        let inWindow = convert(caret, to: nil)
        let onScreen = window.convertToScreen(inWindow)
        popup.show(items: items, over: window, anchor: onScreen)
    }

    func hideCompletions() {
        completionPopup?.hide()
    }

    /// Current-file symbols, plus whatever the window controller contributes from the
    /// project index.
    ///
    /// Never *starts* a project index: this runs on the keystroke path, and kicking off a
    /// project-wide symbol walk from a keypress is exactly the kind of thing that makes
    /// typing stutter. Whatever the index already holds is offered; anything else isn't.
    /// That reasoning applied just as much to extracting *this file's* symbols, which used
    /// to happen here on every keystroke — hence the cache below.
    private func completionSymbols() -> [CompletionItem] {
        // Extracted on the idle timer, not here: this walks the whole document, and doing
        // it per keystroke cost ~85 ms a key in a 20k-line file — the same stall
        // `BufferWordIndex` describes, in the same feature. Only the first use scans
        // inline, so a list asked for before the timer has ever fired isn't empty.
        if cachedCompletionSymbolsGeneration == nil { refreshCompletionSymbols() }
        var items = cachedCompletionSymbols
        items.append(contentsOf: onCompletionSymbols?() ?? [])
        return items
    }

    func refreshCompletionSymbols() {
        cachedCompletionSymbols = SymbolExtractor
            .extractSymbols(from: document, grammar: highlightService.grammar)
            .map { CompletionItem(text: $0.name, kind: .symbol, detail: "line \($0.line + 1)") }
        cachedCompletionSymbolsGeneration = document.generation
    }

    private func ensureCompletionPopup() -> CompletionPopup {
        if let completionPopup { return completionPopup }
        let popup = CompletionPopup()
        popup.onCommit = { [weak self] item in self?.commitCompletion(item) }
        completionPopup = popup
        return popup
    }

    // MARK: - Committing

    /// Replaces the word being typed with `item.text`.
    ///
    /// Selects the prefix and replaces it, rather than inserting the remainder after the
    /// caret, so a fuzzy match works: completing `sfn` to `someFunctionName` has to
    /// rewrite what was typed, not append to it.
    func commitCompletion(_ item: CompletionItem) {
        defer { hideCompletions() }
        guard !selection.isMultiple else { return }
        let head = selection.primary.head
        let prefix = CompletionEngine.prefix(in: document, before: head)
        guard head.column >= prefix.count else { return }

        let start = Position(line: head.line, column: head.column - prefix.count)
        let wordRegion = Selection(regions: [Region(anchor: start, head: head)])
        // `replace(_:withEach:)` rather than `insert`: the prefix has to go.
        didEdit(newSelection: document.replace(wordRegion, withEach: item.text))
        // Committing ends this completion session. Without clearing suppression, the very
        // next character typed inside the freshly inserted word would be compared against
        // a stale suppressed word.
        suppressedCompletionWord = nil
    }

    /// Returns true when the popup consumed the command, so `doCommand(by:)` knows not to
    /// also run the editor's normal behaviour for that key.
    func handleCompletionCommand(_ selector: Selector) -> Bool {
        guard isCompletionVisible, let popup = completionPopup else { return false }

        switch selector {
        case #selector(NSResponder.insertTab(_:)):
            if let item = popup.selectedItem { commitCompletion(item) }
            return true

        case #selector(NSResponder.insertNewline(_:)):
            // Enter commits, matching Sublime's default. The cost is that a deliberate
            // newline typed while the list happens to be open inserts a word instead —
            // which is why Escape dismissing is important and why the auto-trigger
            // threshold isn't 1.
            if let item = popup.selectedItem { commitCompletion(item) }
            return true

        case #selector(NSResponder.cancelOperation(_:)):
            // Remember which word was dismissed so typing on doesn't immediately reopen
            // the list for the same word — but a *different* word still triggers.
            suppressedCompletionWord = CompletionEngine.prefix(in: document,
                                                               before: selection.primary.head)
            hideCompletions()
            return true

        case #selector(NSResponder.moveUp(_:)):
            popup.moveSelection(by: -1)
            return true

        case #selector(NSResponder.moveDown(_:)):
            popup.moveSelection(by: 1)
            return true

        // Any caret movement other than the list navigation above means the user has left
        // the word behind; the list stops being about anything.
        case #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveRight(_:)),
             #selector(NSResponder.moveToBeginningOfLine(_:)),
             #selector(NSResponder.moveToEndOfLine(_:)),
             #selector(NSResponder.moveToBeginningOfDocument(_:)),
             #selector(NSResponder.moveToEndOfDocument(_:)),
             #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.scrollPageDown(_:)):
            hideCompletions()
            return false // let the movement itself still happen

        default:
            return false
        }
    }
}
