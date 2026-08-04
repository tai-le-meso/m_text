import AppKit
import CoreText
import MTextCore

extension RGBAColor {
    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

/// Syntax highlighting, colour schemes and bracket matching in the view.
extension EditorView {

    // MARK: - Setup

    /// Installs the grammar registry and starts highlighting. Call after the document
    /// has content so the right grammar is picked.
    public func configureHighlighting(registry: GrammarRegistry, scheme: ColorScheme? = nil) {
        grammarRegistry = registry
        if let scheme { colorScheme = scheme }

        highlightService.onSpansReady = { [weak self] range in
            self?.spansArrived(for: range)
        }
        detectSyntax()
    }

    /// Picks a grammar from the file name and first line, then restarts highlighting.
    public func detectSyntax() {
        guard let registry = grammarRegistry else { return }
        let firstLine = document.lineCount > 0 ? document.line(0) : ""
        setGrammar(registry.grammar(for: document.fileURL, firstLine: firstLine))
    }

    /// `isManualChoice` records that the user picked this syntax, which switches off
    /// auto-detection until the document is replaced.
    public func setGrammar(_ grammar: Grammar, isManualChoice: Bool = false) {
        if isManualChoice { autoDetectsSyntax = false }
        highlightService.setGrammar(grammar, snapshot: document.snapshot())
        layout.invalidateAll()
        needsDisplay = true
        onChange?()
    }

    public var syntaxName: String { highlightService.grammar.name }
    public var syntaxScope: String { highlightService.grammar.scope.raw }

    /// Guesses the language from what's actually been typed or pasted, for the one case
    /// filename/first-line detection can't cover: an untitled buffer with nothing to go
    /// on but its content.
    ///
    /// Deliberately narrow, so it can never surprise anyone: only runs while still on
    /// Plain Text (a real extension-based match always wins and is never revisited),
    /// only for a document with no file on disk (a saved file's own detection already
    /// had its say), and never once the user has picked a syntax by hand
    /// (`autoDetectsSyntax` is exactly the flag that already protects that everywhere
    /// else). Throttled to roughly every 24 bytes of growth rather than every keystroke,
    /// since it re-scans the whole buffer each time.
    func attemptContentBasedDetection() {
        guard autoDetectsSyntax, grammarRegistry != nil, document.fileURL == nil,
              syntaxScope == "text.plain"
        else { return }

        let length = document.byteCount
        guard length >= 40, length - lastContentSniffLength >= 24 else { return }
        lastContentSniffLength = length

        guard let scope = ContentSniffer.detect(document.text),
              let grammar = grammarRegistry?.grammar(forScope: scope)
        else { return }
        setGrammar(grammar)
    }

    /// Line-comment token from the grammar, falling back to the extension guess.
    var grammarCommentToken: String? { highlightService.grammar.metadata.lineComment }

    // MARK: - Change plumbing

    /// Called from `didEdit` so the highlighter learns which line changed.
    func highlightingDidEdit(fromLine line: Int) {
        highlightService.documentChanged(snapshot: document.snapshot(), fromLine: line)
        matchedBrackets = nil
    }

    /// Queues the visible window ahead of the rest of the sweep.
    func requestVisibleHighlighting() {
        guard let range = visibleLineBounds(in: visibleRect) else { return }
        highlightService.prioritize(visibleLines: range, snapshot: document.snapshot())
    }

    private func spansArrived(for range: ClosedRange<Int>) {
        guard let visible = visibleLineBounds(in: visibleRect) else { return }
        // Only repaint if the new spans overlap what's on screen — a background sweep
        // through the rest of the file must not cause flicker.
        guard range.overlaps(visible) else { return }
        let lower = max(range.lowerBound, visible.lowerBound)
        let upper = min(range.upperBound, visible.upperBound)
        layout.invalidate(lines: lower ... upper)
        // Height in *rows*, not lines: with a region folded between `lower` and `upper`
        // the line count overstates how much of the screen those lines occupy, and the
        // invalidated rect would run past what actually changed (T92).
        let rows = folds.visualRow(forLine: upper) - folds.visualRow(forLine: lower) + 1
        setNeedsDisplay(NSRect(x: 0,
                               y: lineTop(lower),
                               width: bounds.width,
                               height: CGFloat(rows) * lineHeight))
    }

    // MARK: - Attributed line building

    /// Builds the attributed string for a line, applying scheme styles to each span.
    /// Returns nil when the line has no spans yet, so the caller draws it plain and
    /// repaints once highlighting catches up.
    func attributedLine(_ index: Int, text: String) -> NSAttributedString? {
        // nil means "not highlighted yet"; an empty span list means "highlighted, but
        // nothing to style" — returning nil for the latter would keep the line out of
        // the layout cache and re-shape it on every access.
        guard let spans = highlightService.spans(forLine: index) else { return nil }
        guard !spans.isEmpty else { return NSAttributedString(string: text, attributes: baseAttributes) }

        let result = NSMutableAttributedString(string: text, attributes: baseAttributes)
        let utf16Length = (text as NSString).length

        for span in spans {
            let start = max(0, min(span.start, utf16Length))
            let end = max(start, min(span.end, utf16Length))
            guard end > start else { continue }

            let style = colorScheme.style(for: span.scopes)
            var attributes: [NSAttributedString.Key: Any] = [:]
            if let foreground = style.foreground {
                attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] =
                    foreground.nsColor.cgColor
            }
            if !style.fontStyle.isPlain {
                attributes[.font] = styledFont(style.fontStyle)
            }
            if style.fontStyle.underline {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if !attributes.isEmpty {
                result.addAttributes(attributes, range: NSRange(location: start, length: end - start))
            }
        }
        return result
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        let color = colorScheme.globals.foreground?.nsColor ?? .labelColor
        attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = color.cgColor
        return attributes
    }

    /// Bold/italic variants of the editor font, cached because building traits is slow.
    func styledFont(_ style: FontStyle) -> NSFont {
        let key = (style.bold ? 1 : 0) | (style.italic ? 2 : 0)
        if let cached = styledFonts[key] { return cached }

        var traits: NSFontDescriptor.SymbolicTraits = []
        if style.bold { traits.insert(.bold) }
        if style.italic { traits.insert(.italic) }
        let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
        let resolved = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        styledFonts[key] = resolved
        return resolved
    }

    // MARK: - Theme colours

    var themeBackground: NSColor { colorScheme.globals.background?.nsColor ?? .textBackgroundColor }
    var themeCaret: NSColor { colorScheme.globals.caret?.nsColor ?? .controlAccentColor }
    var themeInvisibles: NSColor { colorScheme.globals.invisibles?.nsColor ?? .tertiaryLabelColor }
    var themeGutterBackground: NSColor { colorScheme.globals.gutterBackground?.nsColor ?? themeBackground }
    var themeGutterForeground: NSColor { colorScheme.globals.gutterForeground?.nsColor ?? .tertiaryLabelColor }

    var themeSelection: NSColor {
        if isActive { return colorScheme.globals.selection?.nsColor ?? .selectedTextBackgroundColor }
        return colorScheme.globals.inactiveSelection?.nsColor ?? .unemphasizedSelectedTextBackgroundColor
    }

    var themeLineHighlight: NSColor {
        colorScheme.globals.lineHighlight?.nsColor ?? NSColor.textColor.withAlphaComponent(0.05)
    }

    public func setColorScheme(_ scheme: ColorScheme) {
        colorScheme = scheme
        layout.invalidateAll()
        needsDisplay = true
    }

    // MARK: - Bracket matching

    /// Recomputes the matching bracket pair around the primary caret.
    func updateBracketMatch() {
        guard !selection.isMultiple, selection.primary.isEmpty else {
            matchedBrackets = nil
            return
        }
        let probe = BracketMatcher.scopeProbe(document: document) { [weak self] line in
            self?.highlightService.spans(forLine: line)
        }
        let matcher = BracketMatcher(document: document, isIgnored: probe)
        matchedBrackets = matcher.match(at: selection.primary.head)
    }

    func drawBracketMatch(_ visible: VisibleLines) {
        guard let match = matchedBrackets else { return }
        let color = match.isUnbalanced
            ? NSColor.systemRed.withAlphaComponent(0.35)
            : NSColor.labelColor.withAlphaComponent(0.18)
        color.setFill()

        for position in [match.open, match.close].compactMap({ $0 }) where visible.contains(position.line) {
            let x0 = xOffset(ofColumn: position.column, line: position.line)
            let x1 = xOffset(ofColumn: position.column + 1, line: position.line)
            NSRect(x: x0, y: lineTop(position.line), width: max(2, x1 - x0), height: lineHeight).fill()
        }
    }
}
