import Foundation

/// One entry on the tokenizer's context stack.
///
/// Carries what must be undone when the context is popped: how many meta scopes it
/// pushed, and any scopes `clear_scopes` removed — without the latter, a single
/// `clear_scopes` context would strip the root scope for the rest of the file.
public struct ContextFrame: Equatable {
    public var name: String
    public var metaScopeCount: Int
    public var metaContentScopeCount: Int
    public var clearedScopes: [ScopeName]

    init(name: String, metaScopeCount: Int = 0, metaContentScopeCount: Int = 0,
         clearedScopes: [ScopeName] = []) {
        self.name = name
        self.metaScopeCount = metaScopeCount
        self.metaContentScopeCount = metaContentScopeCount
        self.clearedScopes = clearedScopes
    }
}

/// The tokenizer's state at a line boundary: the open context frames plus the scope
/// stack they contribute.
///
/// Equatable because the incremental highlighter stops re-scanning as soon as a line's
/// entry state matches what it was before — that comparison is the whole optimisation.
public struct TokenizerState: Equatable {
    public var frames: [ContextFrame]
    public var scopes: ScopeStack

    init(frames: [ContextFrame], scopes: ScopeStack) {
        self.frames = frames
        self.scopes = scopes
    }

    public var contextNames: [String] { frames.map(\.name) }
    var currentContext: String { frames.last?.name ?? Grammar.entryContext }

    /// Entry state for the first line: the `main` context, with its own meta scopes
    /// applied, on top of the grammar's root scope.
    public static func initial(for grammar: Grammar) -> TokenizerState {
        var state = TokenizerState(frames: [], scopes: ScopeStack([grammar.scope]))
        let main = grammar.context(named: Grammar.entryContext) ?? Context(name: Grammar.entryContext)
        state.enter(main)
        return state
    }

    mutating func enter(_ context: Context) {
        var cleared: [ScopeName] = []
        if context.clearScopes > 0 {
            let removeCount = min(context.clearScopes, scopes.scopes.count)
            cleared = Array(scopes.scopes.suffix(removeCount))
            scopes = ScopeStack(Array(scopes.scopes.dropLast(removeCount)))
        }
        scopes.push(contentsOf: context.metaScope)
        scopes.push(contentsOf: context.metaContentScope)
        frames.append(ContextFrame(name: context.name,
                                   metaScopeCount: context.metaScope.count,
                                   metaContentScopeCount: context.metaContentScope.count,
                                   clearedScopes: cleared))
    }

    /// Pops the innermost frame. The entry context is never popped.
    mutating func leave() {
        guard frames.count > 1, let frame = frames.popLast() else { return }
        for _ in 0 ..< (frame.metaScopeCount + frame.metaContentScopeCount) { scopes.pop() }
        if !frame.clearedScopes.isEmpty {
            scopes = ScopeStack(frame.clearedScopes + scopes.scopes)
        }
    }

    /// Scope stack with the innermost frame's `meta_content_scope` removed — the scopes
    /// that apply to a closing delimiter, which `meta_scope` covers but content does not.
    func scopesExcludingContentScope() -> ScopeStack {
        guard let frame = frames.last, frame.metaContentScopeCount > 0 else { return scopes }
        let keep = max(0, scopes.scopes.count - frame.metaContentScopeCount)
        return ScopeStack(Array(scopes.scopes.prefix(keep)))
    }
}

/// Runs a grammar's context stack machine over one line at a time.
///
/// Line-at-a-time is deliberate: it is what makes the highlighter incremental, since a
/// line's output depends only on its text plus the entry state.
public struct Tokenizer {

    public let grammar: Grammar
    /// Ceiling on matches per line, so a pathological grammar cannot hang the editor.
    public var matchLimit = 10_000

    public init(grammar: Grammar) {
        self.grammar = grammar
    }

    /// Tokenizes `line` (without its newline) starting from `state`.
    /// Span offsets are UTF-16 units within the line, matching what CoreText wants.
    public func tokenize(line: String, state initialState: TokenizerState) -> (spans: [ScopeSpan], state: TokenizerState) {
        var state = initialState
        var spans: [ScopeSpan] = []
        let length = line.utf16.count
        var position = 0
        var iterations = 0
        var lastZeroWidthPosition = -1

        while position <= length {
            iterations += 1
            if iterations > matchLimit { break }

            guard let hit = nextMatch(in: line, from: position, state: state) else { break }
            let matchStart = hit.match.range.location
            let matchEnd = matchStart + hit.match.range.length

            // Text before the match carries the enclosing scopes only.
            if matchStart > position {
                spans.append(ScopeSpan(start: position, end: matchStart, scopes: state.scopes))
            }

            // Scopes for the delimiter itself depend on the transition: an opening
            // delimiter is inside the new context's meta_scope but not its content
            // scope, and a closing delimiter is the mirror image.
            let delimiterBase = baseScopes(for: hit.pattern.action, state: state)
            let matchScopes = delimiterBase.pushing(hit.pattern.scopes)
            if matchEnd > matchStart {
                spans.append(contentsOf: captureSpans(hit: hit,
                                                      baseScopes: matchScopes,
                                                      matchRange: hit.match.range))
            }

            let previousState = state
            apply(hit.pattern.action, to: &state)

            // A zero-width match must still make progress.
            if matchEnd == matchStart {
                if matchStart == lastZeroWidthPosition && state == previousState { break }
                lastZeroWidthPosition = matchStart
                position = state == previousState ? matchStart + 1 : matchStart
                if position > length { break }
                continue
            }
            position = matchEnd
        }

        if position < length {
            spans.append(ScopeSpan(start: position, end: length, scopes: state.scopes))
        }
        return (merge(spans), state)
    }

    // MARK: - Matching

    private struct Hit {
        let pattern: Pattern
        let match: CompiledRegex.Match
    }

    /// Leftmost match among the current context's patterns, with the prototype merged
    /// in. Ties go to the pattern declared first, which is what Sublime specifies.
    private func nextMatch(in line: String, from position: Int, state: TokenizerState) -> Hit? {
        guard let context = grammar.context(named: state.currentContext) else { return nil }

        var candidates = context.patterns
        if context.includesPrototype, !grammar.prototype.isEmpty {
            candidates = grammar.prototype + candidates
        }

        var best: Hit?
        for pattern in candidates {
            guard let regex = pattern.regex else { continue }
            guard let match = regex.firstMatch(in: line, from: position) else { continue }
            if let current = best, match.range.location >= current.match.range.location { continue }
            best = Hit(pattern: pattern, match: match)
            // Nothing can beat a match starting exactly at the cursor.
            if match.range.location == position { break }
        }
        return best
    }

    /// Scopes in effect for the matched delimiter text.
    private func baseScopes(for action: PatternAction, state: TokenizerState) -> ScopeStack {
        switch action {
        case .push(let names), .set(let names):
            // meta_scope of the context being entered covers its opening delimiter.
            guard let first = names.first, let context = grammar.context(named: first),
                  !context.metaScope.isEmpty else { return state.scopes }
            return state.scopes.pushing(context.metaScope)
        case .pop:
            // meta_scope still applies to the closing delimiter; content scope does not.
            return state.scopesExcludingContentScope()
        case .none:
            return state.scopes
        }
    }

    /// Splits a match into spans so capture groups get their own scopes.
    private func captureSpans(hit: Hit, baseScopes: ScopeStack, matchRange: NSRange) -> [ScopeSpan] {
        guard !hit.pattern.captures.isEmpty else {
            return [ScopeSpan(start: matchRange.location,
                              end: matchRange.location + matchRange.length,
                              scopes: baseScopes)]
        }

        // Layer scopes per UTF-16 unit, then coalesce. Matches are short, so this
        // costs less than interval bookkeeping.
        let start = matchRange.location
        let end = start + matchRange.length
        var layers = [ScopeStack](repeating: baseScopes, count: max(0, end - start))

        // Group 0 is the whole match and is already covered by baseScopes.
        for (group, scopes) in hit.pattern.captures.sorted(by: { $0.key < $1.key }) where group > 0 {
            guard let range = hit.match.groups[group], range.location != NSNotFound else { continue }
            let from = max(start, range.location)
            let to = min(end, range.location + range.length)
            guard from < to else { continue }
            for index in (from - start) ..< (to - start) {
                layers[index] = layers[index].pushing(scopes)
            }
        }

        var spans: [ScopeSpan] = []
        guard !layers.isEmpty else { return spans }
        var runStart = 0
        for index in 1 ... layers.count {
            // Short-circuits before the out-of-bounds read on the final iteration.
            if index == layers.count || layers[index] != layers[runStart] {
                spans.append(ScopeSpan(start: start + runStart,
                                       end: start + index,
                                       scopes: layers[runStart]))
                runStart = index
            }
        }
        return spans
    }

    // MARK: - Stack transitions

    private func apply(_ action: PatternAction, to state: inout TokenizerState) {
        switch action {
        case .none:
            break
        case .push(let names):
            for name in names { enter(name, in: &state) }
        case .pop(let count):
            for _ in 0 ..< max(1, count) { state.leave() }
        case .set(let names):
            state.leave()
            for name in names { enter(name, in: &state) }
        }
    }

    private func enter(_ name: String, in state: inout TokenizerState) {
        guard let context = grammar.context(named: name) else { return }
        state.enter(context)
    }

    /// Coalesces adjacent spans carrying the same scopes, which keeps the attributed
    /// string the renderer builds small.
    private func merge(_ spans: [ScopeSpan]) -> [ScopeSpan] {
        guard spans.count > 1 else { return spans.filter { $0.length > 0 } }
        var result: [ScopeSpan] = []
        for span in spans where span.length > 0 {
            if var last = result.last, last.end == span.start, last.scopes == span.scopes {
                last.end = span.end
                result[result.count - 1] = last
            } else {
                result.append(span)
            }
        }
        return result
    }
}
