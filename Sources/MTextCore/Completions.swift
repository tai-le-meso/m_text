import Foundation

/// One candidate offered by autocomplete (T90).
public struct CompletionItem: Equatable {

    public enum Kind: Equatable {
        /// A word that already appears somewhere in this buffer.
        case bufferWord
        /// A declaration found by `SymbolExtractor`/`SymbolIndex`.
        case symbol
    }

    public let text: String
    public let kind: Kind
    /// Shown dimmed beside the name — `"Foo.swift:42"` for a project symbol, nil for a
    /// plain buffer word (where the buffer *is* the context, so there's nothing to add).
    public let detail: String?
    /// Which characters of `text` the query matched, for bolding in the popup. Same shape
    /// `PaletteItem` already uses.
    public let matchedIndices: [Int]

    public init(text: String, kind: Kind, detail: String? = nil, matchedIndices: [Int] = []) {
        self.text = text
        self.kind = kind
        self.detail = detail
        self.matchedIndices = matchedIndices
    }
}

/// Gathers and ranks completion candidates.
///
/// Deliberately pure and platform-free: the caller supplies the word list and the symbol
/// list, this decides what to offer and in what order. That keeps the ranking policy unit
/// testable without a window, and lets the same code serve the current-file symbols
/// (`SymbolExtractor`) and the project-wide ones (`SymbolIndex`) without knowing which is
/// which.
public enum CompletionEngine {

    /// Words shorter than this are never *offered* — completing "if" to "in" costs more
    /// keystrokes than typing it. They can still be typed as a prefix.
    public static let minimumWordLength = 3

    /// Caps the buffer scan the way `SymbolIndex` and Goto Anything's `#text` mode cap
    /// theirs, so a pathological file can't turn every keystroke into a full-document walk.
    public static let maximumLinesScanned = 20_000

    /// Matches `identifierUnderCaret` in `MainWindowController` (Goto Definition) so a
    /// word means the same thing in both features.
    public static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    /// The partial identifier immediately before `position` — what the user is typing, and
    /// what gets replaced when a candidate is committed.
    ///
    /// Looks only *backwards*: the caret sitting in the middle of an existing word means
    /// the tail belongs to that word, not to the thing being completed, and swallowing it
    /// would silently rewrite text to the right of the caret.
    public static func prefix(in document: TextDocument, before position: Position) -> String {
        let characters = Array(document.line(position.line))
        let column = max(0, min(position.column, characters.count))
        var start = column
        while start > 0, isIdentifierCharacter(characters[start - 1]) { start -= 1 }
        return String(characters[start ..< column])
    }

    /// Every distinct identifier-like word in the document, unordered.
    public static func bufferWords(in document: TextDocument) -> [String] {
        var seen = Set<String>()
        let limit = min(document.lineCount, maximumLinesScanned)
        for index in 0 ..< limit {
            var current = ""
            for character in document.line(index) {
                if isIdentifierCharacter(character) {
                    current.append(character)
                } else {
                    if current.count >= minimumWordLength { seen.insert(current) }
                    current = ""
                }
            }
            if current.count >= minimumWordLength { seen.insert(current) }
        }
        return Array(seen)
    }

    /// Ranks candidates against `prefix` and returns at most `limit` items.
    ///
    /// Ordering comes from the shared `FuzzyMatcher` (T70) rather than a second scorer, so
    /// ⌘P, ⌘⇧P and autocomplete all agree on what "a good match" means — its
    /// word-boundary and consecutive-run bonuses already float true prefix matches to the
    /// top, which is what a completion list wants.
    ///
    /// A symbol and a buffer word with the same text collapse to one entry, keeping the
    /// symbol: a declaration carries a location worth showing, and offering the same
    /// identifier twice is noise.
    public static func complete(prefix: String,
                                bufferWords: [String],
                                symbols: [CompletionItem],
                                limit: Int = 50) -> [CompletionItem] {
        var byText: [String: CompletionItem] = [:]
        for symbol in symbols where symbol.text.count >= minimumWordLength {
            byText[symbol.text] = symbol
        }
        for word in bufferWords where byText[word] == nil {
            byText[word] = CompletionItem(text: word, kind: .bufferWord)
        }
        // Never offer exactly what has already been typed — accepting it would be a no-op,
        // and it pushes a genuinely useful candidate off the end of the list.
        byText.removeValue(forKey: prefix)

        let candidates = Array(byText.values)
        guard !prefix.isEmpty else {
            // Explicit trigger on empty prefix (⌃Space at a non-word position): no query
            // to rank by, so offer a stable alphabetical list rather than hash order.
            return candidates
                .sorted { $0.text.lowercased() < $1.text.lowercased() }
                .prefix(limit)
                .map { $0 }
        }

        let ranked = FuzzyMatcher.rank(query: prefix, candidates: candidates.map(\.text))
        return ranked.prefix(limit).map { entry in
            let candidate = candidates[entry.index]
            return CompletionItem(text: candidate.text,
                                  kind: candidate.kind,
                                  detail: candidate.detail,
                                  matchedIndices: entry.match.indices)
        }
    }
}

/// Caches one document's buffer words, invalidated by `TextDocument.generation`.
///
/// Autocomplete re-queries on every keystroke, and rescanning the whole buffer that often
/// is the obvious way to make typing feel slow. Keying the cache on the document's
/// existing edit counter — the same mechanism `LayoutCache` and `HighlightService` use to
/// spot stale work — means a run of keystrokes that only extends the current word reuses
/// one scan. The word being typed is filtered at *rank* time, not scan time, so it doesn't
/// invalidate anything.
public final class BufferWordIndex {

    private var cachedGeneration: UInt64?
    private var cachedWords: [String] = []

    public init() {}

    public func words(in document: TextDocument) -> [String] {
        if cachedGeneration == document.generation { return cachedWords }
        cachedWords = CompletionEngine.bufferWords(in: document)
        cachedGeneration = document.generation
        return cachedWords
    }

    public func invalidate() {
        cachedGeneration = nil
        cachedWords = []
    }
}
