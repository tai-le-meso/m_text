import Foundation

/// Incremental syntax highlighting over a document snapshot.
///
/// The trick is the per-line entry-state cache. After an edit on line *n*, only lines
/// from *n* onward can change — and re-scanning stops as soon as a line's entry state
/// matches what it was before, because from there on the output is provably identical.
/// For a typical edit that is one line of work regardless of file size.
public final class Highlighter {

    public private(set) var grammar: Grammar
    private var tokenizer: Tokenizer

    /// Entry state for each line. `states[i]` is the state *before* line i is scanned.
    private var states: [TokenizerState] = []
    /// Cached spans per line, in UTF-16 offsets within the line.
    private var lineSpans: [Int: [ScopeSpan]] = [:]
    /// First line whose cached state may be wrong.
    private var dirtyLine = 0
    private var lineCount = 0

    public init(grammar: Grammar) {
        self.grammar = grammar
        self.tokenizer = Tokenizer(grammar: grammar)
    }

    public func setGrammar(_ grammar: Grammar) {
        self.grammar = grammar
        self.tokenizer = Tokenizer(grammar: grammar)
        invalidateAll()
    }

    public func invalidateAll() {
        states.removeAll(keepingCapacity: true)
        lineSpans.removeAll(keepingCapacity: true)
        dirtyLine = 0
        lineCount = 0
    }

    /// Marks everything from `line` onward as needing a re-scan.
    ///
    /// Cached spans below the convergence point are deliberately kept: once a line's
    /// entry state matches, its output is provably unchanged. Spans are only discarded
    /// wholesale when the line *count* changes, since they are keyed by line index —
    /// see `syncLineCount`.
    public func invalidate(fromLine line: Int) {
        dirtyLine = min(dirtyLine, max(0, line))
    }

    /// True when there is still work queued.
    public var hasPendingWork: Bool { dirtyLine < lineCount }
    public var highlightedLineCount: Int { min(dirtyLine, lineCount) }

    /// Spans for `line`, highlighting on demand up to that point if needed.
    ///
    /// `provider` supplies line text — a `PieceTree` snapshot in the background actor,
    /// or the live document on the main thread.
    public func spans(forLine line: Int, in provider: LineProvider) -> [ScopeSpan] {
        ensure(upToLine: line, in: provider)
        return lineSpans[line] ?? []
    }

    /// Scans forward until `line` is covered.
    public func ensure(upToLine line: Int, in provider: LineProvider) {
        syncLineCount(provider.lineCount)
        guard line >= dirtyLine else { return }
        _ = highlight(from: dirtyLine, through: line, in: provider, budget: Int.max)
    }

    /// Advances highlighting by at most `budget` lines. Returns the range that changed,
    /// so a caller can repaint just those lines.
    @discardableResult
    public func advance(in provider: LineProvider, budget: Int) -> ClosedRange<Int>? {
        syncLineCount(provider.lineCount)
        guard budget > 0, dirtyLine < lineCount else { return nil }
        let start = dirtyLine
        // `through: start` asks for the minimum, so the convergence check can fire from
        // the very next line; `budget` caps how far the sweep actually runs. Passing the
        // budget as the range instead would put the converged lines inside `end`, where
        // the check is suppressed — which is what made every edit re-scan the file.
        let stopped = highlight(from: start, through: start, in: provider, budget: budget)
        return start <= stopped ? start ... stopped : nil
    }

    // MARK: - Core loop

    private func syncLineCount(_ count: Int) {
        guard count != lineCount else { return }
        // Spans are keyed by line index, so inserting or removing a line shifts every
        // cached entry below the edit. Cheaper and safer to drop them all than to
        // renumber, and the re-scan is bounded by convergence anyway.
        lineSpans.removeAll(keepingCapacity: true)
        if count < lineCount {
            states.removeSubrange(min(count, states.count) ..< states.count)
        }
        lineCount = count
        dirtyLine = 0
    }

    /// Returns the last line actually scanned.
    private func highlight(from start: Int, through end: Int,
                           in provider: LineProvider, budget: Int) -> Int {
        guard lineCount > 0 else { return start }
        let first = max(0, min(start, lineCount - 1))
        var state = entryState(forLine: first)
        var line = first
        var scanned = 0
        var lastScanned = first
        var converged = false

        while line < lineCount, scanned < budget {
            // Convergence: past the requested range, if this line's entry state is
            // unchanged then nothing below it can differ either.
            if line > end, line < states.count, states[line] == state {
                converged = true
                break
            }

            storeState(state, forLine: line)
            let text = provider.line(line)
            let result = tokenizer.tokenize(line: text, state: state)
            lineSpans[line] = result.spans
            state = result.state

            lastScanned = line
            line += 1
            scanned += 1
        }

        // Record the state at the boundary we stopped on so a later pass resumes here.
        if line < lineCount { storeState(state, forLine: line) }
        // Converging proves every remaining line is already correct — marking only up
        // to `line` would make the next pass re-scan the rest of the file, which is
        // exactly the O(file) behaviour this class exists to avoid.
        dirtyLine = max(dirtyLine, converged ? lineCount : line)
        return lastScanned
    }

    private func entryState(forLine line: Int) -> TokenizerState {
        guard line > 0, line < states.count else { return .initial(for: grammar) }
        return states[line]
    }

    private func storeState(_ state: TokenizerState, forLine line: Int) {
        if states.count <= line {
            states.append(contentsOf: Array(repeating: TokenizerState.initial(for: grammar),
                                            count: line - states.count + 1))
        }
        states[line] = state
    }
}

/// Line-oriented text source, so the highlighter can run against either a live
/// document or an immutable snapshot.
///
/// Only the `PieceTree` conformance is safe to use off the owning thread. The
/// `TextDocument` conformance mutates internal caches on read and must stay on the
/// thread that owns the document.
public protocol LineProvider {
    var lineCount: Int { get }
    func line(_ index: Int) -> String
}

extension PieceTree: LineProvider {
    public func line(_ index: Int) -> String { lineText(index) }
}

extension TextDocument: LineProvider {}
