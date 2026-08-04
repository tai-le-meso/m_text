import Foundation

/// Runs the incremental highlighter off the main thread and publishes finished spans
/// back to it.
///
/// Ownership rules, which the whole design depends on:
/// - `highlighter` is touched **only** on `queue`.
/// - `published` and `generation` are touched **only** on the main thread.
/// - work always runs against an immutable `PieceTree` snapshot, never the live
///   document, and every batch carries the generation it was computed from so stale
///   results are dropped rather than painted.
///
/// Lines not yet highlighted simply draw unstyled and are repainted when their batch
/// arrives, which is what makes opening a large file feel instant.
public final class HighlightService {

    /// Called on the main thread when new spans are available for a line range.
    public var onSpansReady: ((ClosedRange<Int>) -> Void)?

    /// Lines highlighted per background batch. Small enough to publish promptly,
    /// large enough that the hop back to main isn't the bottleneck.
    /// A `let` so the background queue can read it without crossing ownership.
    public let batchSize = 500

    private let queue = DispatchQueue(label: "io.mesoneer.mtext.highlight", qos: .userInitiated)

    // Background-only state.
    private var highlighter: Highlighter

    // Main-thread-only state.
    private var published: [Int: [ScopeSpan]] = [:]
    private var generation: UInt64 = 0
    private var inFlight = false
    /// Queued follow-up sweep. `fromLine` is nil when nothing changed and we only need
    /// the sweep to reach further.
    private var pending: (snapshot: PieceTree, fromLine: Int?)?
    private var priorityRange: ClosedRange<Int>?

    public private(set) var grammar: Grammar

    public init(grammar: Grammar = .plainText()) {
        self.grammar = grammar
        self.highlighter = Highlighter(grammar: grammar)
    }

    // MARK: - Main-thread API

    /// Spans for a line, or nil when it has not been highlighted yet.
    public func spans(forLine line: Int) -> [ScopeSpan]? {
        published[line]
    }

    public func setGrammar(_ grammar: Grammar, snapshot: PieceTree) {
        self.grammar = grammar
        generation &+= 1
        published.removeAll(keepingCapacity: true)
        // Drop queued work: it belongs to the previous grammar, and replaying it later
        // would stamp stale spans with the current generation.
        pending = nil
        priorityRange = nil
        inFlight = false

        queue.async { [weak self] in
            self?.highlighter.setGrammar(grammar)
        }
        schedule(snapshot: snapshot, invalidateFrom: 0)
    }

    /// Tell the service the document changed at or after `line`.
    public func documentChanged(snapshot: PieceTree, fromLine line: Int) {
        generation &+= 1
        // Spans at or after the edit are no longer trustworthy.
        for key in published.keys where key >= line { published[key] = nil }
        schedule(snapshot: snapshot, invalidateFrom: line)
    }

    /// Highlight the visible range first, so scrolling into un-highlighted territory
    /// colours in immediately rather than waiting for the sweep to reach it.
    ///
    /// Deliberately does **not** invalidate: this is a request to get ahead of the
    /// sweep, not a signal that anything changed.
    public func prioritize(visibleLines range: ClosedRange<Int>, snapshot: PieceTree) {
        guard range.contains(where: { published[$0] == nil }) else { return }
        priorityRange = range
        schedule(snapshot: snapshot, invalidateFrom: nil)
    }

    public func reset() {
        generation &+= 1
        published.removeAll(keepingCapacity: true)
        pending = nil
        priorityRange = nil
        inFlight = false
        let grammar = self.grammar
        queue.async { [weak self] in
            self?.highlighter.setGrammar(grammar)
        }
    }

    // MARK: - Scheduling

    /// `invalidateFrom` is nil when the document has not changed and we only want the
    /// sweep to reach further.
    private func schedule(snapshot: PieceTree, invalidateFrom line: Int?) {
        // Coalesce: while a sweep is running, keep only the earliest dirty line.
        if inFlight {
            switch (pending?.fromLine, line) {
            case (let existing?, let incoming?): pending = (snapshot, min(existing, incoming))
            case (nil, let incoming?): pending = (snapshot, incoming)
            case (let existing?, nil): pending = (snapshot, existing)
            case (nil, nil): pending = (snapshot, nil)
            }
            return
        }
        inFlight = true
        let stamp = generation
        let priority = priorityRange
        queue.async { [weak self] in
            guard let self else { return }
            if let line { self.highlighter.invalidate(fromLine: line) }
            if let priority {
                // Warm the visible window first, then let the sweep continue.
                self.publish(self.highlighter.spansBatch(for: priority, in: snapshot),
                             generation: stamp)
            }
            self.run(snapshot: snapshot, generation: stamp)
        }
    }

    /// Background sweep: advances in batches, publishing each one.
    private func run(snapshot: PieceTree, generation stamp: UInt64) {
        while let range = highlighter.advance(in: snapshot, budget: batchSize) {
            publish(highlighter.spansBatch(for: range, in: snapshot), generation: stamp)
            if !highlighter.hasPendingWork { break }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.inFlight = false
            self.priorityRange = nil
            if let next = self.pending {
                self.pending = nil
                self.schedule(snapshot: next.snapshot, invalidateFrom: next.fromLine)
            }
        }
    }

    /// Hops a finished batch to the main thread, dropping it if the document moved on.
    private func publish(_ batch: [Int: [ScopeSpan]], generation stamp: UInt64) {
        guard !batch.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, stamp == self.generation else { return }
            var lowest = Int.max
            var highest = Int.min
            for (line, spans) in batch {
                self.published[line] = spans
                lowest = min(lowest, line)
                highest = max(highest, line)
            }
            if lowest <= highest { self.onSpansReady?(lowest ... highest) }
        }
    }
}

public extension Highlighter {
    /// Spans for a whole line range, as a batch ready to publish.
    func spansBatch(for range: ClosedRange<Int>, in provider: LineProvider) -> [Int: [ScopeSpan]] {
        var batch: [Int: [ScopeSpan]] = [:]
        let upper = min(range.upperBound, provider.lineCount - 1)
        guard range.lowerBound <= upper else { return batch }
        for line in range.lowerBound ... upper {
            batch[line] = spans(forLine: line, in: provider)
        }
        return batch
    }
}
