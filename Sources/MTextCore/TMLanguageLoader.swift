import Foundation

/// Loads TextMate `.tmLanguage` grammars (XML property lists), which Sublime also
/// accepts. Foundation parses the plist, so this loader is mostly a translation of
/// TextMate's begin/end model onto our context stack machine:
///
/// - a `match` rule becomes a pattern with no action;
/// - a `begin`/`end` rule becomes a push into a generated context whose first pattern
///   is the `end` regex with `pop`, carrying `contentName` as a meta content scope;
/// - `repository` entries become named contexts, `$self`/`$base` map to `main`.
///
/// Not supported: `while` rules (rare), and `applyEndPatternLast` ordering nuances.
public struct TMLanguageLoader {

    public private(set) var diagnostics = GrammarLoadDiagnostics()
    private var generatedCounter = 0

    public init() {}

    public static func load(contentsOf url: URL) throws -> (grammar: Grammar, diagnostics: GrammarLoadDiagnostics) {
        let data = try Data(contentsOf: url)
        var loader = TMLanguageLoader()
        let grammar = try loader.parse(data)
        return (grammar, loader.diagnostics)
    }

    public mutating func parse(_ data: Data) throws -> Grammar {
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let top = object as? [String: Any] else {
            throw GrammarLoadError(reason: "tmLanguage is not a dictionary")
        }
        guard let scopeString = top["scopeName"] as? String else {
            throw GrammarLoadError(reason: "tmLanguage has no scopeName")
        }

        var contexts: [String: Context] = [:]

        // The repository provides named rule sets referenced as `#name`.
        if let repository = top["repository"] as? [String: Any] {
            for (name, value) in repository {
                guard let entry = value as? [String: Any] else { continue }
                let rules = (entry["patterns"] as? [Any]) ?? [value]
                // Built into a local first: the RHS writes generated contexts through
                // the same inout dictionary this assignment targets.
                let built = patterns(from: rules, into: &contexts)
                contexts["#" + name] = Context(name: "#" + name, patterns: built)
            }
        }

        let rootRules = (top["patterns"] as? [Any]) ?? []
        let rootPatterns = patterns(from: rootRules, into: &contexts)
        contexts[Grammar.entryContext] = Context(name: Grammar.entryContext, patterns: rootPatterns)

        var grammar = Grammar(
            name: (top["name"] as? String) ?? scopeString,
            scope: ScopeName(scopeString),
            fileExtensions: (top["fileTypes"] as? [String]) ?? [],
            contexts: contexts
        )
        if let firstLine = top["firstLineMatch"] as? String {
            grammar.firstLineMatch = try? RegexShim.compile(firstLine)
        }
        grammar.metadata = metadata(from: top)
        grammar.contexts = flattenIncludes(resolveSelfReferences(grammar.contexts))
        return grammar
    }

    /// Splices `#name` / `main` include placeholders into the referencing context.
    ///
    /// Without this every repository reference stays an inert placeholder (the
    /// tokenizer skips patterns with no regex), so a TextMate grammar would highlight
    /// only its top-level rules.
    private mutating func flattenIncludes(_ contexts: [String: Context]) -> [String: Context] {
        var resolved = contexts
        // Iterate to a fixed point; includes chain. Bounded to survive cycles.
        for _ in 0 ..< 8 {
            var changed = false
            for (name, context) in resolved {
                guard context.patterns.contains(where: { $0.isIncludePlaceholder }) else { continue }
                var flattened: [Pattern] = []
                for pattern in context.patterns {
                    guard pattern.isIncludePlaceholder,
                          let target = pattern.scopes.first?.raw else {
                        flattened.append(pattern)
                        continue
                    }
                    if target.hasPrefix("scope:") {
                        flattened.append(pattern) // left for GrammarRegistry
                        continue
                    }
                    guard target != name, let included = resolved[target] else {
                        if target != name {
                            diagnostics.note("context '\(name)': unknown include '\(target)'")
                        }
                        continue
                    }
                    flattened.append(contentsOf: included.patterns)
                    changed = true
                }
                var updated = context
                updated.patterns = flattened
                resolved[name] = updated
            }
            if !changed { break }
        }
        return resolved
    }

    // MARK: - Rules

    private mutating func patterns(from rules: [Any], into contexts: inout [String: Context]) -> [Pattern] {
        var result: [Pattern] = []
        for rule in rules {
            guard let map = rule as? [String: Any] else { continue }
            result.append(contentsOf: self.patterns(from: map, into: &contexts))
        }
        return result
    }

    private mutating func patterns(from rule: [String: Any], into contexts: inout [String: Context]) -> [Pattern] {
        // `include` — reference another rule set.
        if let include = rule["include"] as? String {
            return [Pattern(regex: nil, scopes: [ScopeName(include)], isIncludePlaceholder: true)]
        }

        let scopes = scopeList(rule["name"] as? String ?? "")

        // Simple match rule.
        if let match = rule["match"] as? String {
            guard let regex = compile(match) else { return [] }
            return [Pattern(regex: regex,
                            scopes: scopes,
                            captures: captures(rule["captures"]),
                            action: .none)]
        }

        // begin/end rule → push into a generated context.
        if let begin = rule["begin"] as? String, let end = rule["end"] as? String {
            guard let beginRegex = compile(begin) else { return [] }
            guard let endRegex = compile(end) else { return [] }

            generatedCounter += 1
            let name = "__tm_\(generatedCounter)"
            var context = Context(name: name)
            context.metaScope = scopes
            context.metaContentScope = scopeList(rule["contentName"] as? String ?? "")

            let endCaptures = captures(rule["endCaptures"] ?? rule["captures"])
            let endPattern = Pattern(regex: endRegex, captures: endCaptures, action: .pop(1))
            // TextMate applies the end pattern first unless told otherwise.
            let endLast = (rule["applyEndPatternLast"] as? NSNumber)?.intValue == 1

            var inner: [Pattern] = []
            if let nested = rule["patterns"] as? [Any] {
                inner = patterns(from: nested, into: &contexts)
            }
            context.patterns = endLast ? inner + [endPattern] : [endPattern] + inner
            contexts[name] = context

            let beginCaptures = captures(rule["beginCaptures"] ?? rule["captures"])
            return [Pattern(regex: beginRegex,
                            scopes: scopes,
                            captures: beginCaptures,
                            action: .push([name]))]
        }

        // A bare container of patterns.
        if let nested = rule["patterns"] as? [Any] {
            return patterns(from: nested, into: &contexts)
        }
        if rule["while"] != nil {
            diagnostics.note("'while' rules are not supported; rule skipped")
        }
        return []
    }

    private mutating func compile(_ pattern: String) -> CompiledRegex? {
        do {
            return try RegexShim.compile(pattern)
        } catch {
            diagnostics.note("pattern failed to compile: \(pattern)")
            return nil
        }
    }

    private func captures(_ value: Any?) -> [Int: [ScopeName]] {
        guard let map = value as? [String: Any] else { return [:] }
        var result: [Int: [ScopeName]] = [:]
        for (key, entry) in map {
            guard let index = Int(key),
                  let dictionary = entry as? [String: Any],
                  let name = dictionary["name"] as? String
            else { continue }
            result[index] = scopeList(name)
        }
        return result
    }

    /// `$self` and `$base` both mean "start over from the root context".
    private func resolveSelfReferences(_ contexts: [String: Context]) -> [String: Context] {
        var resolved = contexts
        for (name, context) in contexts {
            var updated = context
            updated.patterns = context.patterns.map { pattern in
                guard pattern.isIncludePlaceholder,
                      let target = pattern.scopes.first?.raw,
                      target == "$self" || target == "$base"
                else { return pattern }
                var rewritten = pattern
                rewritten.scopes = [ScopeName(Grammar.entryContext)]
                return rewritten
            }
            resolved[name] = updated
        }
        return resolved
    }

    private func metadata(from top: [String: Any]) -> GrammarMetadata {
        var metadata = GrammarMetadata()
        // TextMate stores comment tokens in shellVariables inside settings.
        if let settings = top["settings"] as? [String: Any],
           let variables = settings["shellVariables"] as? [[String: Any]] {
            for variable in variables {
                guard let name = variable["name"] as? String,
                      let value = variable["value"] as? String else { continue }
                switch name {
                case "TM_COMMENT_START": metadata.lineComment = value.trimmingCharacters(in: .whitespaces)
                case "TM_COMMENT_START_2": metadata.blockComment = (value, metadata.blockComment?.close ?? "")
                case "TM_COMMENT_END_2": metadata.blockComment = (metadata.blockComment?.open ?? "", value)
                default: break
                }
            }
        }
        return metadata
    }

    private func scopeList(_ raw: String) -> [ScopeName] {
        raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { ScopeName(String($0)) }
    }
}
