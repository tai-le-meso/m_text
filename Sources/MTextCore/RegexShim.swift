import Foundation

/// A compiled pattern plus the source it came from, matched against one line at a time.
public final class CompiledRegex {
    public let source: String
    public let translated: String
    private let regex: NSRegularExpression

    init(source: String, translated: String, regex: NSRegularExpression) {
        self.source = source
        self.translated = translated
        self.regex = regex
    }

    /// Match result in UTF-16 offsets within the line.
    public struct Match {
        public let range: NSRange
        /// Capture group ranges by group number; group 0 is the whole match.
        public let groups: [Int: NSRange]
    }

    /// First match at or after `start` (UTF-16 offset) in `line`.
    public func firstMatch(in line: String, from start: Int) -> Match? {
        let utf16Count = line.utf16.count
        guard start <= utf16Count else { return nil }
        let searchRange = NSRange(location: start, length: utf16Count - start)
        // withoutAnchoringBounds keeps ^ and $ tied to the real line edges rather than
        // to the sub-range we scan from; withTransparentBounds lets \b and lookbehind
        // see the text before `start`. Without the latter, `\bif\b` would match the
        // "if" in "abcif" as soon as the tokenizer had consumed "abc".
        guard let result = regex.firstMatch(in: line,
                                            options: [.withoutAnchoringBounds, .withTransparentBounds],
                                            range: searchRange)
        else { return nil }

        var groups: [Int: NSRange] = [:]
        for index in 0 ..< result.numberOfRanges {
            let range = result.range(at: index)
            if range.location != NSNotFound { groups[index] = range }
        }
        return Match(range: result.range, groups: groups)
    }

    public var numberOfCaptureGroups: Int { regex.numberOfCaptureGroups }
}

/// Translates Oniguruma patterns (what `.sublime-syntax` and `.tmLanguage` use) into
/// the ICU dialect `NSRegularExpression` accepts, and caches the compiled results.
///
/// Most constructs are shared. The ones that differ, and what we do about them, are
/// listed in `translate`. Patterns that still fail to compile are reported rather than
/// silently dropped, so a bad grammar is visible instead of mysteriously uncoloured.
public enum RegexShim {

    private static var cache: [String: CompiledRegex] = [:]
    private static let cacheLimit = 4_000
    /// Grammars are compiled on whichever thread loads them, and the highlighter runs
    /// off-main, so the shared cache needs a lock.
    private static let cacheLock = NSLock()

    public static func compile(_ pattern: String, caseInsensitive: Bool = false) throws -> CompiledRegex {
        let key = caseInsensitive ? "i\u{0}" + pattern : pattern

        cacheLock.lock()
        let cached = cache[key]
        cacheLock.unlock()
        if let cached { return cached }

        let translated = translate(pattern)
        var options: NSRegularExpression.Options = []
        if caseInsensitive { options.insert(.caseInsensitive) }

        let regex = try NSRegularExpression(pattern: translated, options: options)
        let compiled = CompiledRegex(source: pattern, translated: translated, regex: regex)
        cacheLock.lock()
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[key] = compiled
        cacheLock.unlock()
        return compiled
    }

    public static func clearCache() {
        cacheLock.lock()
        cache.removeAll(keepingCapacity: true)
        cacheLock.unlock()
    }

    /// Oniguruma → ICU. Handled here:
    ///
    /// - `\h` / `\H` — hex digit in Oniguruma, horizontal space in ICU. Rewritten
    ///   to an explicit class, which is the single most common incompatibility.
    /// - POSIX brackets (`[[:alpha:]]`) — mapped to ICU property classes.
    /// - `\Z` — end-of-input-before-final-newline in Oniguruma; ICU treats it the
    ///   same, so it is left alone. `\A` and `\z` are identical in both.
    /// - Possessive quantifiers and atomic groups — ICU supports both natively.
    /// - `(?<name>…)`, lookaround, `\p{…}`, `\Q…\E` — identical in both.
    /// - `\G` — no ICU equivalent; dropped, since we already anchor the search
    ///   position ourselves.
    public static func translate(_ pattern: String) -> String {
        var result = ""
        result.reserveCapacity(pattern.count + 16)

        var index = pattern.startIndex
        var insideClass = false

        while index < pattern.endIndex {
            let character = pattern[index]

            if character == "\\" {
                let next = pattern.index(after: index)
                guard next < pattern.endIndex else {
                    result.append(character)
                    break
                }
                let escaped = pattern[next]
                switch escaped {
                case "h":
                    // \p{AHex} works both inside and outside a class; a bare
                    // "^0-9a-fA-F" inside one would be read as a literal caret.
                    result += insideClass ? "\\p{AHex}" : "[0-9a-fA-F]"
                case "H":
                    result += insideClass ? "\\P{AHex}" : "[^0-9a-fA-F]"
                case "G":
                    break // no ICU equivalent; the search position is already anchored
                default:
                    result.append(character)
                    result.append(escaped)
                }
                index = pattern.index(after: next)
                continue
            }

            if character == "[" && !insideClass {
                // POSIX bracket expressions appear as [[:alpha:]] — detect the inner form.
                if let replacement = posixClass(in: pattern, at: index) {
                    result += replacement.text
                    index = replacement.end
                    continue
                }
                insideClass = true
                result.append(character)
                index = pattern.index(after: index)
                continue
            }

            if character == "[" && insideClass {
                if let replacement = posixClass(in: pattern, at: index) {
                    result += replacement.text
                    index = replacement.end
                    continue
                }
                // ICU treats a nested [ inside a class as set intersection syntax;
                // escape it to keep the literal meaning Oniguruma gives it.
                result += "\\["
                index = pattern.index(after: index)
                continue
            }

            if character == "]" && insideClass {
                insideClass = false
            }

            result.append(character)
            index = pattern.index(after: index)
        }
        return result
    }

    /// ICU's POSIX compatibility properties, which behave correctly both inside and
    /// outside a character class — unlike hand-rolled unions such as `\P{Z}\P{C}`,
    /// which ICU reads as a union and so matches almost everything.
    private static let posixClasses: [String: String] = [
        "alpha": "\\p{Alpha}",
        "digit": "\\p{Digit}",
        "alnum": "\\p{Alnum}",
        "space": "\\p{Space}",
        "upper": "\\p{Upper}",
        "lower": "\\p{Lower}",
        "punct": "\\p{Punct}",
        "word": "\\p{Word}",
        "xdigit": "\\p{XDigit}",
        "cntrl": "\\p{Cntrl}",
        "graph": "\\p{Graph}",
        "print": "\\p{Print}",
        "blank": "\\p{Blank}",
    ]

    /// Recognises `[:name:]` at `index` (with or without the outer bracket) and
    /// returns its ICU replacement plus the index just past it.
    private static func posixClass(in pattern: String, at index: String.Index) -> (text: String, end: String.Index)? {
        // Forms: "[[:alpha:]]" starting at the outer '[', or "[:alpha:]" inside a class.
        var cursor = index
        var wrapped = false
        guard pattern[cursor] == "[" else { return nil }
        cursor = pattern.index(after: cursor)
        guard cursor < pattern.endIndex else { return nil }

        if pattern[cursor] == "[" {
            wrapped = true
            cursor = pattern.index(after: cursor)
            guard cursor < pattern.endIndex else { return nil }
        }
        guard pattern[cursor] == ":" else { return nil }
        cursor = pattern.index(after: cursor)

        var negated = false
        if cursor < pattern.endIndex, pattern[cursor] == "^" {
            negated = true
            cursor = pattern.index(after: cursor)
        }

        var name = ""
        while cursor < pattern.endIndex, pattern[cursor].isLetter {
            name.append(pattern[cursor])
            cursor = pattern.index(after: cursor)
        }
        guard let replacement = posixClasses[name.lowercased()],
              cursor < pattern.endIndex, pattern[cursor] == ":"
        else { return nil }
        cursor = pattern.index(after: cursor)
        guard cursor < pattern.endIndex, pattern[cursor] == "]" else { return nil }
        cursor = pattern.index(after: cursor)

        if wrapped {
            guard cursor < pattern.endIndex, pattern[cursor] == "]" else { return nil }
            cursor = pattern.index(after: cursor)
            return ("[" + (negated ? "^" : "") + replacement + "]", cursor)
        }
        // Inside an existing class: contribute the bare set contents.
        return (negated ? "^" + replacement : replacement, cursor)
    }

}
