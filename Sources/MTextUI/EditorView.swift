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
    /// Buffer words for this document, cached against `TextDocument.generation`.
    let bufferWordIndex = BufferWordIndex()
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
            layout.invalidateAll()
            updateFrameSize()
            needsDisplay = true
        }
    }

    /// Line count as of the last `didEdit`, so the next one can tell how many lines an
    /// edit added or removed and shift folds to match. `didEdit` only receives the
    /// resulting selection, so the delta has to be remembered rather than derived.
    var lastKnownLineCount = 1

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
        // Candidates came from the old document. (`bufferWordIndex` needs no explicit
        // invalidation — it keys on `document.generation`, which has already moved.)
        hideCompletions()
        suppressedCompletionWord = nil
        // Folds describe the old document's line structure (T92).
        folds = FoldSet()
        lastKnownLineCount = document.lineCount
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
        updateFrameSize()
        setNeedsDisplay(visibleRect)
        hideCompletionsOnViewportChange()
    }

    @objc private func clipBoundsChanged() {
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
        let contentWidth = textOriginX + charWidth * CGFloat(document.longestLineLength) + textPadding * 2
        // Rows, not lines: folding shortens the document view, which is what makes the
        // scroll bar reflect what you can actually see (T92).
        let rows = folds.visibleLineCount(totalLines: document.lineCount)
        let contentHeight = topPadding * 2 + lineHeight * CGFloat(rows)
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

    /// Y of a document line, **via its visual row** — with anything folded, line *n* is no
    /// longer row *n* (T92). Everything that positions by line goes through here.
    func lineTop(_ index: Int) -> CGFloat {
        topPadding + CGFloat(folds.visualRow(forLine: index)) * lineHeight
    }

    /// The document lines actually on screen, in screen order.
    ///
    /// Walks *rows* and maps each to a line rather than walking a line range and skipping
    /// hidden ones: with a large region collapsed, the span between the first and last
    /// visible line can be the whole document, and skipping through it every repaint would
    /// make drawing O(document) instead of O(screen).
    func visibleLines(in rect: NSRect) -> VisibleLines? {
        guard lineHeight > 0, document.lineCount > 0 else { return nil }
        let rowCount = folds.visibleLineCount(totalLines: document.lineCount)
        let firstRow = max(0, Int((rect.minY - topPadding) / lineHeight))
        let lastRow = min(rowCount - 1, Int((rect.maxY - topPadding) / lineHeight))
        guard firstRow <= lastRow else { return nil }

        var lines: [Int] = []
        lines.reserveCapacity(lastRow - firstRow + 1)
        for row in firstRow ... lastRow {
            let line = folds.line(forVisualRow: row)
            guard line < document.lineCount else { break }
            lines.append(line)
        }
        return lines.isEmpty ? nil : VisibleLines(lines: lines)
    }

    /// First…last visible line as a plain range, for callers that only need bounds rather
    /// than exactly which lines are drawn — highlighting priority and span invalidation,
    /// where covering a few folded lines too is harmless and cheaper than being exact.
    func visibleLineBounds(in rect: NSRect) -> ClosedRange<Int>? {
        guard let visible = visibleLines(in: rect) else { return nil }
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

    func caretRect(for position: Position) -> NSRect {
        let p = document.clamp(position)
        return NSRect(x: xOffset(ofColumn: p.column, line: p.line),
                      y: lineTop(p.line),
                      width: 1.5,
                      height: lineHeight)
    }

    func position(at point: NSPoint) -> Position {
        // Clamp before converting to Int: externally supplied points can be far out
        // of range or non-finite, and Int(_: CGFloat) traps on both.
        let raw = (point.y - topPadding) / lineHeight
        let rowCount = folds.visibleLineCount(totalLines: document.lineCount)
        let bounded = raw.isFinite ? min(max(raw, 0), CGFloat(rowCount)) : 0
        // The click lands on a *row*; which document line that is depends on what is
        // folded above it (T92).
        let row = max(0, min(rowCount - 1, Int(bounded)))
        let lineIndex = max(0, min(document.lineCount - 1, folds.line(forVisualRow: row)))

        let entry = cachedLine(lineIndex)
        guard !entry.text.isEmpty else { return Position(line: lineIndex, column: 0) }
        let x = point.x - textOriginX
        guard x.isFinite else { return Position(line: lineIndex, column: 0) }
        let u16 = CTLineGetStringIndexForPosition(entry.ctLine, CGPoint(x: x, y: 0))
        let column = u16 == kCFNotFound ? entry.text.count : self.column(fromUTF16: u16, in: entry.text)
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
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        themeBackground.setFill()
        dirtyRect.fill()

        guard let visible = visibleLines(in: dirtyRect) else {
            drawGutter(in: dirtyRect, context: context, lines: nil)
            return
        }

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

    private func drawCurrentLineHighlight(_ visible: VisibleLines) {
        guard highlightsCurrentLine, !selection.isMultiple, !selection.hasSelectedText, isActive
        else { return }
        let lineIndex = selection.primary.head.line
        guard visible.contains(lineIndex) else { return }
        themeLineHighlight.setFill()
        NSRect(x: 0, y: lineTop(lineIndex), width: bounds.width, height: lineHeight).fill()
    }

    private func drawRulers(_ dirtyRect: NSRect) {
        guard !rulerColumns.isEmpty else { return }
        NSColor.separatorColor.withAlphaComponent(0.4).setFill()
        for column in rulerColumns {
            let x = textOriginX + charWidth * CGFloat(column)
            NSRect(x: x, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
        }
    }

    private func drawSelection(_ visible: VisibleLines) {
        themeSelection.setFill()

        for region in selection.regions where !region.isEmpty {
            let start = region.start
            let end = region.end
            guard end.line >= visible.lowerBound, start.line <= visible.upperBound else { continue }

            // Only lines actually on screen: a selection spanning a collapsed region must
            // not paint the hidden lines' worth of highlight over the fold.
            for lineIndex in visible.lines where lineIndex >= start.line && lineIndex <= end.line {
                let fromColumn = lineIndex == start.line ? start.column : 0
                let isLastLine = lineIndex == end.line
                let toColumn = isLastLine ? end.column : document.lineLength(lineIndex)

                let x0 = xOffset(ofColumn: fromColumn, line: lineIndex)
                var x1 = xOffset(ofColumn: toColumn, line: lineIndex)
                // A selection running through a line break shows the newline as a
                // sliver of highlight past the last character.
                if !isLastLine { x1 += charWidth * 0.5 }
                NSRect(x: x0, y: lineTop(lineIndex), width: max(1, x1 - x0), height: lineHeight).fill()
            }
        }
    }

    private func drawText(_ visible: VisibleLines, context: CGContext) {
        for lineIndex in visible.lines {
            let entry = cachedLine(lineIndex)
            if entry.text.isEmpty { continue }
            let baseline = lineTop(lineIndex) + baselineOffset
            context.saveGState()
            context.textMatrix = .identity
            context.translateBy(x: textOriginX, y: baseline)
            context.scaleBy(x: 1, y: -1)
            CTLineDraw(entry.ctLine, context)
            context.restoreGState()

            if showsInvisibles { drawInvisibles(entry.text, line: lineIndex) }
            drawFoldedIndicator(forLine: lineIndex)
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

    private func drawCarets(_ visible: VisibleLines) {
        guard isActive, caretVisible else { return }
        themeCaret.setFill()
        for region in selection.regions where visible.contains(region.head.line) {
            caretRect(for: region.head).fill()
        }
    }

    private func drawGutter(in dirtyRect: NSRect, context: CGContext, lines visible: VisibleLines?) {
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

        for lineIndex in visible.lines {
            // A triangle only where something can actually fold, so the gutter isn't a
            // column of decoration (T92).
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
        foldsDidEdit(fromLine: firstChangedLine)
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

/// The document lines on screen for one repaint, in screen order (T92).
///
/// Not a `ClosedRange`: with a region folded, the visible lines are no longer contiguous,
/// so drawing has to iterate an explicit list. `lowerBound`/`upperBound` and `contains`
/// keep the call sites that only need containment or clamping simple.
struct VisibleLines {
    let lines: [Int]
    private let lookup: Set<Int>

    init(lines: [Int]) {
        self.lines = lines
        self.lookup = Set(lines)
    }

    var lowerBound: Int { lines.first ?? 0 }
    var upperBound: Int { lines.last ?? 0 }

    /// True only for lines actually drawn — a line inside a collapsed region falls between
    /// the bounds but is not on screen.
    func contains(_ line: Int) -> Bool { lookup.contains(line) }
}
