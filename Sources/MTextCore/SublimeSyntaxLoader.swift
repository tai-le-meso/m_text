import Foundation

/// Loads Sublime Text `.sublime-syntax` files (YAML).
///
/// Supported: `variables` with `{{name}}` expansion, `contexts` with `match`/`scope`/
/// `captures`/`push`/`pop`/`set`, inline anonymous contexts, `include` (internal and
/// `scope:` cross-grammar), `meta_scope`, `meta_content_scope`, `meta_include_prototype`,
/// `clear_scopes`, `prototype`, and `embed`/`escape` approximated as push/pop.
///
/// Not supported: `with_prototype` backreference substitution (`\1` inside a pushed
/// context), and `branch`/`fail`. Both are rare; grammars using them still load, with a
/// diagnostic, and simply highlight those constructs less precisely.
public struct SublimeSyntaxLoader {

    public private(set) var diagnostics = GrammarLoadDiagnostics()

    public init() {}

    public static func load(contentsOf url: URL) throws -> (grammar: Grammar, diagnostics: GrammarLoadDiagnostics) {
        let text = try String(contentsOf: url, encoding: .utf8)
        var loader = SublimeSyntaxLoader()
        let grammar = try loader.parse(text)
        return (grammar, loader.diagnostics)
    }

    public mutating func parse(_ text: String) throws -> Grammar {
        let root = try YAML.parse(text)
        guard let top = root.mapValue else {
            throw GrammarLoadError(reason: "syntax file is not a YAML mapping")
        }
        guard let scopeString = top["scope"]?.stringValue, !scopeString.isEmpty else {
            throw GrammarLoadError(reason: "syntax file has no 'scope'")
        }

        let variables = (top["variables"]?.mapValue ?? [:]).compactMapValues { $0.stringValue }
        let expanded = expandAll(variables)

        var grammar = Grammar(
            name: top["name"]?.stringValue ?? scopeString,
            scope: ScopeName(scopeString),
            fileExtensions: (top["file_extensions"]?.listValue ?? []).compactMap { $0.stringValue },
            hidden: (top["hidden"]?.stringValue ?? "false") == "true"
        )

        if let firstLine = top["first_line_match"]?.stringValue, !firstLine.isEmpty {
            grammar.firstLineMatch = try? RegexShim.compile(substitute(firstLine, expanded))
            if grammar.firstLineMatch == nil {
                diagnostics.note("first_line_match failed to compile: \(firstLine)")
            }
        }
        grammar.metadata = parseMetadata(top)

        guard let contextsMap = top["contexts"]?.mapValue else {
            throw GrammarLoadError(reason: "syntax file has no 'contexts'")
        }

        // Anonymous contexts declared inline get generated names, collected here.
        var contexts: [String: Context] = [:]
        var anonymousCounter = 0

        for (name, value) in contextsMap {
            let entries = value.listValue ?? []
            let context = parseContext(named: name,
                                       entries: entries,
                                       variables: expanded,
                                       contexts: &contexts,
                                       anonymousCounter: &anonymousCounter)
            contexts[name] = context
        }

        if contexts[Grammar.entryContext] == nil {
            throw GrammarLoadError(reason: "syntax file has no 'main' context")
        }
        grammar.contexts = flattenIncludes(contexts)
        return grammar
    }

    // MARK: - Contexts

    private mutating func parseContext(named name: String,
                                       entries: [YAMLValue],
                                       variables: [String: String],
                                       contexts: inout [String: Context],
                                       anonymousCounter: inout Int) -> Context {
        var context = Context(name: name)

        for entry in entries {
            guard let map = entry.mapValue else { continue }

            if let metaScope = map["meta_scope"]?.stringValue {
                context.metaScope = scopeList(metaScope)
                continue
            }
            if let metaContent = map["meta_content_scope"]?.stringValue {
                context.metaContentScope = scopeList(metaContent)
                continue
            }
            if let flag = map["meta_include_prototype"]?.stringValue {
                context.includesPrototype = flag != "false"
                continue
            }
            if let clear = map["clear_scopes"]?.stringValue {
                context.clearScopes = Int(clear) ?? (clear == "true" ? Int.max : 0)
                continue
            }
            if let include = map["include"]?.stringValue {
                // Resolved by flattenIncludes; kept as a placeholder carrying the name.
                context.patterns.append(Pattern(regex: nil,
                                                scopes: [ScopeName(include)],
                                                action: .none,
                                                isIncludePlaceholder: true))
                continue
            }

            if let pattern = parsePattern(map,
                                          variables: variables,
                                          contexts: &contexts,
                                          anonymousCounter: &anonymousCounter,
                                          owner: name) {
                context.patterns.append(pattern)
            }
        }
        return context
    }

    private mutating func parsePattern(_ map: [String: YAMLValue],
                                       variables: [String: String],
                                       contexts: inout [String: Context],
                                       anonymousCounter: inout Int,
                                       owner: String) -> Pattern? {
        guard let matchSource = map["match"]?.stringValue else { return nil }
        let substituted = substitute(matchSource, variables)

        let regex: CompiledRegex
        do {
            regex = try RegexShim.compile(substituted)
        } catch {
            diagnostics.note("context '\(owner)': pattern failed to compile: \(substituted)")
            return nil
        }

        var captures: [Int: [ScopeName]] = [:]
        if let capturesMap = map["captures"]?.mapValue {
            for (key, value) in capturesMap {
                guard let index = Int(key), let scopeString = value.stringValue else { continue }
                captures[index] = scopeList(scopeString)
            }
        }

        var action = PatternAction.none
        if let popValue = map["pop"]?.stringValue {
            // `pop: true` leaves one context; sublime-syntax 2 allows a count.
            action = .pop(popValue == "true" ? 1 : (Int(popValue) ?? 1))
        }
        if let pushValue = map["push"] {
            action = .push(contextReferences(pushValue,
                                             variables: variables,
                                             contexts: &contexts,
                                             anonymousCounter: &anonymousCounter,
                                             owner: owner))
        }
        if let setValue = map["set"] {
            action = .set(contextReferences(setValue,
                                            variables: variables,
                                            contexts: &contexts,
                                            anonymousCounter: &anonymousCounter,
                                            owner: owner))
        }
        if let embedValue = map["embed"] {
            // Approximation: treat an embedded syntax as a push. The escape pattern is
            // added to the embedded context so it can pop back out.
            var references = contextReferences(embedValue,
                                               variables: variables,
                                               contexts: &contexts,
                                               anonymousCounter: &anonymousCounter,
                                               owner: owner)
            if let escape = map["escape"]?.stringValue,
               let escapeRegex = try? RegexShim.compile(substitute(escape, variables)) {
                anonymousCounter += 1
                let escapeContextName = "__embed_\(anonymousCounter)"
                var escapeContext = Context(name: escapeContextName)
                escapeContext.patterns.append(Pattern(regex: escapeRegex, action: .pop(1)))
                for reference in references {
                    escapeContext.patterns.append(Pattern(regex: nil,
                                                          scopes: [ScopeName(reference)],
                                                          isIncludePlaceholder: true))
                }
                contexts[escapeContextName] = escapeContext
                references = [escapeContextName]
            }
            action = .push(references)
        }
        if map["branch"] != nil || map["fail"] != nil {
            diagnostics.note("context '\(owner)': branch/fail is not supported; pattern degraded")
        }

        return Pattern(regex: regex,
                       scopes: scopeList(map["scope"]?.stringValue ?? ""),
                       captures: captures,
                       action: action)
    }

    /// A `push`/`set`/`embed` value: context names, or inline anonymous contexts.
    private mutating func contextReferences(_ value: YAMLValue,
                                            variables: [String: String],
                                            contexts: inout [String: Context],
                                            anonymousCounter: inout Int,
                                            owner: String) -> [String] {
        switch value {
        case .string(let name):
            return name.isEmpty ? [] : [name]

        case .map:
            // A single inline pattern, e.g. `push: {match: …, pop: true}`.
            anonymousCounter += 1
            let name = "__anon_\(anonymousCounter)"
            let context = parseContext(named: name,
                                       entries: [value],
                                       variables: variables,
                                       contexts: &contexts,
                                       anonymousCounter: &anonymousCounter)
            contexts[name] = context
            return [name]

        case .list(let items):
            // Either a list of context names, or one inline context given as a list
            // of pattern maps.
            if items.allSatisfy({ $0.stringValue != nil }) {
                return items.compactMap { $0.stringValue }.filter { !$0.isEmpty }
            }
            anonymousCounter += 1
            let name = "__anon_\(anonymousCounter)"
            let context = parseContext(named: name,
                                       entries: items,
                                       variables: variables,
                                       contexts: &contexts,
                                       anonymousCounter: &anonymousCounter)
            contexts[name] = context
            return [name]
        }
    }

    // MARK: - Includes

    /// Replaces `include` placeholders with the referenced context's patterns.
    /// Cross-grammar `scope:` includes are dropped with a diagnostic — resolving them
    /// needs the whole grammar registry, which happens in `GrammarRegistry`.
    private mutating func flattenIncludes(_ contexts: [String: Context]) -> [String: Context] {
        var resolved = contexts
        // Iterate to a fixed point; includes can chain. Bounded to avoid cycles.
        for _ in 0 ..< 8 {
            var changed = false
            for (name, context) in resolved {
                guard context.patterns.contains(where: { $0.isIncludePlaceholder }) else { continue }
                var flattened: [Pattern] = []
                for pattern in context.patterns {
                    guard pattern.isIncludePlaceholder else {
                        flattened.append(pattern)
                        continue
                    }
                    let target = pattern.scopes.first?.raw ?? ""
                    if target.hasPrefix("scope:") {
                        flattened.append(pattern) // left for the registry to resolve
                        continue
                    }
                    guard target != name, let included = resolved[target] else {
                        if target != name {
                            diagnostics.note("context '\(name)': unknown include '\(target)'")
                        }
                        continue
                    }
                    // Drop any placeholder that would point straight back at us.
                    flattened.append(contentsOf: included.patterns.filter {
                        !$0.isIncludePlaceholder || $0.scopes.first?.raw != name
                    })
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

    // MARK: - Helpers

    private func parseMetadata(_ top: [String: YAMLValue]) -> GrammarMetadata {
        var metadata = GrammarMetadata()
        // Sublime carries comment tokens in a companion .tmPreferences file; many
        // grammars also declare them here under `metadata` or `settings`.
        let source = top["metadata"]?.mapValue ?? top["settings"]?.mapValue ?? [:]
        metadata.lineComment = source["line_comment"]?.stringValue ?? source["shellVariables"]?.stringValue
        if let open = source["block_comment_start"]?.stringValue,
           let close = source["block_comment_end"]?.stringValue {
            metadata.blockComment = (open, close)
        }
        metadata.wordSeparators = source["word_separators"]?.stringValue
        return metadata
    }

    private func scopeList(_ raw: String) -> [ScopeName] {
        raw.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map { ScopeName(String($0)) }
    }

    /// Expands `{{var}}` references inside the variables map itself, so variables may
    /// refer to other variables.
    private func expandAll(_ variables: [String: String]) -> [String: String] {
        var expanded = variables
        for _ in 0 ..< 8 {
            var changed = false
            for (key, value) in expanded {
                let substituted = substitute(value, expanded)
                if substituted != value {
                    expanded[key] = substituted
                    changed = true
                }
            }
            if !changed { break }
        }
        return expanded
    }

    private func substitute(_ pattern: String, _ variables: [String: String]) -> String {
        guard pattern.contains("{{") else { return pattern }
        var result = ""
        var index = pattern.startIndex
        while index < pattern.endIndex {
            guard pattern[index] == "{",
                  let open = pattern.range(of: "{{", range: index ..< pattern.endIndex),
                  open.lowerBound == index,
                  let close = pattern.range(of: "}}", range: open.upperBound ..< pattern.endIndex)
            else {
                result.append(pattern[index])
                index = pattern.index(after: index)
                continue
            }
            let name = String(pattern[open.upperBound ..< close.lowerBound])
            result += variables[name] ?? ""
            index = close.upperBound
        }
        return result
    }
}
