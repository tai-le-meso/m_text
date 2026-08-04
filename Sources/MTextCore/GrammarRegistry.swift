import Foundation

/// Holds the loaded grammars and picks one for a file.
///
/// Also resolves cross-grammar `include: scope:source.x` references, which a single
/// loader cannot do on its own — it needs to see every grammar first.
public final class GrammarRegistry {

    public private(set) var grammars: [Grammar] = []
    public private(set) var diagnostics: [String] = []

    /// Grammar by scope name, for cross-grammar includes and explicit selection.
    private var byScope: [String: Int] = [:]

    public init() {}

    // MARK: - Loading

    /// Drops every loaded grammar, for a full reload after an import.
    public func removeAll() {
        grammars.removeAll()
        byScope.removeAll()
        diagnostics.removeAll()
    }

    /// Rebuilds from the built-in set plus whatever is installed in `packagesDirectory`.
    /// Later additions with the same scope win, so a user grammar overrides a built-in.
    public func reload(packagesDirectory: URL?) {
        removeAll()
        add(.plainText())
        for (index, source) in BuiltInGrammars.all.enumerated() {
            var loader = SublimeSyntaxLoader()
            do {
                add(try loader.parse(source))
                diagnostics.append(contentsOf: loader.diagnostics.messages)
            } catch {
                diagnostics.append("built-in grammar #\(index): \(error.localizedDescription)")
            }
        }
        if let packagesDirectory,
           FileManager.default.fileExists(atPath: packagesDirectory.path) {
            loadGrammars(in: packagesDirectory)
        } else {
            // loadGrammars would have done this; built-ins can use scope: includes too.
            resolveCrossGrammarIncludes()
        }
    }

    /// `priority` puts the grammar ahead of everything already loaded for
    /// extension/first-line detection, which is what makes an imported grammar able to
    /// claim an extension a built-in already lists (`.html`, `.vue`, `.conf`…). Without
    /// it, a user grammar could only win by reusing a built-in's exact scope.
    public func add(_ grammar: Grammar, priority: Bool = false) {
        if let existing = byScope[grammar.scope.raw] {
            grammars[existing] = grammar
            return
        }
        if priority {
            grammars.insert(grammar, at: 0)
            reindex()
        } else {
            byScope[grammar.scope.raw] = grammars.count
            grammars.append(grammar)
        }
    }

    private func reindex() {
        byScope.removeAll(keepingCapacity: true)
        for (index, grammar) in grammars.enumerated() {
            byScope[grammar.scope.raw] = index
        }
    }

    /// Loads every `.sublime-syntax` and `.tmLanguage` in `directory`, recursively.
    /// Unreadable or malformed files are recorded and skipped.
    public func loadGrammars(in directory: URL) {
        let manager = FileManager.default
        guard let walker = manager.enumerator(at: directory,
                                              includingPropertiesForKeys: nil,
                                              options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in walker {
            switch url.pathExtension.lowercased() {
            case "sublime-syntax":
                do {
                    let loaded = try SublimeSyntaxLoader.load(contentsOf: url)
                    add(loaded.grammar, priority: true)
                    diagnostics.append(contentsOf: loaded.diagnostics.messages.map {
                        "\(url.lastPathComponent): \($0)"
                    })
                } catch {
                    diagnostics.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            case "tmlanguage":
                do {
                    let loaded = try TMLanguageLoader.load(contentsOf: url)
                    add(loaded.grammar, priority: true)
                    diagnostics.append(contentsOf: loaded.diagnostics.messages.map {
                        "\(url.lastPathComponent): \($0)"
                    })
                } catch {
                    diagnostics.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            default:
                break
            }
        }
        resolveCrossGrammarIncludes()
    }

    /// Replaces `include: scope:source.x` placeholders with the target grammar's main
    /// context patterns. One level deep, which covers embedded languages in practice.
    private func resolveCrossGrammarIncludes() {
        for index in grammars.indices {
            // Named `current`, not `grammar`: a local of that name would shadow the
            // grammar(forScope:) method used below.
            var current = grammars[index]
            var changed = false

            for (name, context) in current.contexts {
                guard context.patterns.contains(where: { $0.isIncludePlaceholder }) else { continue }
                var flattened: [Pattern] = []
                for pattern in context.patterns {
                    guard pattern.isIncludePlaceholder,
                          let target = pattern.scopes.first?.raw else {
                        flattened.append(pattern)
                        continue
                    }
                    guard target.hasPrefix("scope:") else {
                        diagnostics.append("\(current.name): unresolved include '\(target)'")
                        continue
                    }
                    let scope = String(target.dropFirst("scope:".count))
                    guard let other = self.grammar(forScope: scope) else {
                        diagnostics.append("\(current.name): unresolved include scope:\(scope)")
                        continue
                    }
                    // Namespace the borrowed contexts so they cannot collide.
                    let prefix = "\(scope)@"
                    for (otherName, otherContext) in other.contexts
                    where current.contexts[prefix + otherName] == nil {
                        var copied = otherContext
                        copied.name = prefix + otherName
                        copied.patterns = otherContext.patterns.map { rename($0, prefix: prefix) }
                        current.contexts[prefix + otherName] = copied
                    }
                    if let main = current.contexts[prefix + Grammar.entryContext] {
                        flattened.append(contentsOf: main.patterns)
                        changed = true
                    }
                }
                var updated = context
                updated.patterns = flattened
                current.contexts[name] = updated
            }
            if changed { grammars[index] = current }
        }
    }

    private func rename(_ pattern: Pattern, prefix: String) -> Pattern {
        var renamed = pattern
        switch pattern.action {
        case .push(let names): renamed.action = .push(names.map { prefix + $0 })
        case .set(let names): renamed.action = .set(names.map { prefix + $0 })
        case .pop, .none: break
        }
        return renamed
    }

    // MARK: - Lookup

    public func grammar(forScope scope: String) -> Grammar? {
        byScope[scope].map { grammars[$0] }
    }

    public func grammar(named name: String) -> Grammar? {
        grammars.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Picks a grammar by file extension, then by first-line match (shebang, XML
    /// declaration), falling back to plain text.
    public func grammar(for url: URL?, firstLine: String? = nil) -> Grammar {
        if let url {
            let ext = url.pathExtension.lowercased()
            if !ext.isEmpty,
               let match = grammars.first(where: { grammar in
                   !grammar.hidden && grammar.fileExtensions.contains { $0.lowercased() == ext }
               }) {
                return match
            }
            // Whole-name matches (Makefile, Dockerfile) and dotfiles. A grammar lists
            // "bashrc", so ".bashrc" must be compared with the leading dot stripped —
            // note `pathExtension` is empty for ".bashrc", not "bashrc".
            let fileName = url.lastPathComponent.lowercased()
            let bare = fileName.hasPrefix(".") ? String(fileName.dropFirst()) : fileName
            if let match = grammars.first(where: { grammar in
                !grammar.hidden && grammar.fileExtensions.contains {
                    let candidate = $0.lowercased()
                    return candidate == fileName || candidate == bare
                }
            }) {
                return match
            }
        }

        if let firstLine, !firstLine.isEmpty {
            for grammar in grammars where !grammar.hidden {
                guard let regex = grammar.firstLineMatch else { continue }
                if regex.firstMatch(in: firstLine, from: 0) != nil { return grammar }
            }
        }
        return grammars.first { $0.scope.raw == "text.plain" } ?? .plainText()
    }

    /// Grammars offered in a "Set Syntax" menu, alphabetically.
    public var selectableGrammars: [Grammar] {
        grammars.filter { !$0.hidden }.sorted { $0.name < $1.name }
    }
}
