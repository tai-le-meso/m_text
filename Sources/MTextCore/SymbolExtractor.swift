import Foundation

/// Extracts symbol-like names from a file's syntax highlighting — anything scoped
/// `entity.name.*` (functions, types, classes, methods, however each grammar's contexts
/// define it) — for "@symbol" Goto Anything (current file, T73) and the project-wide
/// symbol index (T74).
///
/// Synchronous and one-shot: builds a fresh `Highlighter` for the given grammar and
/// runs it to completion immediately, unlike `HighlightService`'s incremental/async
/// design (made for a single open document that keeps changing while it's on screen).
/// This is for extracting from a file's *current* content once — either the live
/// document for "current file" mode, or a `PieceTree` loaded from disk for the
/// project-wide index — not for keeping up with edits.
public enum SymbolExtractor {

    public struct Symbol: Equatable {
        public let name: String
        public let line: Int
        /// UTF-16 column within `line`, for placing the caret exactly on the symbol.
        public let column: Int
    }

    private static let entityNamePrefix = ScopeName("entity.name")

    /// `provider` is typically the live `TextDocument` (main thread only — matches
    /// `LineProvider`'s own documented rule) or a `PieceTree` snapshot (safe off-main).
    public static func extractSymbols(from provider: LineProvider, grammar: Grammar) -> [Symbol] {
        guard provider.lineCount > 0 else { return [] }
        let highlighter = Highlighter(grammar: grammar)
        highlighter.ensure(upToLine: provider.lineCount - 1, in: provider)

        var symbols: [Symbol] = []
        for line in 0 ..< provider.lineCount {
            let utf16 = Array(provider.line(line).utf16)
            for span in highlighter.spans(forLine: line, in: provider) {
                guard span.scopes.scopes.contains(where: { $0.isDescendant(of: entityNamePrefix) }) else { continue }

                let start = max(0, min(span.start, utf16.count))
                let end = max(start, min(span.end, utf16.count))
                guard end > start else { continue }
                let name = String(utf16CodeUnits: Array(utf16[start ..< end]), count: end - start)
                guard !name.isEmpty else { continue }

                symbols.append(Symbol(name: name, line: line, column: start))
            }
        }
        return symbols
    }
}
