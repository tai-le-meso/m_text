import Foundation
import MTextCore
import MTextTestKit

/// Symbol extraction quality is entirely bounded by how precisely each grammar tags
/// `entity.name.*` — most of the 48 built-in grammars were written for coloring, not
/// symbol indexing, so many (including this project's own Swift/Python grammars) only
/// tag *type* names this way and don't distinguish function/variable declarations at
/// all. Java's `class`/`interface` declarations are one of the more precise cases (a
/// dedicated `type_name` context pushed right after the keyword), so it's used here as
/// a grammar known to produce an unambiguous, single symbol per declaration.
enum SymbolExtractorTests {

    static let suite = TestSuite("SymbolExtractor", [
        ("finds a Java class declaration as a symbol", testFindsJavaClassDeclaration),
        ("finds nothing in an empty document", testEmptyDocument),
        ("does not tag ordinary keywords as symbols", testIgnoresKeywords),
    ])

    private static func javaGrammar() -> Grammar {
        BuiltInGrammars.registry().grammar(named: "Java") ?? .plainText()
    }

    static func testFindsJavaClassDeclaration() {
        let document = TextDocument(text: "public class Foo {\n    void bar() {}\n}\n")
        let symbols = SymbolExtractor.extractSymbols(from: document, grammar: javaGrammar())
        expectTrue(symbols.contains { $0.name == "Foo" && $0.line == 0 },
                  "expected a 'Foo' symbol on line 0, got \(symbols)")
    }

    static func testEmptyDocument() {
        let document = TextDocument(text: "")
        let symbols = SymbolExtractor.extractSymbols(from: document, grammar: javaGrammar())
        expectEqual(symbols.count, 0)
    }

    static func testIgnoresKeywords() {
        let document = TextDocument(text: "if (true) { return; }\n")
        let symbols = SymbolExtractor.extractSymbols(from: document, grammar: javaGrammar())
        expectFalse(symbols.contains { $0.name == "if" || $0.name == "return" || $0.name == "true" })
    }
}
