import Foundation

/// What to look for. One model for every search path — ⌘D, the find bar, and later
/// find-in-files — so options behave identically everywhere.
public struct SearchQuery: Equatable {
    public var pattern: String
    public var isRegex: Bool
    public var caseSensitive: Bool
    public var wholeWord: Bool
    public var wrap: Bool
    /// Replacements keep the case pattern of the text they overwrite (ALL CAPS,
    /// Capitalised, lowercase).
    public var preserveCase: Bool

    public init(pattern: String = "",
                isRegex: Bool = false,
                caseSensitive: Bool = true,
                wholeWord: Bool = false,
                wrap: Bool = true,
                preserveCase: Bool = false) {
        self.pattern = pattern
        self.isRegex = isRegex
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.wrap = wrap
        self.preserveCase = preserveCase
    }

    public static func literal(_ pattern: String, caseSensitive: Bool = true) -> SearchQuery {
        SearchQuery(pattern: pattern, caseSensitive: caseSensitive)
    }

    public var isEmpty: Bool { pattern.isEmpty }
}

/// A match, with its captures kept so a replacement template can reference them.
public struct SearchMatch {
    public let region: Region
    public let text: String
    /// Captured text by group number; group 0 is the whole match.
    public let groups: [Int: String]

    public init(region: Region, text: String, groups: [Int: String] = [:]) {
        self.region = region
        self.text = text
        self.groups = groups
    }
}

public struct SearchError: LocalizedError {
    public let reason: String
    public var errorDescription: String? { reason }
}

/// A compiled query, ready to run against lines.
///
/// Searching is line-oriented, like the highlighter: it keeps memory bounded on large
/// files and makes `^`/`$` mean what users expect. The cost is that a regex cannot span
/// a line break — a documented limitation, not an accident.
public struct SearchMatcher {

    public let query: SearchQuery
    private let regex: CompiledRegex?
    private let compareOptions: String.CompareOptions

    public init(_ query: SearchQuery) throws {
        self.query = query

        var options: String.CompareOptions = [.literal]
        if !query.caseSensitive { options.insert(.caseInsensitive) }
        self.compareOptions = options

        guard !query.pattern.isEmpty else {
            self.regex = nil
            return
        }
        if query.isRegex {
            // Whole-word is expressed as boundaries around the user's pattern, wrapped
            // in a group so alternations stay intact: \b(?:a|b)\b, not \ba|b\b.
            let source = query.wholeWord ? "\\b(?:" + query.pattern + ")\\b" : query.pattern
            do {
                self.regex = try RegexShim.compile(source, caseInsensitive: !query.caseSensitive)
            } catch {
                throw SearchError(reason: "Invalid pattern: \(error.localizedDescription)")
            }
        } else {
            self.regex = nil
        }
    }

    public var isEmpty: Bool { query.isEmpty }

    /// Whether the pattern compiles — used to grey out the find bar on a bad regex.
    public static func validate(_ query: SearchQuery) -> String? {
        do {
            _ = try SearchMatcher(query)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// All matches on one line, at or after `fromColumn`.
    public func matches(inLine lineIndex: Int, text: String, fromColumn: Int = 0) -> [SearchMatch] {
        // fromColumn is public API: a negative value would trap in String.index(_:offsetBy:).
        guard !query.isEmpty, fromColumn >= 0, fromColumn <= text.count else { return [] }
        return query.isRegex
            ? regexMatches(lineIndex: lineIndex, text: text, fromColumn: fromColumn)
            : literalMatches(lineIndex: lineIndex, text: text, fromColumn: fromColumn)
    }

    // MARK: - Literal

    private func literalMatches(lineIndex: Int, text: String, fromColumn: Int) -> [SearchMatch] {
        var results: [SearchMatch] = []
        guard !text.isEmpty else { return results }

        var searchStart = text.index(text.startIndex, offsetBy: fromColumn)
        while searchStart < text.endIndex,
              let found = text.range(of: query.pattern,
                                     options: compareOptions,
                                     range: searchStart ..< text.endIndex) {
            let startColumn = text.distance(from: text.startIndex, to: found.lowerBound)
            let endColumn = text.distance(from: text.startIndex, to: found.upperBound)

            if !query.wholeWord || SearchMatcher.isWholeWord(in: text, start: startColumn, end: endColumn) {
                let matched = String(text[found])
                results.append(SearchMatch(
                    region: Region(anchor: Position(line: lineIndex, column: startColumn),
                                   head: Position(line: lineIndex, column: endColumn)),
                    text: matched,
                    groups: [0: matched]
                ))
            }
            // Advance past the match, or by one for a zero-length one.
            searchStart = found.upperBound > found.lowerBound
                ? found.upperBound
                : text.index(after: found.lowerBound)
        }
        return results
    }

    static func isWholeWord(in text: String, start: Int, end: Int) -> Bool {
        let characters = Array(text)
        if start > 0, WordBoundary.classify(characters[start - 1]) == .word { return false }
        if end < characters.count, WordBoundary.classify(characters[end]) == .word { return false }
        return true
    }

    // MARK: - Regex

    private func regexMatches(lineIndex: Int, text: String, fromColumn: Int) -> [SearchMatch] {
        guard let regex else { return [] }
        var results: [SearchMatch] = []
        let utf16 = text.utf16

        // Convert the starting column (Characters) to a UTF-16 offset.
        let startIndex = text.index(text.startIndex, offsetBy: min(fromColumn, text.count))
        var position = utf16.distance(from: utf16.startIndex, to: startIndex)
        let length = utf16.count

        while position <= length, let match = regex.firstMatch(in: text, from: position) {
            let range = match.range
            guard let region = SearchMatcher.region(for: range, in: text, line: lineIndex) else { break }

            var groups: [Int: String] = [:]
            for (number, groupRange) in match.groups {
                groups[number] = SearchMatcher.substring(of: text, utf16Range: groupRange) ?? ""
            }
            results.append(SearchMatch(region: region,
                                       text: groups[0] ?? "",
                                       groups: groups))

            // A zero-width match must still make progress.
            position = range.length > 0 ? range.location + range.length : range.location + 1
        }
        return results
    }

    static func region(for utf16Range: NSRange, in text: String, line: Int) -> Region? {
        guard let start = column(of: utf16Range.location, in: text),
              let end = column(of: utf16Range.location + utf16Range.length, in: text)
        else { return nil }
        return Region(anchor: Position(line: line, column: start),
                      head: Position(line: line, column: end))
    }

    /// UTF-16 offset → Character column, snapping into the enclosing grapheme cluster.
    static func column(of utf16Offset: Int, in text: String) -> Int? {
        let utf16 = text.utf16
        let clamped = max(0, min(utf16Offset, utf16.count))
        guard let index = utf16.index(utf16.startIndex, offsetBy: clamped, limitedBy: utf16.endIndex)
        else { return nil }
        let position = index.samePosition(in: text)
            ?? text.rangeOfComposedCharacterSequence(at: index).lowerBound
        return text.distance(from: text.startIndex, to: position)
    }

    static func substring(of text: String, utf16Range: NSRange) -> String? {
        let utf16 = text.utf16
        guard utf16Range.location != NSNotFound,
              let start = utf16.index(utf16.startIndex, offsetBy: utf16Range.location,
                                      limitedBy: utf16.endIndex),
              let end = utf16.index(start, offsetBy: utf16Range.length, limitedBy: utf16.endIndex),
              let from = start.samePosition(in: text),
              let to = end.samePosition(in: text)
        else { return nil }
        return String(text[from ..< to])
    }
}

/// Expands a replacement template against a match.
public enum ReplacementTemplate {

    /// Supports `$0`–`$99`, `${n}`, `\1`–`\99`, `$$`/`\\` for literals, and the escapes
    /// `\n`, `\t`, `\r`. Unknown group references expand to nothing, matching Sublime.
    ///
    /// With `preserveCase`, the result adopts the case shape of the text it replaces:
    /// ALL CAPS stays all caps, Capitalised stays capitalised.
    public static func expand(_ template: String,
                              match: SearchMatch,
                              preserveCase: Bool = false) -> String {
        var result = ""
        result.reserveCapacity(template.count)

        var index = template.startIndex
        while index < template.endIndex {
            let character = template[index]

            if character == "\\" {
                let next = template.index(after: index)
                guard next < template.endIndex else {
                    result.append(character)
                    break
                }
                switch template[next] {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                case "\\": result.append("\\")
                case "0" ... "9":
                    let (number, after) = readNumber(template, from: next)
                    result += match.groups[number] ?? ""
                    index = after
                    continue
                default: result.append(template[next])
                }
                index = template.index(after: next)
                continue
            }

            if character == "$" {
                let next = template.index(after: index)
                guard next < template.endIndex else {
                    result.append(character)
                    break
                }
                if template[next] == "$" {
                    result.append("$")
                    index = template.index(after: next)
                    continue
                }
                if template[next] == "{" {
                    if let close = template[next...].firstIndex(of: "}") {
                        let name = String(template[template.index(after: next) ..< close])
                        result += match.groups[Int(name) ?? -1] ?? ""
                        index = template.index(after: close)
                        continue
                    }
                }
                if template[next].isNumber {
                    let (number, after) = readNumber(template, from: next)
                    result += match.groups[number] ?? ""
                    index = after
                    continue
                }
                result.append(character)
                index = next
                continue
            }

            result.append(character)
            index = template.index(after: index)
        }

        return preserveCase ? applyCaseShape(of: match.text, to: result) : result
    }

    /// Reads up to two digits starting at `index`, returning the value and the index
    /// just past them.
    private static func readNumber(_ template: String, from index: String.Index) -> (Int, String.Index) {
        var digits = ""
        var cursor = index
        while cursor < template.endIndex, template[cursor].isNumber, digits.count < 2 {
            digits.append(template[cursor])
            cursor = template.index(after: cursor)
        }
        return (Int(digits) ?? 0, cursor)
    }

    /// Mirrors the case shape of `source` onto `replacement`.
    static func applyCaseShape(of source: String, to replacement: String) -> String {
        let letters = source.filter { $0.isLetter }
        guard !letters.isEmpty else { return replacement }

        if letters.allSatisfy({ $0.isUppercase }), letters.count > 1 {
            return replacement.uppercased()
        }
        if letters.allSatisfy({ $0.isLowercase }) {
            return replacement.lowercased()
        }
        if let first = letters.first, first.isUppercase,
           letters.dropFirst().allSatisfy({ $0.isLowercase }) {
            guard let firstCharacter = replacement.first else { return replacement }
            return firstCharacter.uppercased() + replacement.dropFirst().lowercased()
        }
        return replacement
    }
}
