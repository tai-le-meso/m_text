import Foundation

/// Decides *which parts of a line* are worth spell-checking (T101).
///
/// Spell-checking a source file wholesale is useless — every identifier, keyword and symbol
/// is a "misspelling", and the squiggles become noise you learn to ignore. Restricting to
/// comments, strings and prose is what makes the feature usable, and the scope information
/// needed to do it is already computed by the highlighter.
///
/// Pure and separate from `NSSpellChecker` so the filtering rules are testable without a
/// spell checker, a view, or a language dictionary.
public enum SpellCheckScopes {

    /// Scope selectors whose text gets checked. Deliberately broad prefixes: every grammar
    /// names comments `comment.*` and strings `string.*`, and prose files are `text.*`.
    public static let defaultSelectors = ["comment", "string", "text"]

    /// UTF-16 ranges of a line to check.
    ///
    /// `spans` nil and empty mean different things, matching the convention
    /// `EditorView.attributedLine` already relies on:
    ///
    /// - **empty** — highlighted, but nothing to style. The whole line is checked.
    /// - **nil** — the highlighter hasn't reached this line, so `baseScope` decides. A prose
    ///   document (`text.*`) is checked immediately; a code file is not, so it isn't briefly
    ///   squiggled all over while the background sweep catches up.
    ///
    /// That `baseScope` fallback is not a nicety: without it, spell check does nothing at all
    /// on a plain-text file that never produces spans — which is the main thing anyone turns
    /// it on for.
    public static func checkableRanges(spans: [ScopeSpan]?,
                                       lineLength: Int,
                                       baseScope: String? = nil,
                                       selectors: [String] = defaultSelectors) -> [Range<Int>] {
        guard lineLength > 0 else { return [] }
        guard let spans else {
            guard let baseScope,
                  selectors.contains(where: { ScopeSelector($0).matches(ScopeStack([baseScope])) })
            else { return [] }
            return [0 ..< lineLength]
        }
        guard !spans.isEmpty else { return [0 ..< lineLength] }

        let compiled = selectors.map { ScopeSelector($0) }
        var ranges: [Range<Int>] = []
        for span in spans {
            let start = max(0, min(span.start, lineLength))
            let end = max(start, min(span.end, lineLength))
            guard end > start else { continue }
            guard compiled.contains(where: { $0.matches(span.scopes) }) else { continue }
            // Adjacent runs merge, so a comment split across several spans (punctuation,
            // content) is checked as one piece of text rather than word-by-fragment — a
            // word straddling a span boundary would otherwise be reported misspelled.
            if let last = ranges.last, last.upperBound >= start {
                ranges[ranges.count - 1] = last.lowerBound ..< max(last.upperBound, end)
            } else {
                ranges.append(start ..< end)
            }
        }
        return ranges
    }
}
