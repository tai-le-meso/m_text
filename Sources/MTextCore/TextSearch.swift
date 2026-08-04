import Foundation

/// Document search, line-oriented so cost is proportional to what it walks rather than
/// to the file size.
///
/// Regex support lives in `SearchMatcher`; a regex cannot span a line break, which is a
/// documented limitation of the line-at-a-time design.
public extension TextDocument {

    // MARK: - Query-based API

    /// First match starting at or after `position`, optionally wrapping to the top.
    ///
    /// Inclusive at the boundary on purpose: callers pass the end of the current match,
    /// and a back-to-back match starts exactly there.
    func findNext(_ query: SearchQuery, after position: Position) -> SearchMatch? {
        guard let matcher = try? SearchMatcher(query), !matcher.isEmpty else { return nil }
        let from = clamp(position)

        if let match = firstMatch(matcher, fromLine: from.line, fromColumn: from.column,
                                 throughLine: lineCount - 1, after: from) {
            return match
        }
        guard query.wrap else { return nil }
        return firstMatch(matcher, fromLine: 0, fromColumn: 0, throughLine: from.line, after: nil)
    }

    /// Last match strictly before `position`, optionally wrapping to the bottom.
    func findPrevious(_ query: SearchQuery, before position: Position) -> SearchMatch? {
        guard let matcher = try? SearchMatcher(query), !matcher.isEmpty else { return nil }
        let to = clamp(position)

        // Walk backwards a line at a time and take the last match that starts earlier.
        for line in stride(from: to.line, through: 0, by: -1) {
            let candidates = matcher.matches(inLine: line, text: self.line(line))
            if let match = candidates.last(where: { $0.region.start < to }) { return match }
        }
        guard query.wrap else { return nil }
        for line in stride(from: lineCount - 1, through: to.line, by: -1) {
            if let match = matcher.matches(inLine: line, text: self.line(line)).last { return match }
        }
        return nil
    }

    /// Every match in the document, in order.
    func findAll(_ query: SearchQuery) -> [SearchMatch] {
        guard let matcher = try? SearchMatcher(query), !matcher.isEmpty else { return [] }
        var results: [SearchMatch] = []
        for line in 0 ..< lineCount {
            results.append(contentsOf: matcher.matches(inLine: line, text: self.line(line)))
        }
        return results
    }

    /// Matches inside a region — "find in selection".
    func findAll(_ query: SearchQuery, in region: Region) -> [SearchMatch] {
        guard let matcher = try? SearchMatcher(query), !matcher.isEmpty else { return [] }
        let bounds = Region(anchor: clamp(region.start), head: clamp(region.end))
        guard bounds.start < bounds.end else { return [] }

        var results: [SearchMatch] = []
        for line in bounds.start.line ... bounds.end.line {
            for match in matcher.matches(inLine: line, text: self.line(line))
            where match.region.start >= bounds.start && match.region.end <= bounds.end {
                results.append(match)
            }
        }
        return results
    }

    /// Matches anywhere in any region of a selection.
    func findAll(_ query: SearchQuery, in selection: Selection) -> [SearchMatch] {
        selection.regions.filter { !$0.isEmpty }.flatMap { findAll(query, in: $0) }
    }

    func matchCount(_ query: SearchQuery) -> Int {
        findAll(query).count
    }

    // MARK: - Convenience for ⌘D

    func findNext(_ needle: String, after position: Position,
                  caseSensitive: Bool = true, wrap: Bool = true) -> Region? {
        var query = SearchQuery.literal(needle, caseSensitive: caseSensitive)
        query.wrap = wrap
        return findNext(query, after: position)?.region
    }

    func findPrevious(_ needle: String, before position: Position,
                      caseSensitive: Bool = true) -> Region? {
        findPrevious(SearchQuery.literal(needle, caseSensitive: caseSensitive),
                     before: position)?.region
    }

    func findAll(_ needle: String, caseSensitive: Bool = true) -> [Region] {
        findAll(SearchQuery.literal(needle, caseSensitive: caseSensitive)).map(\.region)
    }

    // MARK: - Internals

    private func firstMatch(_ matcher: SearchMatcher,
                            fromLine: Int,
                            fromColumn: Int,
                            throughLine: Int,
                            after: Position?) -> SearchMatch? {
        guard fromLine <= throughLine, fromLine < lineCount else { return nil }
        for line in fromLine ... min(throughLine, lineCount - 1) {
            let startColumn = line == fromLine ? fromColumn : 0
            let candidates = matcher.matches(inLine: line, text: self.line(line),
                                             fromColumn: startColumn)
            if let after {
                if let match = candidates.first(where: { $0.region.start >= after }) { return match }
            } else if let match = candidates.first {
                return match
            }
        }
        return nil
    }
}
