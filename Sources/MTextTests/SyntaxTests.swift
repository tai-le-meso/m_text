import Foundation
import MTextCore
import MTextTestKit

enum SyntaxTests {

    static let suite = TestSuite("Syntax", [
        ("scope descendant matching", testScopeDescendant),
        ("selector matches and scores", testSelectorScoring),
        ("selector specificity survives deep stacks", testSpecificityBeatsDepth),
        ("selector exclusions", testSelectorExclusions),
        ("YAML skips directives and comments", testYAMLSkipsDirectives),
        ("YAML parses a syntax definition", testYAMLSyntaxShape),
        ("YAML handles CRLF", testYAMLCRLF),
        ("CRLF survives the loader and decoder", testCRLFHandlingAcrossLoaders),
        ("YAML flow sequences and block scalars", testYAMLFlowAndBlock),
        ("regex shim translates Oniguruma", testRegexTranslate),
        ("regex sees text before the scan position", testRegexTransparentBounds),
        ("loader builds contexts and variables", testLoaderContexts),
        ("loader flattens includes", testLoaderIncludes),
        ("tokenizer scopes a simple line", testTokenizeSimple),
        ("tokenizer carries state across lines", testTokenizeMultiline),
        ("tokenizer applies capture scopes", testTokenizeCaptures),
        ("meta_scope covers both delimiters", testMetaScopeDelimiters),
        ("clear_scopes is restored on pop", testClearScopesRestored),
        ("incremental result equals full rehighlight", testIncrementalMatchesFull),
        ("edit only redoes affected lines", testIncrementalConverges),
        ("colour parsing", testColorParsing),
        ("JSONC strips comments and trailing commas", testJSONC),
        ("colour scheme resolves by specificity", testSchemeResolution),
        ("built-in grammars all load", testBuiltInGrammarsLoad),
        ("registry picks grammar by extension and shebang", testRegistryDetection),
        ("new grammar batch detects by extension incl. .h ambiguity", testNewGrammarsDetection),
        ("batch 2 grammars detect by extension and filename", testBatch2GrammarsDetection),
        ("batch 3 grammars detect by extension incl. .m ambiguity", testBatch3GrammarsDetection),
        ("content sniffer detects common languages", testContentSnifferDetectsCommonLanguages),
        ("content sniffer declines short or ambiguous text", testContentSnifferDeclinesShortOrAmbiguousText),
        ("bracket matching ignores strings", testBracketMatching),
    ])

    // MARK: - Scopes

    static func testScopeDescendant() {
        let keyword = ScopeName("keyword.control.flow")
        expectTrue(keyword.isDescendant(of: ScopeName("keyword")))
        expectTrue(keyword.isDescendant(of: ScopeName("keyword.control")))
        expectTrue(keyword.isDescendant(of: keyword))
        expectFalse(keyword.isDescendant(of: ScopeName("keywords")))
        expectFalse(ScopeName("keyword").isDescendant(of: keyword))
    }

    static func testSelectorScoring() {
        let stack = ScopeStack(["source.swift", "string.quoted.double.swift"])
        expectTrue(ScopeSelector("string").matches(stack))
        expectTrue(ScopeSelector("string.quoted").matches(stack))
        expectTrue(ScopeSelector("source.swift string").matches(stack))
        expectFalse(ScopeSelector("comment").matches(stack))

        let vague = ScopeSelector("string").score(against: stack) ?? 0
        let specific = ScopeSelector("string.quoted.double").score(against: stack) ?? 0
        expectTrue(specific > vague, "a longer selector must outrank a shorter one")
    }

    /// Regression: depth must not be able to outweigh specificity once a scope stack
    /// grows past the multiplier.
    static func testSpecificityBeatsDepth() {
        var names = ["source.html"]
        for i in 0 ..< 20 { names.append("meta.level\(i)") }
        names.append("string.quoted.double")
        let deep = ScopeStack(names)

        let vague = ScopeSelector("string").score(against: deep) ?? 0
        let specific = ScopeSelector("string.quoted").score(against: deep) ?? 0
        expectTrue(specific > vague, "specificity must dominate stack depth")
    }

    static func testSelectorExclusions() {
        let inComment = ScopeStack(["source.c", "comment.line", "meta.toc-list"])
        let plain = ScopeStack(["source.c", "meta.toc-list"])

        expectFalse(ScopeSelector("meta.toc-list -comment").matches(inComment))
        expectTrue(ScopeSelector("meta.toc-list -comment").matches(plain))
        // A space-separated `-` is also valid exclusion syntax.
        expectFalse(ScopeSelector("meta.toc-list - comment").matches(inComment))
        expectTrue(ScopeSelector("meta.toc-list - comment").matches(plain))
    }

    // MARK: - YAML

    private static let sampleSyntax = """
    %YAML 1.2
    ---
    # a comment
    name: Test
    scope: source.test
    file_extensions: [test, tst]
    variables:
      ident: '[A-Za-z_][A-Za-z_0-9]*'
    contexts:
      main:
        - match: '"'
          scope: punctuation.definition.string.begin
          push: string
        - match: '\\b(if|else)\\b'
          scope: keyword.control
        - include: numbers
      numbers:
        - match: '\\d+'
          scope: constant.numeric
      string:
        - meta_scope: string.quoted.double
        - match: '\\\\.'
          scope: constant.character.escape
        - match: '"'
          pop: true
    """

    static func testYAMLSkipsDirectives() {
        // A %YAML directive on line 1 must not be read as a mapping key.
        expectNoThrow({ _ = try YAML.parse(sampleSyntax) },
                      "the %YAML directive must be skipped")
    }

    static func testYAMLSyntaxShape() {
        guard let root = try? YAML.parse(sampleSyntax) else {
            fail("parse threw")
            return
        }
        expectEqual(root["name"]?.stringValue, "Test")
        expectEqual(root["scope"]?.stringValue, "source.test")
        expectEqual(root["file_extensions"]?.listValue?.count, 2)
        expectEqual(root["file_extensions"]?.listValue?.first?.stringValue, "test")
        expectEqual(root["variables"]?["ident"]?.stringValue, "[A-Za-z_][A-Za-z_0-9]*")

        let main = root["contexts"]?["main"]?.listValue
        expectEqual(main?.count, 3)
        expectEqual(main?[0]["match"]?.stringValue, "\"")
        expectEqual(main?[0]["push"]?.stringValue, "string")
        expectEqual(main?[1]["scope"]?.stringValue, "keyword.control")
        expectEqual(main?[2]["include"]?.stringValue, "numbers")

        let string = root["contexts"]?["string"]?.listValue
        expectEqual(string?[0]["meta_scope"]?.stringValue, "string.quoted.double")
        expectEqual(string?[2]["pop"]?.stringValue, "true")
    }

    static func testYAMLCRLF() {
        let crlf = sampleSyntax.replacingOccurrences(of: "\n", with: "\r\n")

        // Guard the trap that caused this: "\r\n" is a single Character, so a
        // substring search for "\r" does not find it and a `contains("\r")`-gated
        // normalisation is silently skipped.
        expectFalse(crlf.contains("\r"), "Swift reports no \\r inside a CRLF cluster")
        expectTrue(crlf.utf8.contains(0x0D), "…but the byte is certainly there")

        guard let root = try? YAML.parse(crlf) else {
            fail("CRLF parse threw")
            return
        }
        expectEqual(root["scope"]?.stringValue, "source.test",
                    "a trailing CR must not survive into scope names")
        // The real breakage was valueless keys: `contexts:` followed by CR failed
        // splitKey's "colon then space or end of line" rule.
        expectTrue(root["contexts"]?["main"]?.listValue != nil,
                   "a key with no inline value must still open a block under CRLF")
        expectEqual(root["contexts"]?["numbers"]?.listValue?.first?["scope"]?.stringValue,
                    "constant.numeric")
    }

    /// The same grapheme trap, on the paths that read real files.
    static func testCRLFHandlingAcrossLoaders() {
        let crlf = sampleSyntax.replacingOccurrences(of: "\n", with: "\r\n")
        var loader = SublimeSyntaxLoader()
        guard let grammar = try? loader.parse(crlf) else {
            fail("loader threw on a CRLF syntax file")
            return
        }
        expectEqual(grammar.scope.raw, "source.test")
        expectTrue(grammar.context(named: "main") != nil)

        // Document decoding must normalise to LF and report the original convention.
        let decoded = TextEncodingDetector.decode(Array("a\r\nb\r\n".utf8), encoding: .utf8)
        expectEqual(decoded.text, "a\nb\n")
        expectEqual(decoded.lineEnding, .crlf)
    }

    static func testYAMLFlowAndBlock() {
        let text = """
        list: [a, 'b c', d]
        block: |
          line one
          line two
        after: yes
        """
        guard let root = try? YAML.parse(text) else {
            fail("parse threw")
            return
        }
        expectEqual(root["list"]?.listValue?.count, 3)
        expectEqual(root["list"]?.listValue?[1].stringValue, "b c")
        expectEqual(root["block"]?.stringValue, "line one\nline two")
        expectEqual(root["after"]?.stringValue, "yes")
    }

    // MARK: - Regex shim

    static func testRegexTranslate() {
        expectEqual(RegexShim.translate("\\h+"), "[0-9a-fA-F]+")
        expectEqual(RegexShim.translate("[[:alpha:]]+"), "[\\p{Alpha}]+")
        expectEqual(RegexShim.translate("\\G\\d"), "\\d", "\\G has no ICU equivalent")
        // Untouched constructs must pass through unchanged.
        expectEqual(RegexShim.translate("(?<name>\\w+)\\s*"), "(?<name>\\w+)\\s*")

        expectNoThrow({
            _ = try RegexShim.compile("\\h{4}")
            _ = try RegexShim.compile("[[:digit:]]")
            _ = try RegexShim.compile("\\b(?:if|else)\\b")
        })
    }

    /// Regression: without transparent bounds, ICU treats the scan position as the
    /// start of input, so `\bif\b` would match inside "abcif".
    static func testRegexTransparentBounds() {
        guard let regex = try? RegexShim.compile("\\bif\\b") else {
            fail("compile threw")
            return
        }
        expectNil(regex.firstMatch(in: "abcif", from: 3),
                  "\\b must see the 'c' before the scan position")
        expectTrue(regex.firstMatch(in: "abc if", from: 3) != nil)
        // ^ must still be tied to the real line start, not the scan position.
        guard let anchored = try? RegexShim.compile("^x") else {
            fail("compile threw")
            return
        }
        expectNil(anchored.firstMatch(in: "ax", from: 1))
    }

    // MARK: - Loader

    private static func loadSample() -> Grammar? {
        var loader = SublimeSyntaxLoader()
        return try? loader.parse(sampleSyntax)
    }

    static func testLoaderContexts() {
        guard let grammar = loadSample() else {
            fail("loader threw")
            return
        }
        expectEqual(grammar.name, "Test")
        expectEqual(grammar.scope.raw, "source.test")
        expectEqual(grammar.fileExtensions, ["test", "tst"])
        expectTrue(grammar.context(named: "main") != nil)
        expectTrue(grammar.context(named: "string") != nil)
        expectEqual(grammar.context(named: "string")?.metaScope.first?.raw, "string.quoted.double")
    }

    static func testLoaderIncludes() {
        guard let grammar = loadSample(), let main = grammar.context(named: "main") else {
            fail("loader threw")
            return
        }
        // `- include: numbers` must be replaced by that context's pattern, and no
        // placeholder may survive into the tokenizer.
        expectFalse(main.patterns.contains { $0.isIncludePlaceholder })
        expectEqual(main.patterns.count, 3)
        expectEqual(main.patterns[2].scopes.first?.raw, "constant.numeric")
    }

    // MARK: - Tokenizer

    private static func tokenize(_ line: String, grammar: Grammar,
                                 state: TokenizerState? = nil) -> (spans: [ScopeSpan], state: TokenizerState) {
        Tokenizer(grammar: grammar).tokenize(line: line, state: state ?? .initial(for: grammar))
    }

    static func testTokenizeSimple() {
        guard let grammar = loadSample() else {
            fail("loader threw")
            return
        }
        let result = tokenize("if 42", grammar: grammar)
        // "if" keyword, " " plain, "42" numeric.
        expectEqual(result.spans.count, 3)
        expectEqual(result.spans[0].scopes.innermost?.raw, "keyword.control")
        expectEqual(result.spans[1].scopes.innermost?.raw, "source.test")
        expectEqual(result.spans[2].scopes.innermost?.raw, "constant.numeric")
        expectEqual(result.spans[2].start, 3)
        expectEqual(result.spans[2].end, 5)
    }

    static func testTokenizeMultiline() {
        guard let grammar = loadSample() else {
            fail("loader threw")
            return
        }
        // An unterminated string must leave the tokenizer inside the string context.
        let first = tokenize("\"abc", grammar: grammar)
        expectEqual(first.state.contextNames.last, "string")

        let second = tokenize("still string\"", grammar: grammar, state: first.state)
        expectTrue(second.spans.allSatisfy {
            $0.scopes.scopes.contains { $0.raw == "string.quoted.double" }
        }, "the whole continuation line is inside the string")
        expectEqual(second.state.contextNames.last, "main", "the closing quote pops back")
    }

    static func testTokenizeCaptures() {
        let source = """
        %YAML 1.2
        ---
        name: Captures
        scope: source.cap
        contexts:
          main:
            - match: '(foo)=(bar)'
              scope: meta.pair
              captures:
                1: variable.other
                2: constant.other
        """
        var loader = SublimeSyntaxLoader()
        guard let grammar = try? loader.parse(source) else {
            fail("loader threw")
            return
        }
        let result = tokenize("foo=bar", grammar: grammar)
        let scoped = result.spans.map { $0.scopes.innermost?.raw ?? "" }
        expectTrue(scoped.contains("variable.other"))
        expectTrue(scoped.contains("constant.other"))
        // The "=" between them keeps only the match scope.
        expectTrue(scoped.contains("meta.pair"))
    }

    /// Regression: meta_scope covers the delimiters, meta_content_scope does not.
    static func testMetaScopeDelimiters() {
        guard let grammar = loadSample() else {
            fail("loader threw")
            return
        }
        let result = tokenize("\"a\"", grammar: grammar)
        let first = result.spans.first
        let last = result.spans.last
        expectTrue(first?.scopes.scopes.contains { $0.raw == "string.quoted.double" } ?? false,
                   "the opening quote is inside meta_scope")
        expectTrue(last?.scopes.scopes.contains { $0.raw == "string.quoted.double" } ?? false,
                   "the closing quote is too")
    }

    /// Regression: a clear_scopes context must restore what it cleared when popped,
    /// or the root scope is lost for the rest of the file.
    static func testClearScopesRestored() {
        let source = """
        %YAML 1.2
        ---
        name: Clear
        scope: source.outer
        contexts:
          main:
            - match: '<'
              push: inner
            - match: 'x'
              scope: keyword.outer
          inner:
            - meta_scope: source.inner
            - clear_scopes: 1
            - match: '>'
              pop: true
        """
        var loader = SublimeSyntaxLoader()
        guard let grammar = try? loader.parse(source) else {
            fail("loader threw")
            return
        }
        let result = tokenize("<>x", grammar: grammar)
        expectTrue(result.state.scopes.scopes.contains { $0.raw == "source.outer" },
                   "the root scope must come back after the clear_scopes context pops")
        expectTrue(result.spans.last?.scopes.scopes.contains { $0.raw == "source.outer" } ?? false)
    }

    // MARK: - Incremental highlighting

    private static let program = """
    if 1
    "open string
    still inside
    " 2
    if 3
    """

    static func testIncrementalMatchesFull() {
        guard let grammar = loadSample() else {
            fail("loader threw")
            return
        }
        let document = TextDocument(text: program)
        let tree = document.snapshot()

        let incremental = Highlighter(grammar: grammar)
        // Walk forward one line at a time, as the view would.
        for line in 0 ..< tree.lineCount { _ = incremental.spans(forLine: line, in: tree) }

        // Now edit line 0 and re-ask, then compare with a fresh highlighter.
        _ = document.insert("x", at: Position(line: 0, column: 0))
        let edited = document.snapshot()
        incremental.invalidate(fromLine: 0)

        let fresh = Highlighter(grammar: grammar)
        for line in 0 ..< edited.lineCount {
            let a = incremental.spans(forLine: line, in: edited)
            let b = fresh.spans(forLine: line, in: edited)
            expectEqual(a.count, b.count, "span count differs on line \(line)")
            for index in 0 ..< min(a.count, b.count) {
                expectEqual(a[index].start, b[index].start, "line \(line) span \(index) start")
                expectEqual(a[index].end, b[index].end, "line \(line) span \(index) end")
                expectEqual(a[index].scopes, b[index].scopes, "line \(line) span \(index) scopes")
            }
        }
    }

    /// Regression: converging must mark the whole document clean, otherwise every
    /// keystroke re-tokenizes the rest of the file.
    static func testIncrementalConverges() {
        guard let grammar = loadSample() else {
            fail("loader threw")
            return
        }
        let document = TextDocument(text: program)
        let highlighter = Highlighter(grammar: grammar)
        highlighter.ensure(upToLine: document.lineCount - 1, in: document)
        expectFalse(highlighter.hasPendingWork)

        // An edit on the last line leaves earlier lines alone.
        let last = document.lineCount - 1
        _ = document.insert("y", at: Position(line: last, column: 0))
        highlighter.invalidate(fromLine: last)
        expectTrue(highlighter.hasPendingWork)
        highlighter.ensure(upToLine: last, in: document)
        expectFalse(highlighter.hasPendingWork, "the sweep must settle, not stay dirty")
    }

    // MARK: - Colours

    static func testColorParsing() {
        expectEqual(RGBAColor(css: "#f0a"), RGBAColor(css: "#ff00aa"))
        let translucent = RGBAColor(css: "#ff00aa80")
        expectTrue((translucent?.alpha ?? 0) > 0.49 && (translucent?.alpha ?? 0) < 0.51)
        expectEqual(RGBAColor(css: "rgb(255, 0, 170)"), RGBAColor(css: "#ff00aa"))

        let magenta = RGBAColor(css: "hsl(300, 100%, 50%)")
        expectTrue((magenta?.red ?? 0) > 0.99 && (magenta?.blue ?? 0) > 0.99 && (magenta?.green ?? 1) < 0.01)

        expectNil(RGBAColor(css: "#ff"))
        expectNil(RGBAColor(css: "not a colour"))
    }

    static func testJSONC() {
        let input = """
        {
          // line comment
          "a": 1, /* block */
          "b": "// not a comment",
          "c": [1, 2,],
        }
        """
        let cleaned = JSONC.stripComments(input)
        expectFalse(cleaned.contains("line comment"))
        expectFalse(cleaned.contains("block"))
        expectTrue(cleaned.contains("// not a comment"), "comments inside strings survive")

        expectNoThrow({
            let object = try JSONSerialization.jsonObject(with: Data(cleaned.utf8)) as? [String: Any]
            expectEqual(object?["a"] as? Int, 1)
            expectEqual((object?["c"] as? [Int])?.count, 2)
        }, "trailing commas must be removed")
    }

    static func testSchemeResolution() {
        let scheme = ColorScheme.builtInDefault()
        let comment = scheme.style(for: ScopeStack(["source.swift", "comment.line.double-slash"]))
        expectTrue(comment.foreground != nil)
        expectTrue(comment.fontStyle.italic)

        let keyword = scheme.style(for: ScopeStack(["source.swift", "keyword.control.swift"]))
        expectTrue(keyword.foreground != nil)
        expectFalse(keyword.foreground == comment.foreground)

        // Nothing matches: falls back to the global foreground (nil in the default).
        let unknown = scheme.style(for: ScopeStack(["source.swift", "nonsense.scope"]))
        expectNil(unknown.foreground)
    }

    // MARK: - Registry and built-ins

    static func testBuiltInGrammarsLoad() {
        for source in BuiltInGrammars.all {
            var loader = SublimeSyntaxLoader()
            do {
                let grammar = try loader.parse(source)
                expectTrue(grammar.context(named: "main") != nil,
                           "\(grammar.name) has no main context")
                expectTrue(loader.diagnostics.isEmpty,
                           "\(grammar.name) diagnostics: \(loader.diagnostics.messages)")
            } catch {
                fail("a built-in grammar failed to load: \(error)")
            }
        }
    }

    static func testRegistryDetection() {
        let registry = BuiltInGrammars.registry()
        expectEqual(registry.grammar(for: URL(fileURLWithPath: "/tmp/a.json")).scope.raw, "source.json")
        expectEqual(registry.grammar(for: URL(fileURLWithPath: "/tmp/a.swift")).scope.raw, "source.swift")
        expectEqual(registry.grammar(for: URL(fileURLWithPath: "/tmp/a.md")).scope.raw, "text.html.markdown")

        // Unknown extension, recognised shebang.
        let detected = registry.grammar(for: URL(fileURLWithPath: "/tmp/script"),
                                       firstLine: "#!/usr/bin/env python3")
        expectEqual(detected.scope.raw, "source.python")

        // Nothing matches at all.
        expectEqual(registry.grammar(for: URL(fileURLWithPath: "/tmp/a.unknownext")).scope.raw, "text.plain")
    }

    /// The batch of grammars added alongside content-based detection: SQL, Perl, Rust,
    /// Go, and the C family. `.h` is deliberately ambiguous between C/C++/Objective-C —
    /// this pins down that C wins it, per the ordering comment on `BuiltInGrammars.all`.
    static func testNewGrammarsDetection() {
        let registry = BuiltInGrammars.registry()
        let cases: [(String, String)] = [
            ("query.sql", "source.sql"),
            ("script.pl", "source.perl"),
            ("main.rs", "source.rust"),
            ("main.go", "source.go"),
            ("main.c", "source.c"),
            ("main.h", "source.c"),
            ("widget.cpp", "source.c++"),
            ("widget.hpp", "source.c++"),
            ("Program.cs", "source.cs"),
            ("AppDelegate.m", "source.objc"),
            ("index.php", "source.php"),
            ("app.rb", "source.ruby"),
        ]
        for (name, scope) in cases {
            expectEqual(registry.grammar(for: URL(fileURLWithPath: "/tmp/\(name)")).scope.raw, scope,
                       "\(name) should detect as \(scope)")
        }
    }

    /// T113 (batch 2): Lua, Makefile, Diff, TOML, R, Haskell, Scala, Clojure. Makefile
    /// matches by bare filename, not extension, so `Makefile` (no extension) has to
    /// resolve the same as `build.mk`.
    static func testBatch2GrammarsDetection() {
        let registry = BuiltInGrammars.registry()
        let cases: [(String, String)] = [
            ("init.lua", "source.lua"),
            ("build.mk", "source.makefile"),
            ("Makefile", "source.makefile"),
            ("change.diff", "source.diff"),
            ("fix.patch", "source.diff"),
            ("Cargo.toml", "source.toml"),
            ("plot.r", "source.r"),
            ("plot.R", "source.r"),
            ("Main.hs", "source.haskell"),
            ("App.scala", "source.scala"),
            ("core.clj", "source.clojure"),
        ]
        for (name, scope) in cases {
            expectEqual(registry.grammar(for: URL(fileURLWithPath: "/tmp/\(name)")).scope.raw, scope,
                       "\(name) should detect as \(scope)")
        }
    }

    /// T114 (batch 3, the long tail). `.m` is deliberately ambiguous between
    /// Objective-C and MATLAB — this pins down that Objective-C wins it, per the
    /// ordering comment on `BuiltInGrammars.all` (same pattern as `.h` in batch 1).
    static func testBatch3GrammarsDetection() {
        let registry = BuiltInGrammars.registry()
        let cases: [(String, String)] = [
            ("page.asp", "text.asp"),
            ("Main.as", "source.actionscript.3"),
            ("script.applescript", "source.applescript"),
            ("build.bat", "source.batchfile"),
            ("main.d", "source.d"),
            ("server.erl", "source.erlang"),
            ("graph.dot", "source.dot"),
            ("build.gradle", "source.groovy"),
            ("paper.tex", "text.tex.latex"),
            ("util.lisp", "source.lisp"),
            ("script.m", "source.objc"),
            ("main.ml", "source.ocaml"),
            ("unit1.pas", "source.pascal"),
            ("index.html.erb", "text.html.ruby"),
            ("pattern.regexp", "source.regexp"),
            ("readme.rst", "text.restructuredtext"),
            ("script.tcl", "source.tcl"),
            ("readme.textile", "text.html.textile"),
        ]
        for (name, scope) in cases {
            expectEqual(registry.grammar(for: URL(fileURLWithPath: "/tmp/\(name)")).scope.raw, scope,
                       "\(name) should detect as \(scope)")
        }
    }

    // MARK: - Content sniffing

    static func testContentSnifferDetectsCommonLanguages() {
        let samples: [(String, String)] = [
            ("SELECT id, name FROM users WHERE active = 1;", "source.sql"),
            ("fn main() {\n    let mut count = 0;\n    println!(\"{}\", count);\n}\n", "source.rust"),
            ("package main\n\nimport \"fmt\"\n\nfunc main() {\n\tfmt.Println(\"hi\")\n}\n", "source.go"),
            ("use strict;\nmy $name = \"world\";\nsub greet {\n    print \"hi\";\n}\n", "source.perl"),
            ("def main():\n    if __name__ == \"__main__\":\n        print(\"hi\")\n", "source.python"),
            ("public class Main {\n    public static void main(String[] args) {\n        System.out.println(\"hi\");\n    }\n}\n", "source.java"),
            ("#include <stdio.h>\nint main(void) {\n    printf(\"hi\\n\");\n    return 0;\n}\n", "source.c"),
            ("#include <iostream>\nint main() {\n    std::cout << \"hi\" << std::endl;\n}\n", "source.c++"),
            ("using System;\nnamespace App {\n    class Program {\n        static void Main() { Console.WriteLine(\"hi\"); }\n    }\n}\n", "source.cs"),
            ("<?php\n$name = \"world\";\necho $name;\n", "source.php"),
            ("require 'set'\nattr_accessor :name\ndef greet\n  puts \"hi\"\nend\n", "source.ruby"),
        ]
        for (text, expectedScope) in samples {
            expectEqual(ContentSniffer.detect(text), expectedScope, "sample: \(text.prefix(30))…")
        }
    }

    static func testContentSnifferDeclinesShortOrAmbiguousText() {
        expectNil(ContentSniffer.detect(""))
        expectNil(ContentSniffer.detect("   \n\n  "))
        expectNil(ContentSniffer.detect("hello world, this is just a note to self"))
        // A single stray keyword shared by many languages should not be enough to guess.
        expectNil(ContentSniffer.detect("return value"))
    }

    // MARK: - Brackets

    static func testBracketMatching() {
        let document = TextDocument(text: "foo(bar(baz))")
        let matcher = BracketMatcher(document: document)

        // Caret just before the outer "(" pairs with the final ")".
        let outer = matcher.match(at: Position(line: 0, column: 3))
        expectEqual(outer?.open, Position(line: 0, column: 3))
        expectEqual(outer?.close, Position(line: 0, column: 12))

        let inner = matcher.match(at: Position(line: 0, column: 7))
        expectEqual(inner?.open, Position(line: 0, column: 7))
        expectEqual(inner?.close, Position(line: 0, column: 11))

        // Unbalanced.
        let broken = BracketMatcher(document: TextDocument(text: "if (x {"))
        let result = broken.match(at: Position(line: 0, column: 3))
        expectTrue(result?.isUnbalanced ?? false)

        // A brace inside a "string" is skipped when the probe says so.
        let stringy = TextDocument(text: "a(\")\")")
        let ignoring = BracketMatcher(document: stringy) { position in
            position.column >= 2 && position.column <= 4 // stand in for string scopes
        }
        expectEqual(ignoring.match(at: Position(line: 0, column: 1))?.close,
                    Position(line: 0, column: 5),
                    "the ')' inside the string must not pair")
    }
}
