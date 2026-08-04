import Foundation

/// What a matched pattern does to the context stack.
public enum PatternAction {
    /// Stay in the current context.
    case none
    /// Enter the listed contexts (last one becomes current, as in sublime-syntax).
    case push([String])
    /// Leave `count` contexts.
    case pop(Int)
    /// Replace the current context with the listed ones.
    case set([String])
}

/// One `- match:` entry, or an `- include:` reference resolved at load time.
public struct Pattern {
    public var regex: CompiledRegex?
    /// Scopes applied to the whole match.
    public var scopes: [ScopeName]
    /// Scopes applied to individual capture groups.
    public var captures: [Int: [ScopeName]]
    public var action: PatternAction
    /// Contexts merged in by `include:` — flattened at load time so the tokenizer
    /// never has to follow references.
    public var isIncludePlaceholder: Bool

    public init(regex: CompiledRegex?,
                scopes: [ScopeName] = [],
                captures: [Int: [ScopeName]] = [:],
                action: PatternAction = .none,
                isIncludePlaceholder: Bool = false) {
        self.regex = regex
        self.scopes = scopes
        self.captures = captures
        self.action = action
        self.isIncludePlaceholder = isIncludePlaceholder
    }
}

/// A named set of patterns. Contexts are the states of the tokenizer's stack machine.
public struct Context {
    public var name: String
    /// Scope covering everything from the push that entered this context to the pop
    /// that leaves it, including the delimiters.
    public var metaScope: [ScopeName]
    /// Like `metaScope` but excluding the delimiters.
    public var metaContentScope: [ScopeName]
    /// When false, the grammar's `prototype` context is not merged in.
    public var includesPrototype: Bool
    /// `clear_scopes: n` — drop n scopes from the stack on entry.
    public var clearScopes: Int
    public var patterns: [Pattern]

    public init(name: String,
                metaScope: [ScopeName] = [],
                metaContentScope: [ScopeName] = [],
                includesPrototype: Bool = true,
                clearScopes: Int = 0,
                patterns: [Pattern] = []) {
        self.name = name
        self.metaScope = metaScope
        self.metaContentScope = metaContentScope
        self.includesPrototype = includesPrototype
        self.clearScopes = clearScopes
        self.patterns = patterns
    }
}

/// Editor behaviour a grammar declares alongside its patterns.
public struct GrammarMetadata {
    public var lineComment: String?
    public var blockComment: (open: String, close: String)?
    /// Extra characters treated as word separators for this language.
    public var wordSeparators: String?

    public init(lineComment: String? = nil,
                blockComment: (open: String, close: String)? = nil,
                wordSeparators: String? = nil) {
        self.lineComment = lineComment
        self.blockComment = blockComment
        self.wordSeparators = wordSeparators
    }
}

/// A loaded syntax definition.
public struct Grammar {
    public var name: String
    public var scope: ScopeName
    public var fileExtensions: [String]
    public var firstLineMatch: CompiledRegex?
    public var hidden: Bool
    public var contexts: [String: Context]
    public var metadata: GrammarMetadata

    /// Patterns that apply in every context that does not opt out.
    public var prototype: [Pattern] {
        contexts["prototype"]?.patterns ?? []
    }

    public static let entryContext = "main"

    public init(name: String,
                scope: ScopeName,
                fileExtensions: [String] = [],
                firstLineMatch: CompiledRegex? = nil,
                hidden: Bool = false,
                contexts: [String: Context] = [:],
                metadata: GrammarMetadata = GrammarMetadata()) {
        self.name = name
        self.scope = scope
        self.fileExtensions = fileExtensions
        self.firstLineMatch = firstLineMatch
        self.hidden = hidden
        self.contexts = contexts
        self.metadata = metadata
    }

    public func context(named name: String) -> Context? { contexts[name] }

    /// A grammar with no patterns, used when nothing matches a file.
    public static func plainText() -> Grammar {
        Grammar(name: "Plain Text",
                scope: ScopeName("text.plain"),
                fileExtensions: ["txt"],
                contexts: [entryContext: Context(name: entryContext)])
    }
}

/// Problems encountered while loading a grammar. Collected rather than thrown, so one
/// bad pattern does not discard an otherwise usable syntax definition.
public struct GrammarLoadDiagnostics {
    public var messages: [String] = []
    public var isEmpty: Bool { messages.isEmpty }

    mutating func note(_ message: String) { messages.append(message) }
}

public struct GrammarLoadError: LocalizedError {
    public let reason: String
    public var errorDescription: String? { reason }
}
