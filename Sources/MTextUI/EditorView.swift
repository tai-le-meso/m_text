import AppKit
import CoreText
import MTextCore

/// The editor surface: a CALayer-backed `NSView` that draws text, selections,
/// carets and the line-number gutter itself with CoreText. No `NSTextView`.
///
/// Split across files: this one holds state, geometry and drawing;
/// `EditorView+Input` handles the keyboard and input methods,
/// `EditorView+Mouse` pointer selection, `EditorView+Commands` the edit commands.
public final class EditorView: NSView, NSTextInputClient, NSMenuItemValidation {

    // MARK: - Model

    public let document = TextDocument()
    public var onChange: (() -> Void)?

    /// Every caret and selected range. Never empty.
    var selection = Selection(caret: .zero) {
        didSet { if selection != oldValue { needsDisplay = true } }
    }

    /// Text currently being composed by an input method, and the byte offset it
    /// started at (a combining mark can occupy zero columns, so a Position won't do).
    var markedText = ""
    var markedStart: Int?

    /// Needle for ⌘D / ⌘G, remembered across invocations.
    var lastSearchNeedle: String?

    // MARK: - Syntax

    let highlightService = HighlightService()
    var grammarRegistry: GrammarRegistry?
    var colorScheme = ColorScheme.builtInDefault()
    /// Bold/italic variants of `font`, keyed by trait bitmask.
    var styledFonts: [Int: NSFont] = [:]
    var matchedBrackets: BracketMatcher.MatchResult?
    /// False once the user picks a syntax by hand. Reset whenever the document is
    /// replaced, so opening a new file detects afresh. Lives here rather than in the
    /// window controller because the `text` setter also replaces the document.
    ///
    /// `internal(set)`, not `private(set)`: `setGrammar` lives in EditorView+Highlighting,
    /// and `private` is file-scoped even for extensions on the same type.
    public internal(set) var autoDetectsSyntax = true
    /// `document.byteCount` the last time content-based detection ran, so `didEdit`
    /// isn't re-sniffing the whole buffer on every single keystroke. See
    /// `attemptContentBasedDetection()` in EditorView+Highlighting.swift.
    var lastContentSniffLength = 0

    // MARK: - Find

    /// Lazily created so the session can hold an unowned reference to `document`.
    var cachedSearchSession: SearchSession?
    /// Set by the window controller: asks it to show the find bar (true = with replace).
    public var onFindRequested: ((Bool) -> Void)?
    /// Asks the find bar to adopt this text as the query.
    public var onFindSeedText: ((String) -> Void)?
    /// Reports match status back to the find bar: text, and whether it is an error.
    public var onFindStatusChanged: ((String?, Bool) -> Void)?

    // MARK: - Keymap

    /// One engine per editor, matching how `selection`/`document` are also per-editor —
    /// its pending-chord state is inherently per-keystroke-stream, so sharing a single
    /// instance across tabs could let a chord begun in one tab complete after switching
    /// to another. Loaded once, right after creation, by `MainWindowController`.
    let keymapEngine = KeymapEngine()
    /// Fired when `keymapEngine` resolves a full chord to a command name — the window
    /// controller looks the name up via `KeymapCommands` and dispatches it.
    public var onKeymapCommand: ((String, [String: Any]?) -> Void)?

    // MARK: - Appearance

    var font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular) {
        didSet { fontDidChange() }
    }
    public var showsGutter = true {
        didSet {
            updateFrameSize()
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    public var showsInvisibles = false { didSet { needsDisplay = true } }
    public var rulerColumns: [Int] = [] { didSet { needsDisplay = true } }
    public var highlightsCurrentLine = true { didSet { needsDisplay = true } }
    public var indentUnit = "    "

    // MARK: - Settings (T86)

    /// The **view** layer — the top of the settings stack, holding only what this
    /// specific view has overridden by menu command (View ▸ Show Line Numbers, and so
    /// on). Kept as settings rather than as bare `showsGutter` mutation so a settings
    /// file reload re-resolves *through* these instead of overwriting them: toggling the
    /// gutter off and then saving the user settings file must not turn it back on.
    var viewOverrides: [String: SettingValue] = [:]

    /// Fired when `viewOverrides` changes, so the window controller can re-resolve the
    /// whole stack for this editor and apply the result. The editor cannot do this
    /// itself — it has no access to the user/syntax/project layers.
    public var onViewOverridesChanged: (() -> Void)?

    // MARK: - Autocomplete (T90)

    /// Created on first use rather than per editor up front — every tab has an
    /// `EditorView`, and a session restore can open dozens at once, none of which need a
    /// floating panel until someone types in them.
    var completionPopup: CompletionPopup?
    /// Buffer words for this document. Rescanned on an idle timer, never during an edit —
    /// see `scheduleBufferWordRefresh()`.
    let bufferWordIndex = BufferWordIndex()
    /// Pending idle rescan of the completion caches, pushed back by each further edit.
    var bufferWordRefreshTimer: Timer?
    /// This file's symbols, offered alongside buffer words. Extracting them walks the whole
    /// document, so — like `bufferWordIndex` — it is refreshed on the idle timer and never
    /// during a keystroke. `nil` generation means "never extracted", which forces one.
    var cachedCompletionSymbols: [CompletionItem] = []
    var cachedCompletionSymbolsGeneration: UInt64?
    /// The word Escape was pressed in, so typing on doesn't immediately reopen the list.
    /// Cleared when a new word starts, on commit, and by an explicit ⌃Space.
    var suppressedCompletionWord: String?
    /// `auto_complete` from the settings stack (T86).
    public var autoCompleteEnabled = true {
        didSet { if !autoCompleteEnabled { hideCompletions() } }
    }
    /// Extra candidates from outside this document — the window controller supplies
    /// project symbols from `SymbolIndex`. Returns only what is already indexed; this is
    /// on the keystroke path and must never start a walk.
    public var onCompletionSymbols: (() -> [CompletionItem])?

    // MARK: - Folding (T92)

    /// Which regions are collapsed. Every geometry helper consults this, because once
    /// anything is folded a document line is no longer the same thing as a screen row.
    var folds = FoldSet() {
        didSet {
            guard folds != oldValue else { return }
            rowMap.setFolds(folds)
            layout.invalidateAll()
            updateFrameSize()
            needsDisplay = true
        }
    }

    /// Line count as of the last `didEdit`, so the next one can tell how many lines an
    /// edit added or removed and shift folds to match. `didEdit` only receives the
    /// resulting selection, so the delta has to be remembered rather than derived.
    var lastKnownLineCount = 1

    // MARK: - Phantoms (T103)

    /// Inline annotations shown between lines. Changing them re-measures the row map, since
    /// each one takes a row.
    var phantoms = PhantomSet() {
        didSet {
            guard phantoms != oldValue else { return }
            rowMap.setPhantomRows(phantoms.rowsPerLine)
            updateFrameSize()
            needsDisplay = true
        }
    }

    /// Replaces one source's annotations, leaving other sources' alone.
    public func setPhantoms(_ new: [Phantom], owner: String) {
        var updated = phantoms
        updated.removeAll(owner: owner)
        for phantom in new { updated.add(phantom) }
        phantoms = updated
    }

    // MARK: - Spell check (T101)

    /// `spell_check` from the settings stack. Off by default: it is a prose feature, and
    /// most files opened in a code editor are not prose.
    public var spellCheckEnabled = false {
        didSet {
            guard spellCheckEnabled != oldValue else { return }
            spellCheckCache = [:]
            needsDisplay = true
        }
    }
    /// Misspellings per line, invalidated wholesale when the document changes.
    var spellCheckCache: [Int: [NSRange]] = [:]
    var spellCheckGeneration: UInt64?

    // MARK: - Diff gutter (T102)

    /// The file's lines as last loaded or saved. nil for an unsaved buffer, which has
    /// nothing to diff against.
    var diffBaseline: [String]?
    var cachedDiffMarks: [Int: DiffMark] = [:]
    var cachedDiffGeneration: UInt64?

    // MARK: - Find results (T64)

    /// Set when this editor is showing find-in-files results, which turns it into a
    /// navigable list: double-click or Enter on a match line jumps to it. nil for a normal
    /// document, so nothing about ordinary editing changes.
    var findResults: FindResultsBuffer?
    /// Asks the window to open the match on a given buffer line.
    var onActivateResult: ((FileMatch) -> Void)?

    var isFindResultsBuffer: Bool { findResults != nil }

    /// Activates the match on the caret's line, if there is one. Returns false for a
    /// heading, blank or context line — which then does nothing rather than jumping
    /// somewhere the user didn't point at.
    @discardableResult
    func activateResult(atLine line: Int) -> Bool {
        guard let match = findResults?.match(atBufferLine: line) else { return false }
        onActivateResult?(match)
        return true
    }

    // MARK: - Macros (T94)

    /// True while `run(_:)` is replaying, so replay neither re-records itself nor recurses.
    var isReplayingMacro = false
    /// Status text for the window's status line ("Recording macro…", "Replayed 6 steps").
    public var onMacroStatus: ((String) -> Void)?

    // MARK: - Minimap (T93)

    /// The strip beside this editor, if the window built one. Weak: the minimap is owned by
    /// the tab's container view, and it holds a weak reference back, so neither keeps the
    /// other alive.
    weak var minimap: Minimap?

    /// `minimap` from the settings stack. Toggling it shows/hides the strip, which the
    /// window controller wires up.
    public var minimapEnabled = false {
        didSet { if minimapEnabled != oldValue { onMinimapVisibilityChanged?() } }
    }
    public var onMinimapVisibilityChanged: (() -> Void)?

    /// Repaints the strip. Cheap enough to call from every edit, scroll and highlight batch:
    /// the minimap culls to its dirty rect and samples rows past a few thousand.
    func refreshMinimap() { minimap?.needsDisplay = true }

    // MARK: - Word wrap (T28)

    /// Folds *and* wrap, combined. Every screen position goes through this.
    var rowMap = RowMap()

    /// `word_wrap` from the settings stack.
    public var wordWrapEnabled = false {
        didSet { if wordWrapEnabled != oldValue { rebuildRowMap() } }
    }
    /// `wrap_width` — columns to wrap at, or 0 for "the window width".
    public var wrapColumn = 0 {
        didSet { if wrapColumn != oldValue { rebuildRowMap() } }
    }
    /// Wrap width the row map was last built for, so a resize that doesn't change the
    /// column count (most of them) doesn't rebuild the whole index.
    var lastBuiltWrapWidth = -1

    // MARK: - Snippets (T91)

    /// One store for the process: snippet files are read once and shared, like grammars.
    public static let snippetStore = SnippetStore()

    /// The snippet being filled in, if any. nil most of the time.
    var snippetSession: SnippetSession?
    /// True while `synchronizeSnippetMirrors` is rewriting mirrors, so those edits don't
    /// recurse back into the session that generated them.
    var isApplyingSnippetMirrors = false
    /// Set by the *typing* paths immediately before an edit, describing what is about to be
    /// replaced so the session can rebase precisely.
    ///
    /// `didEdit` cannot work this out for itself — it only receives the resulting selection,
    /// not what changed — and guessing from a length delta would be wrong the moment an
    /// edit happened anywhere but the caret. Anything that edits *without* setting this
    /// (paste, line transforms, undo, Replace All) deliberately ends the session instead:
    /// far better than tracking stop ranges that no longer describe the document.
    var pendingSnippetEdit: (replaced: Range<Int>, newByteLength: Int)?

    lazy var layout = LayoutCache(font: font)

    var lineHeight: CGFloat = 0
    var charWidth: CGFloat = 0
    var baselineOffset: CGFloat = 0
    let textPadding: CGFloat = 6
    let topPadding: CGFloat = 4
    let gutterPadding: CGFloat = 8

    var gutterWidth: CGFloat {
        guard showsGutter else { return 0 }
        let digits = max(2, String(document.lineCount).count)
        return ceil(charWidth * CGFloat(digits)) + gutterPadding * 2
    }

    /// X of column 0 in document coordinates.
    var textOriginX: CGFloat { gutterWidth + textPadding }

    // MARK: - Caret blink

    var caretVisible = true
    var blinkTimer: Timer?

    // MARK: - Mouse state

    enum DragMode { case character, word, line, column }
    var dragMode: DragMode = .character
    var dragOrigin = Position.zero
    var dragOriginRegion: Region?
    /// Regions that existed before an additive (⌘-click) drag started.
    var dragBaseRegions: [Region] = []

    // MARK: - Init

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        fontDidChange()
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        blinkTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override var isOpaque: Bool { true }

    /// Opts out of AppKit's responsive-scrolling overdraw, which drives a document view
    /// through `prepareContentInRect(_:)`. This view has never implemented that method —
    /// it computes its own visible line range in `draw(_:)` and invalidates through
    /// `clipBoundsChanged` — so it was being handed machinery it does not participate in.
    ///
    /// Honest history: this was added while chasing the blank-pane bug (KNOWLEDGE.md) on a
    /// theory that the layer dumps then disproved, and it did **not** fix it — moving the
    /// find bar inside the pane did. Kept because opting out is correct for a view that
    /// manages its own visible range, not because it is load-bearing.
    public override class var isCompatibleWithResponsiveScrolling: Bool { false }

    var isActive: Bool { window?.firstResponder === self }

    private func fontDidChange() {
        lineHeight = ceil(font.ascender - font.descender + font.leading)
        charWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        baselineOffset = font.ascender
        styledFonts.removeAll(keepingCapacity: true)
        layout.font = font
        // A different font means a different character width, so every wrap point moves.
        rebuildRowMap()
        updateFrameSize()
        needsDisplay = true
    }

    // MARK: - Content

    public var text: String {
        get { document.text }
        set {
            // Preserve encoding and line ending, or the next save rewrites the file
            // in the wrong convention.
            document.setText(newValue,
                             url: document.fileURL,
                             encoding: document.encoding,
                             lineEnding: document.lineEnding,
                             modificationDate: document.modificationDate)
            didReplaceDocument()
        }
    }

    public func loadFile(_ url: URL) throws {
        try document.load(from: url)
        didReplaceDocument()
        resetDiffBaseline()
    }

    /// T85 (hot exit): restores unsaved content stashed by the session at last quit.
    /// Like the `text` setter but with the *original* document identity — its file URL
    /// (which the plain setter would keep as whatever the document currently has) and
    /// the encoding/line-ending convention the file on disk uses, so a later ⌘S still
    /// writes the same convention back. Lives in this file, not `EditorView+Find`-style
    /// extensions, because `didReplaceDocument` is `private` (file-scoped).
    public func restoreBuffer(text: String, url: URL?, encoding: TextEncodingKind, lineEnding: LineEnding) {
        document.setText(text, url: url, encoding: encoding, lineEnding: lineEnding, modificationDate: nil)
        // After `didReplaceDocument` would be too late to matter, but set it before
        // anyway: the restored buffer is by definition unsaved work, and must show the
        // dirty dot / prompt-on-close from its very first frame.
        document.markRestoredDirty()
        didReplaceDocument()
    }

    private func didReplaceDocument() {
        // Candidates came from the old document, and both completion caches are now
        // refreshed on an idle timer rather than keyed on `document.generation` (see
        // `BufferWordIndex`), so replacing the document has to clear them explicitly —
        // otherwise the new file offers the old one's words until the timer next fires.
        bufferWordIndex.invalidate()
        cachedCompletionSymbolsGeneration = nil
        hideCompletions()
        suppressedCompletionWord = nil
        // Folds describe the old document's line structure (T92), annotations point at its
        // lines (T103), and every line's wrap has to be measured afresh (T28).
        folds = FoldSet()
        phantoms = PhantomSet()
        lastKnownLineCount = document.lineCount
        rebuildRowMap()
        selection = Selection(caret: .zero)
        markedText = ""
        markedStart = nil
        lastSearchNeedle = nil
        matchedBrackets = nil
        lastContentSniffLength = 0
        // Match regions belong to the old document.
        cachedSearchSession?.clear()
        onFindStatusChanged?(nil, false)
        layout.invalidateAll()
        // A new document gets fresh auto-detection.
        autoDetectsSyntax = true
        if grammarRegistry != nil {
            detectSyntax()
        } else {
            highlightService.reset()
        }
        updateFrameSize()
        scroll(.zero)
        needsDisplay = true
    }

    // MARK: - Scroll view wiring

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            // The run loop retains scheduled timers; a closed window must not leave
            // one ticking forever.
            blinkTimer?.invalidate()
            blinkTimer = nil
        }
        configureScrollView()
        updateFrameSize()
    }

    private func configureScrollView() {
        guard let clip = enclosingScrollView?.contentView else { return }
        // The gutter is pinned to the viewport's left edge, so a horizontal scroll must
        // repaint it even though the text underneath only shifted. NSClipView minimises
        // invalidation on its own since macOS 11 (copiesOnScroll no longer does
        // anything), so the bounds observer below invalidates the visible rect instead.
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: clip)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(clipBoundsChanged),
                                               name: NSView.boundsDidChangeNotification,
                                               object: clip)

        // The viewport *resizing* is a separate notification from it *scrolling*, and
        // this one is what keeps `updateFrameSize`'s `max(viewport, content)` floor
        // honest. Without it the document view keeps whatever size it was given the last
        // time something else happened to call `updateFrameSize` — and the first such
        // call, from `viewDidMoveToWindow`, runs before Auto Layout has resolved the
        // scroll view's size at all, so `enclosingScrollView?.contentSize` is still zero
        // and the frame collapses to the *content* size. For a short document that looks
        // completely normal (text at the top, empty space below), which is why it went
        // unnoticed: the editor only appears to "go blank" once something scrolls the
        // clip view horizontally — opening Find scrolls to a match — and the text slides
        // out of the viewport with no full-height document view left behind it.
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: clip)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(clipFrameChanged),
                                               name: NSView.frameDidChangeNotification,
                                               object: clip)
        // The observer above only fires on *later* resizes; this call catches the size
        // the clip view already has by the time the editor joins the window.
        updateFrameSize()
    }

    /// The completion popup is positioned in screen coordinates against the caret, so any
    /// scroll or viewport resize leaves it pointing at the wrong line. Dismissing is the
    /// right call rather than repositioning: scrolling away from what you were typing ends
    /// that completion session anyway.
    private func hideCompletionsOnViewportChange() {
        if isCompletionVisible { hideCompletions() }
    }

    @objc private func clipFrameChanged() {
        // Terminates rather than ping-ponging: `updateFrameSize` only calls
        // `setFrameSize` when the size actually differs, and resizing the *document*
        // view doesn't resize the clip view that drives this notification.
        // A narrower or wider viewport changes how many columns fit, so the wrap points
        // move with it (T28). Guarded inside so a resize that leaves the column count
        // unchanged — most of them — doesn't rebuild the index.
        wrapWidthDidChange()
        updateFrameSize()
        setNeedsDisplay(visibleRect)
        hideCompletionsOnViewportChange()
    }

    @objc private func clipBoundsChanged() {
        // The viewport box tracks the scroll position (T93).
        refreshMinimap()
        hideCompletionsOnViewportChange()
        // Cursor rects are derived from the viewport origin whether or not the gutter
        // is visible, so they go stale on any horizontal scroll.
        window?.invalidateCursorRects(for: self)
        // Repaint what is on screen — not just to keep the pinned gutter following the
        // scroll, but because NSClipView no longer redraws the newly revealed strip on
        // its own (copiesOnScroll has been a no-op since macOS 11). This must run for
        // *any* bounds change — a vertical resize (the find bar showing/hiding shrinks
        // or grows the viewport) needs it just as much as a horizontal scroll does, so
        // it is not gated on `showsGutter`. Scoped to the visible rect rather than the
        // whole (possibly enormous) document view.
        setNeedsDisplay(visibleRect)
    }

    func updateFrameSize() {
        let visible = enclosingScrollView?.contentSize ?? bounds.size
        // Wrapping means no horizontal scroll by definition — the canvas is exactly the
        // viewport, which is also what stops the wrap width and the canvas width from
        // chasing each other on every resize.
        let contentWidth = rowMap.isWrapping
            ? 0
            : textOriginX + charWidth * CGFloat(document.longestLineLength) + textPadding * 2
        // Rows, not lines: folding shortens the document view and wrapping lengthens it,
        // which is what makes the scroll bar reflect what you can actually see (T92, T28).
        let contentHeight = topPadding * 2 + lineHeight * CGFloat(rowMap.totalRows)
        let size = NSSize(width: max(visible.width, contentWidth),
                          height: max(visible.height, contentHeight))
        if frame.size != size { setFrameSize(size) }
    }

    // MARK: - Geometry

    /// Shaped line, highlighted if its spans have arrived.
    func cachedLine(_ index: Int) -> LayoutCache.Entry {
        layout.entry(forLine: index,
                     in: document,
                     plainAttributes: baseAttributes) { [weak self] line, text in
            self?.attributedLine(line, text: text)
        }
    }

    /// Y of a document line's **first** row. Positions that need an exact row (a caret
    /// mid-way through a wrapped line) go through `rowTop(_:)` with `rowMap.row(at:)`.
    func lineTop(_ index: Int) -> CGFloat {
        rowTop(rowMap.firstRow(ofLine: index))
    }

    func rowTop(_ row: Int) -> CGFloat { topPadding + CGFloat(row) * lineHeight }

    /// The screen rows on display, each carrying the document line and the slice of that
    /// line's columns drawn on it.
    ///
    /// Replaces the line-based version from T92: with wrapping, one line can occupy several
    /// rows, so "which lines are visible" is no longer enough to draw with — every row needs
    /// its own column range and its own Y.
    func visibleRows(in rect: NSRect) -> VisibleRows? {
        guard lineHeight > 0, document.lineCount > 0 else { return nil }
        let total = rowMap.totalRows
        let firstRow = max(0, Int((rect.minY - topPadding) / lineHeight))
        let lastRow = min(total - 1, Int((rect.maxY - topPadding) / lineHeight))
        guard firstRow <= lastRow else { return nil }

        var rows: [VisibleRow] = []
        rows.reserveCapacity(lastRow - firstRow + 1)
        for row in firstRow ... lastRow {
            let location = rowMap.location(ofRow: row)
            guard location.line < document.lineCount else { break }

            // Phantom rows carry no text of their own — they sit after the line's wrapped
            // rows and show an annotation instead (T103).
            if rowMap.isPhantomRow(line: location.line, rowInLine: location.rowInLine) {
                rows.append(VisibleRow(row: row, line: location.line,
                                       rowInLine: location.rowInLine,
                                       columns: 0 ..< 0,
                                       phantomIndex: location.rowInLine - rowMap.wrapRows(forLine: location.line)))
                continue
            }

            let text = document.line(location.line)
            let columns: Range<Int>
            if rowMap.isWrapping {
                let breaks = wrapBreaks(forLine: location.line, text: text)
                columns = WordWrapper.columnRange(ofRow: location.rowInLine,
                                                 breaks: breaks, lineLength: text.count)
            } else {
                columns = 0 ..< text.count
            }
            rows.append(VisibleRow(row: row, line: location.line,
                                   rowInLine: location.rowInLine, columns: columns,
                                   phantomIndex: nil))
        }
        return rows.isEmpty ? nil : VisibleRows(rows: rows)
    }

    /// Break columns for a line, computed on demand. Cheap enough per repaint (one greedy
    /// scan of a single line) that caching it separately from `rowMap` would be complexity
    /// without benefit.
    func wrapBreaks(forLine line: Int, text: String? = nil) -> [Int] {
        guard rowMap.isWrapping else { return [] }
        return WordWrapper.breaks(for: text ?? document.line(line),
                                  width: rowMap.wrapWidth, tabSize: foldTabSize)
    }

    /// First…last visible line as a plain range, for callers that only need bounds rather
    /// than exactly which lines are drawn — highlighting priority and span invalidation,
    /// where covering a few folded lines too is harmless and cheaper than being exact.
    func visibleLineBounds(in rect: NSRect) -> ClosedRange<Int>? {
        guard let visible = visibleRows(in: rect) else { return nil }
        return visible.lowerBound ... visible.upperBound
    }

    var visibleLineCount: Int {
        let height = enclosingScrollView?.contentSize.height ?? bounds.height
        return max(1, Int(height / lineHeight) - 1)
    }

    /// X offset of `column` within its line, in document coordinates.
    func xOffset(ofColumn column: Int, line index: Int) -> CGFloat {
        let entry = cachedLine(index)
        guard !entry.text.isEmpty else { return textOriginX }
        let utf16 = utf16Offset(ofColumn: column, in: entry.text)
        return textOriginX + CTLineGetOffsetForStringIndex(entry.ctLine, utf16, nil)
    }

    /// Screen x of a column **on a given row** — the column's offset within its line,
    /// rebased so the row's first column sits at the text origin. Identical to `xOffset`
    /// when wrapping is off, since every row then starts at column 0.
    func x(forColumn column: Int, in row: VisibleRow) -> CGFloat {
        guard rowMap.isWrapping else { return xOffset(ofColumn: column, line: row.line) }
        let rowStart = xOffset(ofColumn: row.columns.lowerBound, line: row.line)
        return textOriginX + (xOffset(ofColumn: column, line: row.line) - rowStart)
    }

    func caretRect(for position: Position) -> NSRect {
        let p = document.clamp(position)
        guard rowMap.isWrapping else {
            return NSRect(x: xOffset(ofColumn: p.column, line: p.line),
                          y: lineTop(p.line), width: 1.5, height: lineHeight)
        }
        // On a wrapped line the caret's row and its x both depend on which wrapped row the
        // column falls on, so both come from the break points rather than from the line.
        let text = document.line(p.line)
        let breaks = wrapBreaks(forLine: p.line, text: text)
        let rowInLine = WordWrapper.row(forColumn: p.column, breaks: breaks)
        let columns = WordWrapper.columnRange(ofRow: rowInLine, breaks: breaks, lineLength: text.count)
        let rowStart = xOffset(ofColumn: columns.lowerBound, line: p.line)
        return NSRect(x: textOriginX + (xOffset(ofColumn: p.column, line: p.line) - rowStart),
                      y: rowTop(rowMap.firstRow(ofLine: p.line) + rowInLine),
                      width: 1.5, height: lineHeight)
    }

    func position(at point: NSPoint) -> Position {
        // Clamp before converting to Int: externally supplied points can be far out
        // of range or non-finite, and Int(_: CGFloat) traps on both.
        let raw = (point.y - topPadding) / lineHeight
        let rowCount = rowMap.totalRows
        let bounded = raw.isFinite ? min(max(raw, 0), CGFloat(rowCount)) : 0
        // The click lands on a *row*; which line and which part of it depends on both what
        // is folded above (T92) and how the line wraps (T28).
        let row = max(0, min(rowCount - 1, Int(bounded)))
        let location = rowMap.location(ofRow: row)
        let lineIndex = max(0, min(document.lineCount - 1, location.line))

        let entry = cachedLine(lineIndex)
        guard !entry.text.isEmpty else { return Position(line: lineIndex, column: 0) }

        // Rebase the click into the line's own coordinates: on a wrapped row, screen x is
        // measured from that row's first column, not from the start of the line.
        var columns = 0 ..< entry.text.count
        var rowStartX: CGFloat = 0
        if rowMap.isWrapping {
            let breaks = wrapBreaks(forLine: lineIndex, text: entry.text)
            columns = WordWrapper.columnRange(ofRow: location.rowInLine, breaks: breaks,
                                              lineLength: entry.text.count)
            rowStartX = xOffset(ofColumn: columns.lowerBound, line: lineIndex) - textOriginX
        }
        let x = point.x - textOriginX + rowStartX
        guard x.isFinite else { return Position(line: lineIndex, column: columns.lowerBound) }
        let u16 = CTLineGetStringIndexForPosition(entry.ctLine, CGPoint(x: x, y: 0))
        var column = u16 == kCFNotFound ? entry.text.count : self.column(fromUTF16: u16, in: entry.text)
        // Clicking past the end of a wrapped row belongs to that row, not to the next one.
        column = min(max(column, columns.lowerBound), columns.upperBound)
        return document.clamp(Position(line: lineIndex, column: column))
    }

    /// Column nearest to `x` on `line`, used by rectangular selection where the
    /// column must be produced even past the end of a short line.
    func column(atX x: CGFloat, line index: Int) -> Int {
        let entry = cachedLine(index)
        guard !entry.text.isEmpty else { return 0 }
        let u16 = CTLineGetStringIndexForPosition(entry.ctLine, CGPoint(x: x - textOriginX, y: 0))
        return u16 == kCFNotFound ? entry.text.count : column(fromUTF16: u16, in: entry.text)
    }

    func utf16Offset(ofColumn column: Int, in line: String) -> Int {
        let index = line.index(line.startIndex, offsetBy: max(0, min(column, line.count)))
        return line.utf16.distance(from: line.utf16.startIndex, to: index)
    }

    func column(fromUTF16 offset: Int, in line: String) -> Int {
        let clamped = max(0, min(offset, line.utf16.count))
        guard let u16Index = line.utf16.index(line.utf16.startIndex, offsetBy: clamped,
                                              limitedBy: line.utf16.endIndex)
        else { return line.count }
        // A UTF-16 index inside a grapheme cluster (combining mark, flag emoji,
        // surrogate half) has no Character position — snap to the cluster start
        // rather than falling off the end of the line.
        let index = u16Index.samePosition(in: line)
            ?? line.rangeOfComposedCharacterSequence(at: u16Index).lowerBound
        return line.distance(from: line.startIndex, to: index)
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        if InputDiagnostics.isEnabled {
            let bg = themeBackground.usingColorSpace(.deviceRGB)
            let fg = (colorScheme.globals.foreground?.nsColor ?? .labelColor)
                .usingColorSpace(.deviceRGB)
            func hex(_ c: NSColor?) -> String {
                guard let c else { return "?" }
                return String(format: "#%02X%02X%02X a=%.2f",
                              Int(c.redComponent * 255), Int(c.greenComponent * 255),
                              Int(c.blueComponent * 255), c.alphaComponent)
            }
            InputDiagnostics.log("""
                  -> draw dirty=\(dirtyRect.integral) bounds=\(bounds.integral) \
                lines=\(document.lineCount) rows=\(rowMap.totalRows) lineHeight=\(lineHeight) \
                bg=\(hex(bg)) fg=\(hex(fg))
                """)
        }
        guard let context = NSGraphicsContext.current?.cgContext else {
            InputDiagnostics.log("     ** no graphics context — nothing drawn **")
            return
        }

        themeBackground.setFill()
        dirtyRect.fill()

        guard let visible = visibleRows(in: dirtyRect) else {
            InputDiagnostics.log("     ** visibleRows returned nil — only the gutter is drawn **")
            drawGutter(in: dirtyRect, context: context, lines: nil)
            return
        }
        InputDiagnostics.log("""
                 drawing \(visible.rows.count) rows | flipped=\(isFlipped) \
            rowTop(0)=\(rowTop(0)) baselineOffset=\(baselineOffset) \
            textOriginX=\(textOriginX) gutterWidth=\(gutterWidth) charWidth=\(charWidth) \
            showsGutter=\(showsGutter) wantsLayer=\(wantsLayer) \
            layerOpacity=\(layer?.opacity ?? -1) layerHidden=\(layer?.isHidden ?? false) \
            alpha=\(alphaValue) hiddenAncestor=\(isHiddenOrHasHiddenAncestor)
            """)

        drawCurrentLineHighlight(visible)
        drawRulers(dirtyRect)
        drawSearchMatches(visible)
        drawSelection(visible)
        drawBracketMatch(visible)
        drawText(visible, context: context)
        drawCarets(visible)
        drawGutter(in: dirtyRect, context: context, lines: visible)

        // Any visible line still lacking spans means the sweep hasn't reached here yet.
        if visible.lines.contains(where: { highlightService.spans(forLine: $0) == nil }) {
            requestVisibleHighlighting()
        }
    }

    private func drawCurrentLineHighlight(_ visible: VisibleRows) {
        guard highlightsCurrentLine, !selection.isMultiple, !selection.hasSelectedText, isActive
        else { return }
        let lineIndex = selection.primary.head.line
        guard visible.contains(lineIndex) else { return }
        themeLineHighlight.setFill()
        // Every row of a wrapped line, so the highlight doesn't stop halfway through it.
        for row in visible.rows(forLine: lineIndex) {
            NSRect(x: 0, y: rowTop(row.row), width: bounds.width, height: lineHeight).fill()
        }
    }

    private func drawRulers(_ dirtyRect: NSRect) {
        guard !rulerColumns.isEmpty else { return }
        NSColor.separatorColor.withAlphaComponent(0.4).setFill()
        for column in rulerColumns {
            let x = textOriginX + charWidth * CGFloat(column)
            NSRect(x: x, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
        }
    }

    private func drawSelection(_ visible: VisibleRows) {
        themeSelection.setFill()

        for region in selection.regions where !region.isEmpty {
            let start = region.start
            let end = region.end
            guard end.line >= visible.lowerBound, start.line <= visible.upperBound else { continue }

            // Per *row*, not per line: a selection must be clipped to each wrapped row's
            // own column slice, and must not paint over a collapsed region at all.
            for row in visible.rows where row.line >= start.line && row.line <= end.line {
                let lineFrom = row.line == start.line ? start.column : 0
                let isLastLine = row.line == end.line
                let lineTo = isLastLine ? end.column : document.lineLength(row.line)

                // Intersect the selected columns with the columns this row shows.
                let from = max(lineFrom, row.columns.lowerBound)
                let to = min(lineTo, row.columns.upperBound)
                guard from <= to else { continue }

                let x0 = x(forColumn: from, in: row)
                var x1 = x(forColumn: to, in: row)
                // A selection running through a line break shows the newline as a sliver of
                // highlight past the last character — only on the row that actually ends the
                // line, not on every wrapped row of it.
                if !isLastLine, to == lineTo { x1 += charWidth * 0.5 }
                NSRect(x: x0, y: rowTop(row.row), width: max(1, x1 - x0), height: lineHeight).fill()
            }
        }
    }

    private func drawText(_ visible: VisibleRows, context: CGContext) {
        for row in visible.rows {
            if let index = row.phantomIndex {
                drawPhantom(forRow: row, index: index)
                continue
            }
            let entry = cachedLine(row.line)
            if InputDiagnostics.isEnabled {
                let live = document.line(row.line)
                // The colour that actually paints the glyphs lives in the CTLine's run
                // attributes, not in the scheme globals logged at the top of `draw`.
                var runColor = "none"
                if let runs = CTLineGetGlyphRuns(entry.ctLine) as? [CTRun], let first = runs.first {
                    let attrs = CTRunGetAttributes(first) as NSDictionary
                    if let cg = attrs[kCTForegroundColorAttributeName] as! CGColor?,
                       let c = NSColor(cgColor: cg)?.usingColorSpace(.deviceRGB) {
                        runColor = String(format: "#%02X%02X%02X a=%.2f",
                                          Int(c.redComponent * 255), Int(c.greenComponent * 255),
                                          Int(c.blueComponent * 255), c.alphaComponent)
                    }
                    InputDiagnostics.log("     runs=\(runs.count) glyphRunColor=\(runColor)")
                }
                InputDiagnostics.log("""
                         row line=\(row.line) cached=\(String(reflecting: String(entry.text.prefix(30)))) \
                    document=\(String(reflecting: String(live.prefix(30))))\
                    \(entry.text != live ? "  ** CACHE DISAGREES WITH DOCUMENT **" : "")
                    """)
            }
            if entry.text.isEmpty { continue }
            let baseline = rowTop(row.row) + baselineOffset

            context.saveGState()
            // Draw the line's *whole* `CTLine`, shifted so this row's first column lands at
            // the text origin, and clipped to the row. Reusing the cached per-line CTLine
            // rather than shaping one per wrapped row keeps `LayoutCache` untouched and
            // avoids re-shaping the same text once per row it happens to occupy.
            if rowMap.isWrapping {
                context.clip(to: NSRect(x: textOriginX, y: rowTop(row.row),
                                        width: max(0, bounds.width - textOriginX),
                                        height: lineHeight))
            }
            context.textMatrix = .identity
            // The CTLine starts at column 0, so shift left by this row's first column's
            // offset within the line to bring it to the text origin.
            let rowStartOffset = xOffset(ofColumn: row.columns.lowerBound, line: row.line) - textOriginX
            context.translateBy(x: textOriginX - rowStartOffset, y: baseline)
            context.scaleBy(x: 1, y: -1)
            CTLineDraw(entry.ctLine, context)
            context.restoreGState()

            if showsInvisibles { drawInvisibles(entry.text, line: row.line) }
            drawMisspellings(forRow: row)
            if row.rowInLine == 0 { drawFoldedIndicator(forLine: row.line) }
        }
    }

    private func drawInvisibles(_ text: String, line index: Int) {
        themeInvisibles.setFill()
        let y = lineTop(index) + lineHeight * 0.5
        for (column, character) in text.enumerated() where character == " " || character == "\t" {
            let x = xOffset(ofColumn: column, line: index)
            let size: CGFloat = character == " " ? 2 : 4
            NSRect(x: x + charWidth * 0.5 - size / 2, y: y - size / 2, width: size, height: size).fill()
        }
    }

    private func drawCarets(_ visible: VisibleRows) {
        guard isActive, caretVisible else { return }
        themeCaret.setFill()
        for region in selection.regions where visible.contains(region.head.line) {
            caretRect(for: region.head).fill()
        }
    }

    private func drawGutter(in dirtyRect: NSRect, context: CGContext, lines visible: VisibleRows?) {
        guard showsGutter, gutterWidth > 0 else { return }
        // Pinned to the viewport's left edge so it survives horizontal scrolling.
        let originX = (enclosingScrollView?.contentView.bounds.origin.x).map { max(0, $0) } ?? 0

        themeGutterBackground.setFill()
        NSRect(x: originX, y: dirtyRect.minY, width: gutterWidth, height: dirtyRect.height).fill()
        NSColor.separatorColor.setFill()
        NSRect(x: originX + gutterWidth - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()

        guard let visible else { return }
        let caretLines = Set(selection.regions.map { $0.head.line })
        let emphasis = colorScheme.globals.foreground?.nsColor ?? .labelColor

        // One number per *line*, drawn at its first row — a wrapped line's continuation
        // rows get no number, matching every other editor.
        for lineIndex in visible.lines {
            // A triangle only where something can actually fold, so the gutter isn't a
            // column of decoration (T92).
            drawDiffMark(forLine: lineIndex)
            if folds.isFolded(startLine: lineIndex) {
                drawFoldTriangle(forLine: lineIndex, folded: true)
            } else if foldRegion(at: lineIndex) != nil {
                drawFoldTriangle(forLine: lineIndex, folded: false)
            }
            let color = caretLines.contains(lineIndex) ? emphasis : themeGutterForeground
            let ctLine = layout.makeCTLine(String(lineIndex + 1), color: color)
            let width = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
            context.saveGState()
            context.textMatrix = .identity
            context.translateBy(x: originX + gutterWidth - gutterPadding - width,
                                y: lineTop(lineIndex) + baselineOffset)
            context.scaleBy(x: 1, y: -1)
            CTLineDraw(ctLine, context)
            context.restoreGState()
        }
    }

    // MARK: - Post-change plumbing

    /// Call after any edit: refreshes metrics, repaints, scrolls the primary caret
    /// into view and notifies the window controller.
    func didEdit(newSelection: Selection) {
        // Re-highlight from the earliest line any caret touched.
        let firstChangedLine = min(selection.regions.first?.start.line ?? 0,
                                   newSelection.regions.first?.start.line ?? 0)
        selection = newSelection
        highlightingDidEdit(fromLine: firstChangedLine)
        attemptContentBasedDetection()
        updateBracketMatch()
        searchDidEdit()
        updateFrameSize()
        caretVisible = true
        needsDisplay = true
        scrollToPrimaryCaret()
        // T91: keep an active snippet's stop ranges in step, or end it if this edit came
        // from a path that can't describe itself (see `pendingSnippetEdit`).
        rowMapDidEdit(fromLine: firstChangedLine)
        refreshMinimap()
        foldsDidEdit(fromLine: firstChangedLine)
        scheduleBufferWordRefresh()
        if snippetSession != nil, !isApplyingSnippetMirrors {
            if let pending = pendingSnippetEdit {
                pendingSnippetEdit = nil
                snippetDidEdit(replaced: pending.replaced, newByteLength: pending.newByteLength)
            } else {
                endSnippetSession()
            }
        }
        onChange?()
    }

    /// Human-readable caret/selection state for the status bar.
    public var selectionSummary: String {
        if selection.isMultiple {
            let selected = selection.regions.filter { !$0.isEmpty }.count
            return selected > 0
                ? "\(selection.count) cursors, \(selected) selections"
                : "\(selection.count) cursors"
        }
        let region = selection.primary
        if region.isEmpty {
            return "Line \(region.head.line + 1), Column \(region.head.column + 1)"
        }
        let characters = document.text(in: region).count
        let lines = region.end.line - region.start.line + 1
        return lines > 1
            ? "\(characters) characters on \(lines) lines"
            : "\(characters) characters selected"
    }

    /// Call after a pure selection change (no edit).
    func didMoveSelection(_ newSelection: Selection, scroll: Bool = true) {
        selection = newSelection
        document.breakUndoCoalescing()
        updateBracketMatch()
        caretVisible = true
        needsDisplay = true
        if scroll { scrollToPrimaryCaret() }
        onChange?()
    }

    func scrollToPrimaryCaret() {
        var rect = caretRect(for: selection.primary.head)
        rect = rect.insetBy(dx: -charWidth * 3, dy: -lineHeight)
        // Reveal the gutter alongside a caret near column 0 — grow the rect leftwards
        // rather than sliding it, which would uncover the caret on the right.
        if rect.minX < textOriginX {
            rect.size.width += rect.origin.x
            rect.origin.x = 0
        }
        scrollToVisible(rect)
    }

    // MARK: - Focus / blink

    /// Fired when this editor takes focus, so the window controller can update which pane
    /// it considers focused. Clicking straight into a pane's text is the one way focus
    /// moves *without* going through `MainWindowController.activate(_:)`.
    public var onDidBecomeFirstResponder: (() -> Void)?

    public override func becomeFirstResponder() -> Bool {
        startBlink()
        needsDisplay = true
        onDidBecomeFirstResponder?()
        return super.becomeFirstResponder()
    }

    public override func resignFirstResponder() -> Bool {
        blinkTimer?.invalidate()
        blinkTimer = nil
        // A completion list belongs to an active typing session; leaving it up while focus
        // is elsewhere would strand a floating panel over unrelated UI (T90).
        hideCompletions()
        needsDisplay = true
        return super.resignFirstResponder()
    }

    func startBlink() {
        blinkTimer?.invalidate()
        caretVisible = true
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.caretVisible.toggle()
            for region in self.selection.regions {
                self.setNeedsDisplay(self.caretRect(for: region.head).insetBy(dx: -2, dy: -2))
            }
        }
    }

}

/// One screen row: which document line it belongs to, which of that line's wrapped rows it
/// is, and the slice of columns drawn on it (T28).
struct VisibleRow {
    let row: Int
    let line: Int
    let rowInLine: Int
    /// Columns of `line` this row covers. The whole line when wrapping is off. Empty for a
    /// phantom row, which shows an annotation rather than any of the line's text.
    let columns: Range<Int>
    /// Which of the line's phantoms this row shows, if it is a phantom row (T103).
    let phantomIndex: Int?
}

/// The rows on screen for one repaint, in screen order.
///
/// Replaced the line-based `VisibleLines` from T92 when wrapping arrived: visible lines are
/// not contiguous (folding) *and* a single line can occupy several rows (wrapping), so
/// neither a range nor a line list is enough to draw from.
struct VisibleRows {
    let rows: [VisibleRow]
    private let lookup: Set<Int>

    init(rows: [VisibleRow]) {
        self.rows = rows
        self.lookup = Set(rows.map(\.line))
    }

    /// Distinct document lines on screen, in order — for callers that work per line rather
    /// than per row (the gutter draws one number per line, not per wrapped row).
    var lines: [Int] {
        var seen = Set<Int>()
        return rows.compactMap { seen.insert($0.line).inserted ? $0.line : nil }
    }

    var lowerBound: Int { rows.first?.line ?? 0 }
    var upperBound: Int { rows.last?.line ?? 0 }

    /// True only for lines actually drawn — a line inside a collapsed region falls between
    /// the bounds but is not on screen.
    func contains(_ line: Int) -> Bool { lookup.contains(line) }

    /// Every row belonging to `line`, for splitting a selection or match across wraps.
    func rows(forLine line: Int) -> [VisibleRow] { rows.filter { $0.line == line } }
}
