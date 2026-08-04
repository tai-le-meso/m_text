import Foundation

/// A dotted scope name such as `keyword.control.flow.swift`.
///
/// Stored pre-split because selector matching compares components, and a highlighter
/// does that comparison millions of times over a large file.
public struct ScopeName: Hashable {
    public let raw: String
    public let components: [String]

    public init(_ raw: String) {
        self.raw = raw
        self.components = raw.split(separator: ".").map(String.init)
    }

    /// True when `self` is `prefix` or a more specific child of it:
    /// `keyword.control` matches `keyword`, but `keywords` does not.
    public func isDescendant(of prefix: ScopeName) -> Bool {
        guard prefix.components.count <= components.count else { return false }
        for (index, component) in prefix.components.enumerated() where components[index] != component {
            return false
        }
        return true
    }
}

/// The stack of scopes in effect at a point in the text, outermost first —
/// e.g. `["source.swift", "string.quoted.double.swift", "constant.character.escape.swift"]`.
public struct ScopeStack: Hashable {
    public private(set) var scopes: [ScopeName]

    public init(_ scopes: [ScopeName] = []) {
        self.scopes = scopes
    }

    public init(_ names: [String]) {
        self.scopes = names.map(ScopeName.init)
    }

    public var isEmpty: Bool { scopes.isEmpty }
    public var innermost: ScopeName? { scopes.last }

    public mutating func push(_ scope: ScopeName) { scopes.append(scope) }

    public mutating func push(contentsOf newScopes: [ScopeName]) {
        scopes.append(contentsOf: newScopes)
    }

    @discardableResult
    public mutating func pop() -> ScopeName? { scopes.popLast() }

    public func pushing(_ newScopes: [ScopeName]) -> ScopeStack {
        var copy = self
        copy.push(contentsOf: newScopes)
        return copy
    }

    /// Space-joined form, as Sublime displays it in the status bar.
    public var description: String { scopes.map(\.raw).joined(separator: " ") }
}

/// A scope selector from a color scheme or keybinding context, e.g.
/// `string, comment` or `source.swift meta.function entity.name`.
///
/// Supports the subset colour schemes actually use: comma-separated alternatives,
/// space-separated descendant paths, and `-` exclusions.
public struct ScopeSelector {

    /// One comma-separated alternative: a descendant path plus any exclusions.
    struct Alternative {
        let path: [ScopeName]
        let excluded: [ScopeName]

        /// Sum of the matched prefixes' component counts — longer, more specific
        /// selectors win. Mirrors TextMate's ranking closely enough for themes.
        func score(against stack: ScopeStack) -> Int? {
            for exclusion in excluded where stack.scopes.contains(where: { $0.isDescendant(of: exclusion) }) {
                return nil
            }
            guard !path.isEmpty else { return 0 }

            // Walk the stack outermost-to-innermost, consuming the path in order.
            var pathIndex = 0
            var total = 0
            var depthBonus = 0
            for (depth, scope) in stack.scopes.enumerated() {
                guard pathIndex < path.count else { break }
                if scope.isDescendant(of: path[pathIndex]) {
                    total += path[pathIndex].components.count
                    depthBonus = depth
                    pathIndex += 1
                }
            }
            guard pathIndex == path.count else { return nil }
            // Specificity must dominate depth: a stack deeper than the multiplier
            // would otherwise let a vaguer selector matching deeper win.
            return total * 1024 + min(depthBonus, 1023)
        }
    }

    let alternatives: [Alternative]
    public let raw: String

    public init(_ raw: String) {
        self.raw = raw
        self.alternatives = raw
            .split(separator: ",")
            .map { alternative -> Alternative in
                var path: [ScopeName] = []
                var excluded: [ScopeName] = []
                // Both `-comment` and `- comment` are valid exclusion syntax; a bare
                // `-` negates the following token.
                var negateNext = false
                for token in alternative.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                    if token == "-" {
                        negateNext = true
                    } else if token.hasPrefix("-") {
                        let name = String(token.dropFirst())
                        if !name.isEmpty { excluded.append(ScopeName(name)) }
                        negateNext = false
                    } else if negateNext {
                        excluded.append(ScopeName(String(token)))
                        negateNext = false
                    } else {
                        path.append(ScopeName(String(token)))
                    }
                }
                return Alternative(path: path, excluded: excluded)
            }
            .filter { !($0.path.isEmpty && $0.excluded.isEmpty) }
    }

    /// Highest score across alternatives, or nil when nothing matches.
    public func score(against stack: ScopeStack) -> Int? {
        var best: Int?
        for alternative in alternatives {
            if let score = alternative.score(against: stack) {
                best = max(best ?? Int.min, score)
            }
        }
        return best
    }

    public func matches(_ stack: ScopeStack) -> Bool {
        score(against: stack) != nil
    }
}

/// A contiguous run of text sharing one scope stack, in **UTF-16 offsets** relative to
/// the start of its line — the unit CoreText and NSRegularExpression both use.
/// (`PieceTree` is byte-indexed; do not mix the two.)
public struct ScopeSpan {
    public var start: Int
    public var end: Int
    public var scopes: ScopeStack

    public init(start: Int, end: Int, scopes: ScopeStack) {
        self.start = start
        self.end = end
        self.scopes = scopes
    }

    public var length: Int { max(0, end - start) }
}
