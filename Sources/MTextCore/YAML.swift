import Foundation

/// A minimal YAML value tree.
public enum YAMLValue {
    case string(String)
    case list([YAMLValue])
    case map([String: YAMLValue])

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var listValue: [YAMLValue]? {
        switch self {
        case .list(let items): return items
        // A lone scalar where a list is expected is treated as a one-element list,
        // which is how sublime-syntax writes single-item `push` and `include` values.
        case .string, .map: return [self]
        }
    }

    public var mapValue: [String: YAMLValue]? {
        if case .map(let map) = self { return map }
        return nil
    }

    public subscript(key: String) -> YAMLValue? {
        mapValue?[key]
    }
}

public struct YAMLError: LocalizedError {
    public let line: Int
    public let message: String
    public var errorDescription: String? { "YAML line \(line): \(message)" }
}

/// Indentation-based YAML parser covering the subset `.sublime-syntax` uses:
/// block mappings, block sequences, plain and quoted scalars, block scalars
/// (`|`, `>`), comments, and inline flow sequences (`[a, b]`).
///
/// Deliberately not a general YAML implementation — no anchors, aliases, tags,
/// multi-document streams or complex keys. Sublime's own syntax files use none of them.
public enum YAML {

    public static func parse(_ text: String) throws -> YAMLValue {
        var lines: [Line] = []
        // Normalise CRLF first, or a trailing \r breaks `splitKey` on every valueless
        // key (`contexts:`) and gets baked into scope names.
        //
        // The check is on UTF-8 bytes, not `contains("\r")`: "\r\n" is a *single*
        // Character in Swift, so a substring search for "\r" never matches inside it.
        let normalised = text.utf8.contains(0x0D)
            ? text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            : text
        for (number, raw) in normalised.components(separatedBy: "\n").enumerated() {
            guard let line = Line(raw: raw, number: number + 1) else { continue }
            lines.append(line)
        }
        var index = 0
        guard !lines.isEmpty else { return .map([:]) }
        let value = try parseBlock(lines, &index, indent: lines[0].indent)
        return value
    }

    // MARK: - Lines

    private struct Line {
        let number: Int
        let indent: Int
        let content: String

        /// Returns nil for blank lines, comments and document markers.
        init?(raw: String, number: Int) {
            var indent = 0
            var index = raw.startIndex
            while index < raw.endIndex, raw[index] == " " || raw[index] == "\t" {
                indent += raw[index] == "\t" ? 2 : 1
                index = raw.index(after: index)
            }
            // Trailing whitespace and stray carriage returns are never significant
            // here, and leaving them on would break `splitKey`'s "colon followed by
            // space or end of line" rule.
            let body = String(raw[index...]).replacingOccurrences(
                of: "[ \\t\\r\\n]+$", with: "", options: .regularExpression)
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip blanks, comments, document markers, and directives — every
            // .sublime-syntax file opens with `%YAML 1.2`.
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("%")
                || trimmed == "---" || trimmed == "..." {
                return nil
            }
            self.number = number
            self.indent = indent
            self.content = body
        }

        var isSequenceEntry: Bool {
            content == "-" || content.hasPrefix("- ")
        }
    }

    // MARK: - Block parsing

    private static func parseBlock(_ lines: [Line], _ index: inout Int, indent: Int) throws -> YAMLValue {
        guard index < lines.count else { return .map([:]) }
        return lines[index].isSequenceEntry
            ? .list(try parseSequence(lines, &index, indent: indent))
            : .map(try parseMapping(lines, &index, indent: indent))
    }

    private static func parseSequence(_ lines: [Line], _ index: inout Int, indent: Int) throws -> [YAMLValue] {
        var items: [YAMLValue] = []
        while index < lines.count, lines[index].indent == indent, lines[index].isSequenceEntry {
            let line = lines[index]
            let inline = line.content == "-" ? "" : String(line.content.dropFirst(2))
            index += 1

            if inline.isEmpty {
                // Value lives on the following, more-indented lines.
                if index < lines.count, lines[index].indent > indent {
                    items.append(try parseBlock(lines, &index, indent: lines[index].indent))
                } else {
                    items.append(.string(""))
                }
                continue
            }

            // `- key: value` starts a mapping whose subsequent keys align with `key`.
            if let colon = splitKey(inline) {
                let childIndent = indent + 2
                var entries: [String: YAMLValue] = [:]
                try assign(&entries, key: colon.key, rest: colon.rest,
                           lines: lines, index: &index, indent: childIndent, line: line)
                while index < lines.count, lines[index].indent >= childIndent,
                      !lines[index].isSequenceEntry || lines[index].indent > childIndent {
                    let next = lines[index]
                    guard let pair = splitKey(next.content) else { break }
                    index += 1
                    try assign(&entries, key: pair.key, rest: pair.rest,
                               lines: lines, index: &index, indent: next.indent, line: next)
                }
                items.append(.map(entries))
            } else {
                items.append(.string(try scalar(inline, lines: lines, index: &index, indent: indent)))
            }
        }
        return items
    }

    private static func parseMapping(_ lines: [Line], _ index: inout Int, indent: Int) throws -> [String: YAMLValue] {
        var entries: [String: YAMLValue] = [:]
        while index < lines.count, lines[index].indent == indent, !lines[index].isSequenceEntry {
            let line = lines[index]
            guard let pair = splitKey(line.content) else {
                throw YAMLError(line: line.number, message: "expected 'key: value'")
            }
            index += 1
            try assign(&entries, key: pair.key, rest: pair.rest,
                       lines: lines, index: &index, indent: indent, line: line)
        }
        return entries
    }

    /// Stores one `key: value` pair, descending into a nested block when the value
    /// is empty and the following lines are more indented.
    private static func assign(_ entries: inout [String: YAMLValue],
                               key: String,
                               rest: String,
                               lines: [Line],
                               index: inout Int,
                               indent: Int,
                               line: Line) throws {
        if rest.isEmpty {
            if index < lines.count, lines[index].indent > indent {
                entries[key] = try parseBlock(lines, &index, indent: lines[index].indent)
            } else if index < lines.count, lines[index].indent == indent, lines[index].isSequenceEntry {
                // A sequence may sit at the same indentation as its key.
                entries[key] = .list(try parseSequence(lines, &index, indent: indent))
            } else {
                entries[key] = .string("")
            }
            return
        }
        if rest.hasPrefix("[") {
            entries[key] = .list(parseFlowSequence(rest))
            return
        }
        if rest == "|" || rest == ">" || rest.hasPrefix("|") || rest.hasPrefix(">") {
            entries[key] = .string(parseBlockScalar(rest, lines: lines, index: &index, indent: indent))
            return
        }
        entries[key] = .string(try scalar(rest, lines: lines, index: &index, indent: indent))
    }

    // MARK: - Scalars

    private static func scalar(_ text: String, lines: [Line], index: inout Int, indent: Int) throws -> String {
        let trimmed = stripComment(text).trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("'") || trimmed.hasPrefix("\"") {
            return unquote(trimmed)
        }
        return trimmed
    }

    /// Splits `key: value`, ignoring colons inside quotes and regex character classes.
    private static func splitKey(_ content: String) -> (key: String, rest: String)? {
        var quote: Character?
        var depth = 0
        var index = content.startIndex

        while index < content.endIndex {
            let character = content[index]
            if let active = quote {
                if character == active { quote = nil }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == "[" || character == "{" {
                depth += 1
            } else if character == "]" || character == "}" {
                depth = max(0, depth - 1)
            } else if character == ":" && depth == 0 {
                let next = content.index(after: index)
                // A key's colon must be followed by a space or end of line.
                if next == content.endIndex || content[next] == " " || content[next] == "\t" {
                    let key = unquote(String(content[..<index]).trimmingCharacters(in: .whitespacesAndNewlines))
                    let rest = String(content[next...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    return key.isEmpty ? nil : (key, rest)
                }
            }
            index = content.index(after: index)
        }
        return nil
    }

    private static func parseFlowSequence(_ text: String) -> [YAMLValue] {
        let body = stripComment(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.hasPrefix("[") else { return [] }
        let inner = body.dropFirst().prefix { $0 != "]" }
        var items: [YAMLValue] = []
        var current = ""
        var quote: Character?
        for character in inner {
            if let active = quote {
                if character == active { quote = nil } else { current.append(character) }
                if quote == nil { continue }
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                continue
            }
            if character == "," {
                items.append(.string(current.trimmingCharacters(in: .whitespacesAndNewlines)))
                current = ""
                continue
            }
            current.append(character)
        }
        let last = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty { items.append(.string(last)) }
        return items
    }

    private static func parseBlockScalar(_ header: String, lines: [Line],
                                        index: inout Int, indent: Int) -> String {
        let folded = header.hasPrefix(">")
        var collected: [String] = []
        while index < lines.count, lines[index].indent > indent {
            collected.append(lines[index].content)
            index += 1
        }
        return collected.joined(separator: folded ? " " : "\n")
    }

    /// Drops a trailing `# comment`, respecting quotes.
    private static func stripComment(_ text: String) -> String {
        var quote: Character?
        var previous: Character?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if let active = quote {
                if character == active { quote = nil }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == "#", previous == nil || previous == " " || previous == "\t" {
                return String(text[..<index])
            }
            previous = character
            index = text.index(after: index)
        }
        return text
    }

    private static func unquote(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, let last = text.last, first == last else {
            return text
        }
        if first == "'" {
            // In single quotes only '' is an escape.
            return String(text.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if first == "\"" {
            var result = ""
            var escaped = false
            for character in text.dropFirst().dropLast() {
                if escaped {
                    switch character {
                    case "n": result.append("\n")
                    case "t": result.append("\t")
                    case "r": result.append("\r")
                    case "0": result.append("\0")
                    default: result.append(character)
                    }
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else {
                    result.append(character)
                }
            }
            return result
        }
        return text
    }
}
