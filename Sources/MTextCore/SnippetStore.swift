import Foundation

/// Reads `.sublime-snippet` files, which are small XML documents:
///
/// ```xml
/// <snippet>
///   <content><![CDATA[for ${1:item} in ${2:sequence}:\n\t$0]]></content>
///   <tabTrigger>for</tabTrigger>
///   <scope>source.python</scope>
///   <description>for loop</description>
/// </snippet>
/// ```
///
/// Uses Foundation's `XMLParser` rather than a hand-rolled scanner — unlike
/// `.sublime-syntax` (YAML) and `.sublime-settings` (JSON-with-comments), this format is
/// real XML with CDATA, and the platform already parses it correctly including entities.
public final class SnippetParser: NSObject, XMLParserDelegate {

    public enum ParseError: Error, Equatable { case malformedXML, noContent }

    private var currentElement = ""
    private var buffers: [String: String] = [:]

    public static func parse(data: Data, name: String) throws -> Snippet {
        let parser = SnippetParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        guard xml.parse() else { throw ParseError.malformedXML }

        // Whitespace around the CDATA is part of the file's indentation, not the snippet —
        // but *inside* it is significant, so only the outer edges are trimmed.
        guard let content = parser.buffers["content"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty
        else { throw ParseError.noContent }

        func field(_ key: String) -> String? {
            let value = parser.buffers[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (value?.isEmpty ?? true) ? nil : value
        }
        return Snippet(content: content,
                       tabTrigger: field("tabTrigger"),
                       scope: field("scope"),
                       description: field("description"),
                       name: name)
    }

    // MARK: - XMLParserDelegate

    public func parser(_ parser: XMLParser, didStartElement elementName: String,
                       namespaceURI: String?, qualifiedName qName: String?,
                       attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffers[currentElement, default: ""] += string
    }

    /// Snippet bodies are conventionally wrapped in CDATA precisely because they contain
    /// `<`, `&` and `$`; without this they'd arrive as nothing.
    public func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let text = String(data: CDATABlock, encoding: .utf8) else { return }
        buffers[currentElement, default: ""] += text
    }
}

/// Loads every snippet available to the app and answers "what fires for this trigger, in
/// this scope?".
///
/// Scans the same two folders the rest of the app already uses — the bundled `Packages`
/// directory and the user's — so dropping a `.sublime-snippet` in works without a rebuild,
/// matching how grammars and colour schemes behave (T55).
public final class SnippetStore {

    public private(set) var snippets: [Snippet] = []

    /// Directories scanned, in precedence order (later wins on a name clash).
    private let directories: [URL]

    public init(directories: [URL]) {
        self.directories = directories
        reload()
    }

    /// `~/Library/Application Support/m_text/Packages` plus a `Snippets` subfolder,
    /// matching `PackageManager`'s layout.
    public convenience init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let root = support.appendingPathComponent("m_text", isDirectory: true)
        self.init(directories: [
            root.appendingPathComponent("Packages", isDirectory: true),
            root.appendingPathComponent("Snippets", isDirectory: true),
        ])
    }

    /// Replaces the loaded set without touching the disk — for tests, which exercise
    /// trigger/scope resolution rather than directory scanning.
    public func replaceForTesting(_ snippets: [Snippet]) {
        self.snippets = snippets
    }

    public func reload() {
        // Built-ins first so file-based snippets are appended after them and win ties in
        // `snippet(forTrigger:scope:)` — a user file replacing a built-in trigger should
        // take effect, exactly like a drop-in grammar overriding a bundled one.
        var found: [Snippet] = BuiltInSnippets.all
        for directory in directories {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
            for url in urls where url.pathExtension.lowercased() == "sublime-snippet" {
                // One malformed file must not cost the user every other snippet — same
                // rule the grammar and settings loaders follow.
                guard let data = try? Data(contentsOf: url),
                      let snippet = try? SnippetParser.parse(
                          data: data, name: url.deletingPathExtension().lastPathComponent)
                else { continue }
                found.append(snippet)
            }
        }
        snippets = found
    }

    /// The snippet a Tab press should expand, given the word before the caret and the
    /// scope there.
    ///
    /// Scope filtering reuses `ScopeSelector` — the same matcher colour schemes use — so a
    /// snippet scoped `source.python` behaves the way it would in Sublime. A snippet with
    /// no scope matches anywhere. When several match, the **most specific scope wins**,
    /// which is what makes a language-specific snippet able to shadow a general one.
    public func snippet(forTrigger trigger: String, scope: String?) -> Snippet? {
        guard !trigger.isEmpty else { return nil }
        let candidates = snippets.filter { $0.tabTrigger == trigger }
        guard !candidates.isEmpty else { return nil }

        var best: (snippet: Snippet, score: Int)?
        for candidate in candidates {
            guard let selector = candidate.scope else {
                if best == nil { best = (candidate, 0) }
                continue
            }
            guard let scope,
                  let score = ScopeSelector(selector).score(against: ScopeStack([scope])),
                  score > 0
            else { continue }
            // `>=`, not `>`: later entries are user files (built-ins are loaded first), so
            // an equally specific user snippet replaces the built-in rather than losing to it.
            if best == nil || score >= best!.score { best = (candidate, score) }
        }
        return best?.snippet
    }
}
