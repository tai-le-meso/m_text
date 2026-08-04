import Foundation

/// Live find/replace state for one document: the current query, its matches, which
/// match is selected, and the replace operations.
///
/// Owns no UI. The find bar drives it and reads `matchCount`/`currentIndex` back, which
/// keeps the search logic testable without AppKit.
public final class SearchSession {

    public private(set) var query = SearchQuery()
    /// All matches for the current query, in document order.
    public private(set) var matches: [SearchMatch] = []
    /// Index into `matches`, or nil when nothing is selected yet.
    public private(set) var currentIndex: Int?
    /// Non-nil when the pattern does not compile, for display in the find bar.
    public private(set) var errorMessage: String?

    /// Limits the search to these regions when set — "Find in Selection".
    public var scope: Selection? {
        didSet { if scope != oldValue { refresh(force: true) } }
    }

    private unowned let document: TextDocument
    /// What the current match list was actually computed from. Comparing against these
    /// is what makes `refresh` both cheap and correct — checking only the document
    /// generation would let a *new query* reuse the old query's matches, and Replace
    /// would then overwrite text that no longer matches.
    private var generation: UInt64 = .max
    private var computedQuery: SearchQuery?
    private var computedScope: Selection?

    public init(document: TextDocument) {
        self.document = document
    }

    public var matchCount: Int { matches.count }
    public var isEmpty: Bool { query.isEmpty }

    public var currentMatch: SearchMatch? {
        guard let currentIndex, matches.indices.contains(currentIndex) else { return nil }
        return matches[currentIndex]
    }

    /// "3 of 17", or nil when there is nothing to report.
    public var statusText: String? {
        guard !query.isEmpty else { return nil }
        if let errorMessage { return errorMessage }
        guard !matches.isEmpty else { return "No results" }
        if let currentIndex { return "\(currentIndex + 1) of \(matches.count)" }
        return "\(matches.count) results"
    }

    // MARK: - Query

    /// Sets the query and recomputes matches. `near` seeds which match is selected, so
    /// typing in the find bar highlights the one nearest the caret.
    public func setQuery(_ query: SearchQuery, near position: Position? = nil) {
        self.query = query
        refresh(near: position)
    }

    /// Recomputes the match list. Cheap to call — it no-ops when nothing has changed.
    public func refresh(near position: Position? = nil, force: Bool = false) {
        guard force
            || generation != document.generation
            || computedQuery != query
            || computedScope != scope
        else { return }

        generation = document.generation
        computedQuery = query
        computedScope = scope
        errorMessage = SearchMatcher.validate(query)

        guard errorMessage == nil, !query.isEmpty else {
            matches = []
            currentIndex = nil
            return
        }
        let hadSelection = currentIndex != nil
        matches = scope.map { document.findAll(query, in: $0) } ?? document.findAll(query)

        if matches.isEmpty {
            currentIndex = nil
        } else if position != nil || !hadSelection {
            currentIndex = indexOfMatch(atOrAfter: position)
        } else {
            // No hint and something was already selected: keep it in range rather than
            // silently jumping to the first match, which would make selectNext skip one.
            currentIndex = min(currentIndex ?? 0, matches.count - 1)
        }
    }

    /// Forces a recount, e.g. after an edit.
    public func documentChanged() {
        let anchor = currentMatch?.region.start
        generation = .max
        refresh(near: anchor, force: true)
    }

    private func indexOfMatch(atOrAfter position: Position?) -> Int? {
        guard !matches.isEmpty else { return nil }
        guard let position else { return 0 }
        return matches.firstIndex { $0.region.start >= position } ?? (query.wrap ? 0 : nil)
    }

    // MARK: - Cycling

    /// Selects the next match after the current one (or after `from`), wrapping if the
    /// query allows it. Returns the newly selected match.
    @discardableResult
    public func selectNext(from position: Position? = nil) -> SearchMatch? {
        refresh(near: position)
        guard !matches.isEmpty else { return nil }

        if let position {
            // Inclusive: callers pass the end of the current match, and a back-to-back
            // match starts exactly there. A strict `>` skipped it, which made adjacent
            // matches permanently unreachable.
            if let index = matches.firstIndex(where: { $0.region.start >= position }) {
                currentIndex = index
            } else if query.wrap {
                currentIndex = 0
            } else {
                return nil
            }
        } else if let current = currentIndex {
            if current + 1 < matches.count {
                currentIndex = current + 1
            } else if query.wrap {
                currentIndex = 0
            } else {
                return nil
            }
        } else {
            currentIndex = 0
        }
        return currentMatch
    }

    @discardableResult
    public func selectPrevious(from position: Position? = nil) -> SearchMatch? {
        refresh(near: position)
        guard !matches.isEmpty else { return nil }

        if let position {
            if let index = matches.lastIndex(where: { $0.region.end <= position }) {
                currentIndex = index
            } else if query.wrap {
                currentIndex = matches.count - 1
            } else {
                return nil
            }
        } else if let current = currentIndex {
            if current > 0 {
                currentIndex = current - 1
            } else if query.wrap {
                currentIndex = matches.count - 1
            } else {
                return nil
            }
        } else {
            currentIndex = matches.count - 1
        }
        return currentMatch
    }

    public func clear() {
        query = SearchQuery()
        matches = []
        currentIndex = nil
        errorMessage = nil
        computedQuery = nil
        computedScope = nil
        generation = .max
        // Assigned last: its observer would otherwise re-run the search we just cleared.
        if scope != nil { scope = nil }
    }

    // MARK: - Replace

    /// Replaces the selected match and selects the next one. Returns the caret to place.
    @discardableResult
    public func replaceCurrent(with template: String) -> Position? {
        guard let match = currentMatch else { return nil }
        let replacement = ReplacementTemplate.expand(template, match: match,
                                                     preserveCase: query.preserveCase)

        let selection = Selection(match.region)
        let result = document.replace(selection, with: [replacement])
        let caret = result.primary.head

        // The document moved, so every offset must be recomputed.
        documentChanged()
        // Land on the first match at or after where the replacement ended.
        if matches.isEmpty {
            currentIndex = nil
        } else {
            currentIndex = matches.firstIndex { $0.region.start >= caret }
                ?? (query.wrap ? 0 : nil)
        }
        return caret
    }

    /// Replaces every match in one undo step. Returns how many were replaced.
    ///
    /// Runs back-to-front through `applyEdits`, so a replacement that changes length
    /// cannot shift the matches still to be processed.
    @discardableResult
    public func replaceAll(with template: String) -> Int {
        refresh(force: true)
        guard !matches.isEmpty, errorMessage == nil else { return 0 }

        let edits = matches.map { match in
            RegionEdit(range: match.region,
                       text: ReplacementTemplate.expand(template, match: match,
                                                        preserveCase: query.preserveCase))
        }
        let count = edits.count
        _ = document.applyEdits(edits)

        documentChanged()
        currentIndex = matches.isEmpty ? nil : 0
        return count
    }
}
