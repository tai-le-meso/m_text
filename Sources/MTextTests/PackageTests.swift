import Foundation
import MTextCore
import MTextTestKit

enum PackageTests {

    static let suite = TestSuite("Packages", [
        ("every built-in grammar loads clean", testAllBuiltInsLoad),
        ("built-in scopes are unique", testBuiltInScopesUnique),
        ("Spring project files are detected", testSpringFileDetection),
        ("web and JVM extensions are detected", testLanguageDetection),
        ("shebang detection", testShebangDetection),
        ("Java highlights annotations and text blocks", testJavaTokens),
        ("YAML highlights keys and anchors", testYAMLTokens),
        ("properties highlights keys and placeholders", testPropertiesTokens),
        ("import installs a valid grammar", testImportValidGrammar),
        ("import rejects a broken grammar", testImportBrokenGrammar),
        ("import rejects an unsupported type", testImportUnsupportedType),
        ("import scans a folder", testImportFolder),
        ("re-import replaces the previous copy", testImportReplaces),
        ("imported grammar overrides a built-in scope", testImportOverridesBuiltIn),
        ("import rejects an empty folder", testImportEmptyFolder),
        ("remove refuses paths outside Packages", testRemoveGuard),
        ("re-importing an installed file is safe", testImportFromPackagesFolder),
        ("imported grammar claims a built-in extension", testImportClaimsExtension),
        ("dotfiles resolve by whole name", testDotfileDetection),
    ])

    // MARK: - Built-ins

    static func testAllBuiltInsLoad() {
        for source in BuiltInGrammars.all {
            var loader = SublimeSyntaxLoader()
            do {
                let grammar = try loader.parse(source)
                expectTrue(grammar.context(named: "main") != nil,
                           "\(grammar.name) has no main context")
                expectFalse(grammar.name.isEmpty)
                expectTrue(loader.diagnostics.isEmpty,
                           "\(grammar.name): \(loader.diagnostics.messages)")
            } catch {
                fail("a built-in grammar failed to load: \(error)")
            }
        }
    }

    static func testBuiltInScopesUnique() {
        var seen: [String: String] = [:]
        for source in BuiltInGrammars.all {
            var loader = SublimeSyntaxLoader()
            guard let grammar = try? loader.parse(source) else { continue }
            if let previous = seen[grammar.scope.raw] {
                fail("scope \(grammar.scope.raw) used by both \(previous) and \(grammar.name)")
            }
            seen[grammar.scope.raw] = grammar.name
        }
        expectEqual(seen.count, BuiltInGrammars.all.count)
    }

    // MARK: - Detection

    private static func scope(of path: String, firstLine: String? = nil) -> String {
        BuiltInGrammars.registry()
            .grammar(for: URL(fileURLWithPath: path), firstLine: firstLine)
            .scope.raw
    }

    /// The languages a Spring codebase actually contains.
    static func testSpringFileDetection() {
        expectEqual(scope(of: "/p/src/main/java/App.java"), "source.java")
        expectEqual(scope(of: "/p/src/main/resources/application.yml"), "source.yaml")
        expectEqual(scope(of: "/p/src/main/resources/application.yaml"), "source.yaml")
        expectEqual(scope(of: "/p/src/main/resources/application.properties"), "source.java-properties")
        expectEqual(scope(of: "/p/pom.xml"), "text.xml")
    }

    static func testLanguageDetection() {
        expectEqual(scope(of: "/a/b.ts"), "source.ts")
        expectEqual(scope(of: "/a/b.tsx"), "source.ts")
        expectEqual(scope(of: "/a/b.js"), "source.js")
        expectEqual(scope(of: "/a/b.mjs"), "source.js")
        expectEqual(scope(of: "/a/b.css"), "source.css")
        expectEqual(scope(of: "/a/b.scss"), "source.css")
        expectEqual(scope(of: "/a/b.md"), "text.html.markdown")
        expectEqual(scope(of: "/a/b.json"), "source.json")
        expectEqual(scope(of: "/a/b.swift"), "source.swift")
        expectEqual(scope(of: "/a/b.unknownext"), "text.plain")
    }

    static func testShebangDetection() {
        expectEqual(scope(of: "/a/script", firstLine: "#!/usr/bin/env python3"), "source.python")
        expectEqual(scope(of: "/a/script", firstLine: "#!/bin/bash"), "source.shell")
        expectEqual(scope(of: "/a/script", firstLine: "#!/usr/bin/env node"), "source.js")
        expectEqual(scope(of: "/a/doc", firstLine: "<?xml version=\"1.0\"?>"), "text.xml")
    }

    // MARK: - Token spot-checks

    private static func innermostScopes(_ text: String, grammarSource: String) -> [String] {
        var loader = SublimeSyntaxLoader()
        guard let grammar = try? loader.parse(grammarSource) else {
            fail("grammar failed to load")
            return []
        }
        let tokenizer = Tokenizer(grammar: grammar)
        var state = TokenizerState.initial(for: grammar)
        var scopes: [String] = []
        for line in text.components(separatedBy: "\n") {
            let result = tokenizer.tokenize(line: line, state: state)
            state = result.state
            scopes.append(contentsOf: result.spans.compactMap { $0.scopes.innermost?.raw })
        }
        return scopes
    }

    static func testJavaTokens() {
        let scopes = innermostScopes("""
        @RestController
        public class App {
            private static final String X = "hi";
        }
        """, grammarSource: BuiltInGrammars.java)

        expectTrue(scopes.contains("storage.modifier.annotation.java"), "@RestController")
        expectTrue(scopes.contains("storage.modifier.java"), "public/private/static/final")
        expectTrue(scopes.contains("storage.type.class.java"), "class")
        expectTrue(scopes.contains("entity.name.type.class.java"), "App")
        expectTrue(scopes.contains("string.quoted.double.java"), "\"hi\"")
    }

    static func testYAMLTokens() {
        let scopes = innermostScopes("""
        # comment
        server:
          port: 8080
        spring:
          datasource:
            url: "jdbc:h2:mem:test"
        """, grammarSource: BuiltInGrammars.yaml)

        expectTrue(scopes.contains("comment.line.number-sign.yaml"))
        expectTrue(scopes.contains("entity.name.tag.yaml"), "keys")
        expectTrue(scopes.contains("constant.numeric.yaml"), "8080")
        expectTrue(scopes.contains("string.quoted.double.yaml"))
    }

    static func testPropertiesTokens() {
        let scopes = innermostScopes("""
        # comment
        server.port=8080
        spring.datasource.url=${DB_URL}
        """, grammarSource: BuiltInGrammars.properties)

        expectTrue(scopes.contains("comment.line.java-properties"))
        expectTrue(scopes.contains("entity.name.tag.java-properties"), "keys")
        expectTrue(scopes.contains("variable.other.placeholder.java-properties"), "${DB_URL}")
    }

    // MARK: - Import

    private static let validGrammar = #"""
    %YAML 1.2
    ---
    name: Imported Test
    scope: source.imported-test
    file_extensions: [itest]
    contexts:
      main:
        - match: '\bhello\b'
          scope: keyword.control.imported
    """#

    private static func write(_ contents: String, named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func testImportValidGrammar() throws {
        try withTemporaryDirectory("pkg-valid") { dir in
            let source = try write(validGrammar, named: "Test.sublime-syntax", in: dir.url)
            let packages = dir.url.appendingPathComponent("Packages")
            let manager = PackageManager(packagesDirectory: packages)

            let report = try manager.import(from: source)
            expectEqual(report.installed.count, 1)
            expectEqual(report.installed.first?.name, "Imported Test")
            expectEqual(report.installed.first?.scope, "source.imported-test")
            expectFalse(report.installed.first?.replacedExisting ?? true)
            expectEqual(report.rejected.count, 0)

            // Installed on disk, and picked up by a reload.
            expectEqual(manager.installedFiles().count, 1)
            let registry = GrammarRegistry()
            registry.reload(packagesDirectory: packages)
            expectEqual(registry.grammar(for: URL(fileURLWithPath: "/a/b.itest")).scope.raw,
                        "source.imported-test")
        }
    }

    static func testImportBrokenGrammar() throws {
        try withTemporaryDirectory("pkg-broken") { dir in
            // Valid YAML, but no `scope:` — the loader must refuse it.
            let broken = try write("""
            %YAML 1.2
            ---
            name: Broken
            contexts:
              main: []
            """, named: "Broken.sublime-syntax", in: dir.url)
            let manager = PackageManager(packagesDirectory: dir.url.appendingPathComponent("Packages"))

            expectThrows({ _ = try manager.import(from: broken) })
            expectEqual(manager.installedFiles().count, 0,
                        "a grammar that fails to load must not be installed")
        }
    }

    static func testImportUnsupportedType() throws {
        try withTemporaryDirectory("pkg-type") { dir in
            let notes = try write("hello", named: "notes.txt", in: dir.url)
            let manager = PackageManager(packagesDirectory: dir.url.appendingPathComponent("Packages"))
            expectThrows({ _ = try manager.import(from: notes) })
            expectEqual(manager.installedFiles().count, 0)
        }
    }

    static func testImportFolder() throws {
        try withTemporaryDirectory("pkg-folder") { dir in
            let incoming = dir.url.appendingPathComponent("incoming")
            try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
            _ = try write(validGrammar, named: "A.sublime-syntax", in: incoming)
            _ = try write(validGrammar.replacingOccurrences(of: "source.imported-test",
                                                           with: "source.imported-two")
                            .replacingOccurrences(of: "Imported Test", with: "Imported Two")
                            .replacingOccurrences(of: "itest", with: "itwo"),
                          named: "B.sublime-syntax", in: incoming)
            _ = try write("ignore me", named: "README.txt", in: incoming)

            let manager = PackageManager(packagesDirectory: dir.url.appendingPathComponent("Packages"))
            let report = try manager.import(from: incoming)
            expectEqual(report.installed.count, 2, "both grammars, the .txt ignored")
            expectEqual(manager.installedFiles().count, 2)
        }
    }

    static func testImportReplaces() throws {
        try withTemporaryDirectory("pkg-replace") { dir in
            let source = try write(validGrammar, named: "Test.sublime-syntax", in: dir.url)
            let manager = PackageManager(packagesDirectory: dir.url.appendingPathComponent("Packages"))

            _ = try manager.import(from: source)
            let second = try manager.import(from: source)
            expectTrue(second.installed.first?.replacedExisting ?? false)
            expectEqual(manager.installedFiles().count, 1, "no duplicate copies accumulate")
        }
    }

    /// A user grammar claiming a built-in scope must win, so a better Java definition
    /// can replace the bundled one.
    static func testImportOverridesBuiltIn() throws {
        try withTemporaryDirectory("pkg-override") { dir in
            let override = #"""
            %YAML 1.2
            ---
            name: Java (Custom)
            scope: source.java
            file_extensions: [java]
            contexts:
              main:
                - match: '\bmine\b'
                  scope: keyword.control.custom
            """#
            let packages = dir.url.appendingPathComponent("Packages")
            let source = try write(override, named: "JavaCustom.sublime-syntax", in: dir.url)
            let manager = PackageManager(packagesDirectory: packages)
            _ = try manager.import(from: source)

            let registry = GrammarRegistry()
            registry.reload(packagesDirectory: packages)
            expectEqual(registry.grammar(forScope: "source.java")?.name, "Java (Custom)")
        }
    }

    static func testImportEmptyFolder() throws {
        try withTemporaryDirectory("pkg-empty") { dir in
            let empty = dir.url.appendingPathComponent("empty")
            try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            let manager = PackageManager(packagesDirectory: dir.url.appendingPathComponent("Packages"))
            expectThrows({ _ = try manager.import(from: empty) })
        }
    }

    /// Regression: Reveal Packages Folder → Import that same folder used to
    /// remove-then-copy a file onto itself, deleting the user's grammar.
    static func testImportFromPackagesFolder() throws {
        try withTemporaryDirectory("pkg-self") { dir in
            let packages = dir.url.appendingPathComponent("Packages")
            let manager = PackageManager(packagesDirectory: packages)
            let source = try write(validGrammar, named: "Test.sublime-syntax", in: dir.url)
            _ = try manager.import(from: source)
            expectEqual(manager.installedFiles().count, 1)

            // Import the Packages folder itself.
            let report = try manager.import(from: packages)
            expectEqual(report.installed.count, 1)
            expectEqual(report.rejected.count, 0)
            expectEqual(manager.installedFiles().count, 1, "the installed file must survive")

            // And the individual file, by its installed path.
            guard let installed = manager.installedFiles().first else {
                fail("nothing installed")
                return
            }
            _ = try manager.import(from: installed)
            expectEqual(manager.installedFiles().count, 1)
            expectTrue(FileManager.default.fileExists(atPath: installed.path))
        }
    }

    /// A user grammar with a fresh scope must be able to take over an extension a
    /// built-in already lists — otherwise imports only work by scope collision.
    static func testImportClaimsExtension() throws {
        try withTemporaryDirectory("pkg-claim") { dir in
            // XML claims .html among the built-ins; this grammar has its own scope.
            let html = #"""
            %YAML 1.2
            ---
            name: HTML (Imported)
            scope: text.html.imported
            file_extensions: [html, htm]
            contexts:
              main:
                - match: '<'
                  scope: punctuation.definition.tag.begin.html
            """#
            let packages = dir.url.appendingPathComponent("Packages")
            let manager = PackageManager(packagesDirectory: packages)
            _ = try manager.import(from: try write(html, named: "HTML.sublime-syntax", in: dir.url))

            let registry = GrammarRegistry()
            registry.reload(packagesDirectory: packages)
            expectEqual(registry.grammar(for: URL(fileURLWithPath: "/a/index.html")).scope.raw,
                        "text.html.imported",
                        "an imported grammar outranks a built-in for the same extension")
            // The built-in is still there for files it alone claims.
            expectEqual(registry.grammar(for: URL(fileURLWithPath: "/a/pom.xml")).scope.raw, "text.xml")
        }
    }

    /// `.bashrc` has no path extension, so it can only match by whole name — and the
    /// grammar lists "bashrc" without the dot.
    static func testDotfileDetection() {
        expectEqual(scope(of: "/home/me/.bashrc"), "source.shell")
        expectEqual(scope(of: "/home/me/.zshrc"), "source.shell")
        expectEqual(scope(of: "/p/.editorconfig"), "source.java-properties")
    }

    static func testRemoveGuard() throws {
        try withTemporaryDirectory("pkg-remove") { dir in
            let outsider = try write("x", named: "outside.sublime-syntax", in: dir.url)
            let manager = PackageManager(packagesDirectory: dir.url.appendingPathComponent("Packages"))
            expectThrows({ try manager.remove(outsider) },
                         "must refuse to delete outside the Packages folder")
            expectTrue(FileManager.default.fileExists(atPath: outsider.path))
        }
    }
}
