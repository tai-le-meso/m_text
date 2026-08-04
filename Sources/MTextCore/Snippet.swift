import Foundation

/// One `.sublime-snippet`: the body plus the metadata that decides when it's offered.
public struct Snippet: Equatable {
    /// Raw body, still containing `$1` / `${1:placeholder}` / `$SELECTION` markers.
    public let content: String
    /// Word that expands this snippet when Tab is pressed after it. nil = insertable by
    /// name only.
    public let tabTrigger: String?
    /// Scope selector limiting where the trigger fires, e.g. `source.python`. nil = any.
    public let scope: String?
    public let description: String?
    /// Display name — the file's own name, since `.sublime-snippet` has no name field.
    public let name: String

    public init(content: String, tabTrigger: String? = nil, scope: String? = nil,
                description: String? = nil, name: String = "") {
        self.content = content
        self.tabTrigger = tabTrigger
        self.scope = scope
        self.description = description
        self.name = name
    }
}

/// Parsed snippet body. Rendering is separate from parsing so one parse can be expanded
/// repeatedly with different variables (different file, different selection).
public indirect enum SnippetNode: Equatable {
    case literal(String)
    /// `$1` (empty children) or `${1:placeholder}`. `index` 0 is the final caret position.
    case stop(index: Int, children: [SnippetNode])
    /// `$NAME` or `${NAME:default}`, where the default renders only if the variable is empty.
    case variable(name: String, defaultValue: [SnippetNode])
}

/// Values substituted for `$VARIABLE` markers at expansion time.
public struct SnippetContext {
    public var selection: String
    public var fileName: String
    public var filePath: String
    public var directory: String
    public var currentLine: String
    public var lineNumber: Int
    public var currentWord: String
    public var tabSize: Int

    public init(selection: String = "", fileName: String = "", filePath: String = "",
                directory: String = "", currentLine: String = "", lineNumber: Int = 1,
                currentWord: String = "", tabSize: Int = 4) {
        self.selection = selection
        self.fileName = fileName
        self.filePath = filePath
        self.directory = directory
        self.currentLine = currentLine
        self.lineNumber = lineNumber
        self.currentWord = currentWord
        self.tabSize = tabSize
    }

    /// TextMate-compatible names, which is what real `.sublime-snippet` files use.
    /// `SELECTION` is Sublime's own spelling of `TM_SELECTED_TEXT`; both are accepted.
    /// Unknown names resolve to nil so the caller can fall back to the `${VAR:default}`
    /// text rather than silently emitting an empty string.
    public func value(for name: String) -> String? {
        switch name {
        case "SELECTION", "TM_SELECTED_TEXT": return selection
        case "TM_FILENAME": return fileName
        case "TM_FILEPATH": return filePath
        case "TM_DIRECTORY": return directory
        case "TM_CURRENT_LINE": return currentLine
        case "TM_LINE_NUMBER": return String(lineNumber)
        case "TM_CURRENT_WORD": return currentWord
        case "TM_TAB_SIZE": return String(tabSize)
        default: return nil
        }
    }
}

/// One tab stop in an expanded snippet, with every place it appears.
///
/// `ranges` holds character offsets into the expanded text. More than one range means the
/// stop is **mirrored** — `$1` written twice — and the first is the one the caret lands on;
/// the rest track whatever is typed there.
public struct SnippetTabStop: Equatable {
    public let index: Int
    public let ranges: [Range<Int>]
    /// Default text, i.e. what `${1:this}` rendered to. Empty for a bare `$1`.
    public let placeholder: String

    public init(index: Int, ranges: [Range<Int>], placeholder: String) {
        self.index = index
        self.ranges = ranges
        self.placeholder = placeholder
    }

    public var primaryRange: Range<Int> { ranges[0] }
}

/// A snippet body rendered to real text, with the stops located within it.
public struct SnippetExpansion: Equatable {
    public let text: String
    /// Ordered for Tab navigation: 1, 2, 3 … then `$0` last. A snippet with no explicit
    /// `$0` gets one synthesized at the end, so Tab always has somewhere final to land.
    public let stops: [SnippetTabStop]

    public init(text: String, stops: [SnippetTabStop]) {
        self.text = text
        self.stops = stops
    }
}

/// Parses snippet *body* syntax — `$1`, `${1:placeholder}`, `$VAR`, `${VAR:default}`,
/// with `\$` and `\\` escapes.
public enum SnippetBodyParser {

    public static func parse(_ body: String) -> [SnippetNode] {
        var characters = Array(body)
        var index = 0
        return parseNodes(&characters, &index, stopAtBrace: false)
    }

    /// `stopAtBrace` is how nested `${1:${2:inner}}` terminates: the recursive call for the
    /// placeholder returns at the matching `}` instead of consuming it as a literal.
    private static func parseNodes(_ characters: inout [Character], _ index: inout Int,
                                   stopAtBrace: Bool) -> [SnippetNode] {
        var nodes: [SnippetNode] = []
        var literal = ""

        func flush() {
            if !literal.isEmpty {
                nodes.append(.literal(literal))
                literal = ""
            }
        }

        while index < characters.count {
            let character = characters[index]

            if character == "\\", index + 1 < characters.count {
                // Only `$`, `}` and `\` are meaningful to escape; anything else keeps the
                // backslash, so a snippet containing `\n` in code stays `\n`.
                let next = characters[index + 1]
                if next == "$" || next == "\\" || next == "}" {
                    literal.append(next)
                    index += 2
                    continue
                }
                literal.append(character)
                index += 1
                continue
            }

            if stopAtBrace, character == "}" {
                flush()
                return nodes
            }

            guard character == "$", index + 1 < characters.count else {
                literal.append(character)
                index += 1
                continue
            }

            // `$` followed by something that isn't a marker (e.g. a bare `$` in shell code)
            // is just text.
            guard let node = parseMarker(&characters, &index) else {
                literal.append(character)
                index += 1
                continue
            }
            flush()
            nodes.append(node)
        }

        flush()
        return nodes
    }

    /// Consumes one `$…` marker, or returns nil (leaving `index` untouched) when what
    /// follows isn't one.
    private static func parseMarker(_ characters: inout [Character], _ index: inout Int) -> SnippetNode? {
        let start = index
        index += 1 // past `$`

        if index < characters.count, characters[index] == "{" {
            index += 1
            // ${1:...} or ${NAME:...}
            if let number = readInt(&characters, &index) {
                if index < characters.count, characters[index] == ":" {
                    index += 1
                    let children = parseNodes(&characters, &index, stopAtBrace: true)
                    guard index < characters.count, characters[index] == "}" else {
                        index = start; return nil // unbalanced — treat as literal text
                    }
                    index += 1
                    return .stop(index: number, children: children)
                }
                guard index < characters.count, characters[index] == "}" else {
                    index = start; return nil
                }
                index += 1
                return .stop(index: number, children: [])
            }
            let name = readIdentifier(&characters, &index)
            guard !name.isEmpty else { index = start; return nil }
            if index < characters.count, characters[index] == ":" {
                index += 1
                let fallback = parseNodes(&characters, &index, stopAtBrace: true)
                guard index < characters.count, characters[index] == "}" else {
                    index = start; return nil
                }
                index += 1
                return .variable(name: name, defaultValue: fallback)
            }
            guard index < characters.count, characters[index] == "}" else {
                index = start; return nil
            }
            index += 1
            return .variable(name: name, defaultValue: [])
        }

        if let number = readInt(&characters, &index) {
            return .stop(index: number, children: [])
        }
        let name = readIdentifier(&characters, &index)
        if !name.isEmpty { return .variable(name: name, defaultValue: []) }

        index = start
        return nil
    }

    private static func readInt(_ characters: inout [Character], _ index: inout Int) -> Int? {
        var digits = ""
        while index < characters.count, characters[index].isNumber {
            digits.append(characters[index])
            index += 1
        }
        return digits.isEmpty ? nil : Int(digits)
    }

    private static func readIdentifier(_ characters: inout [Character], _ index: inout Int) -> String {
        var name = ""
        while index < characters.count,
              characters[index].isLetter || characters[index].isNumber || characters[index] == "_" {
            name.append(characters[index])
            index += 1
        }
        return name
    }
}

/// Renders parsed nodes to text, recording where every tab stop landed.
public enum SnippetRenderer {

    public static func expand(_ body: String, context: SnippetContext = SnippetContext()) -> SnippetExpansion {
        expand(nodes: SnippetBodyParser.parse(body), context: context)
    }

    public static func expand(nodes: [SnippetNode], context: SnippetContext) -> SnippetExpansion {
        // A mirrored stop is usually written `${1:name}` once and `$1` after, so the text
        // for the bare occurrences has to be known before rendering reaches them. One
        // pre-pass resolves each index's default; rendering then just reuses it.
        var defaults: [Int: String] = [:]
        collectDefaults(nodes, context: context, into: &defaults)

        var text = ""
        var ranges: [Int: [Range<Int>]] = [:]
        render(nodes, context: context, defaults: defaults, text: &text, ranges: &ranges)

        var stops: [SnippetTabStop] = ranges
            .map { SnippetTabStop(index: $0.key, ranges: $0.value.sorted { $0.lowerBound < $1.lowerBound },
                                  placeholder: defaults[$0.key] ?? "") }
            // `$0` is the exit stop, so it sorts *after* every numbered stop rather than
            // first, which a plain numeric sort would do.
            .sorted { ($0.index == 0 ? Int.max : $0.index) < ($1.index == 0 ? Int.max : $1.index) }

        if !stops.contains(where: { $0.index == 0 }) {
            // Without a final stop, Tab out of the last placeholder would have nowhere to
            // go and the caret would be left mid-snippet.
            let end = text.count
            stops.append(SnippetTabStop(index: 0, ranges: [end ..< end], placeholder: ""))
        }
        return SnippetExpansion(text: text, stops: stops)
    }

    private static func collectDefaults(_ nodes: [SnippetNode], context: SnippetContext,
                                        into defaults: inout [Int: String]) {
        for node in nodes {
            switch node {
            case .literal:
                continue
            case .stop(let index, let children):
                if !children.isEmpty, defaults[index] == nil {
                    var text = ""
                    var ignored: [Int: [Range<Int>]] = [:]
                    render(children, context: context, defaults: defaults, text: &text, ranges: &ignored)
                    defaults[index] = text
                }
                collectDefaults(children, context: context, into: &defaults)
            case .variable(_, let fallback):
                collectDefaults(fallback, context: context, into: &defaults)
            }
        }
    }

    private static func render(_ nodes: [SnippetNode], context: SnippetContext,
                               defaults: [Int: String], text: inout String,
                               ranges: inout [Int: [Range<Int>]]) {
        for node in nodes {
            switch node {
            case .literal(let value):
                text += value

            case .stop(let index, let children):
                let start = text.count
                if children.isEmpty {
                    // Bare `$1`: mirror whatever `${1:…}` defined, or nothing.
                    text += defaults[index] ?? ""
                } else {
                    render(children, context: context, defaults: defaults, text: &text, ranges: &ranges)
                }
                ranges[index, default: []].append(start ..< text.count)

            case .variable(let name, let fallback):
                let resolved = context.value(for: name)
                if let resolved, !resolved.isEmpty {
                    text += resolved
                } else {
                    // Covers both an unknown variable and a known-but-empty one (the usual
                    // case being `${SELECTION:placeholder}` with nothing selected).
                    render(fallback, context: context, defaults: defaults, text: &text, ranges: &ranges)
                }
            }
        }
    }
}
