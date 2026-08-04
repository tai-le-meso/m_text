import Foundation

/// Scope-aware bracket matching.
///
/// The scope check is what makes it usable: a `}` inside a string or comment must not
/// pair with real code, so candidates whose scope stack contains `string` or `comment`
/// are skipped — unless the caret itself is inside one, in which case only same-kind
/// brackets are considered.
public struct BracketMatcher {

    public static let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}"]
    private static let closers: [Character: Character] = [")": "(", "]": "[", "}": "{"]

    /// A matched pair. Either side may be nil when the partner is missing.
    public struct MatchResult {
        public let open: Position?
        public let close: Position?
        public var isUnbalanced: Bool { open == nil || close == nil }
    }

    /// Scan ceiling, so an unbalanced brace in a huge file cannot stall a redraw.
    public var lineBudget = 5_000

    /// Reports whether a position is inside a string or comment.
    public typealias ScopeProbe = (Position) -> Bool

    private let document: TextDocument
    private let isIgnored: ScopeProbe

    public init(document: TextDocument, isIgnored: ScopeProbe? = nil) {
        self.document = document
        self.isIgnored = isIgnored ?? { _ in false }
    }

    /// Builds a probe from a highlight service: text scoped as string or comment is
    /// ignored when pairing brackets.
    public static func scopeProbe(document: TextDocument,
                                  spans: @escaping (Int) -> [ScopeSpan]?) -> ScopeProbe {
        { position in
            guard let lineSpans = spans(position.line) else { return false }
            let text = document.line(position.line)
            let index = text.index(text.startIndex, offsetBy: max(0, min(position.column, text.count)))
            let utf16Offset = text.utf16.distance(from: text.utf16.startIndex, to: index)
            guard let span = lineSpans.first(where: { utf16Offset >= $0.start && utf16Offset < $0.end })
            else { return false }
            return span.scopes.scopes.contains { scope in
                scope.components.first == "string" || scope.components.first == "comment"
            }
        }
    }

    /// Finds the pair for the bracket adjacent to `caret` — checking the character
    /// after the caret first, then the one before, which is what editors do.
    public func match(at caret: Position) -> MatchResult? {
        let p = document.clamp(caret)
        let text = document.line(p.line)
        let characters = Array(text)

        if p.column < characters.count {
            let character = characters[p.column]
            let here = Position(line: p.line, column: p.column)
            if BracketMatcher.pairs[character] != nil, !isIgnored(here) {
                return MatchResult(open: here, close: findForward(from: here, open: character))
            }
            if BracketMatcher.closers[character] != nil, !isIgnored(here) {
                return MatchResult(open: findBackward(from: here, close: character), close: here)
            }
        }
        if p.column > 0 {
            let character = characters[p.column - 1]
            let here = Position(line: p.line, column: p.column - 1)
            if BracketMatcher.closers[character] != nil, !isIgnored(here) {
                return MatchResult(open: findBackward(from: here, close: character), close: here)
            }
            if BracketMatcher.pairs[character] != nil, !isIgnored(here) {
                return MatchResult(open: here, close: findForward(from: here, open: character))
            }
        }
        return nil
    }

    // MARK: - Scanning

    private func findForward(from start: Position, open: Character) -> Position? {
        guard let close = BracketMatcher.pairs[open] else { return nil }
        var depth = 0
        let lastLine = min(document.lineCount - 1, start.line + lineBudget)

        for line in start.line ... lastLine {
            let characters = Array(document.line(line))
            let from = line == start.line ? start.column : 0
            guard from <= characters.count else { continue }
            for column in from ..< characters.count {
                let character = characters[column]
                guard character == open || character == close else { continue }
                let here = Position(line: line, column: column)
                if isIgnored(here) { continue }
                if character == open {
                    depth += 1
                } else {
                    depth -= 1
                    if depth == 0 { return here }
                }
            }
        }
        return nil
    }

    private func findBackward(from start: Position, close: Character) -> Position? {
        guard let open = BracketMatcher.closers[close] else { return nil }
        var depth = 0
        let firstLine = max(0, start.line - lineBudget)

        for line in stride(from: start.line, through: firstLine, by: -1) {
            let characters = Array(document.line(line))
            let upper = line == start.line ? min(start.column, characters.count - 1) : characters.count - 1
            guard upper >= 0 else { continue }
            for column in stride(from: upper, through: 0, by: -1) {
                let character = characters[column]
                guard character == open || character == close else { continue }
                let here = Position(line: line, column: column)
                if isIgnored(here) { continue }
                if character == close {
                    depth += 1
                } else {
                    depth -= 1
                    if depth == 0 { return here }
                }
            }
        }
        return nil
    }
}
