import Foundation
import MTextCore
import MTextTestKit

enum SnippetTests {

    static let suite = TestSuite("Snippet", [
        ("plain text passes through untouched", testLiteral),
        ("parses a bare $1 stop", testBareStop),
        ("parses a ${1:placeholder} stop", testPlaceholderStop),
        ("parses nested placeholders", testNestedPlaceholder),
        ("treats an unbalanced ${ as literal text", testUnbalancedBrace),
        ("honours \\$ and \\\\ escapes", testEscapes),
        ("leaves a lone $ that starts nothing as text", testLoneDollar),

        ("expands placeholders and records their ranges", testExpandRanges),
        ("mirrors a repeated stop to the placeholder's text", testMirrors),
        ("orders stops 1,2,… with $0 last", testStopOrdering),
        ("synthesizes a final stop when $0 is absent", testSynthesizedFinalStop),
        ("keeps an explicit $0 where it was written", testExplicitFinalStop),

        ("substitutes $SELECTION and TM_ variables", testVariables),
        ("falls back to ${VAR:default} when the variable is empty", testVariableDefault),
        ("falls back for an unknown variable rather than emitting nothing", testUnknownVariable),

        ("parses a .sublime-snippet file", testParseSnippetFile),
        ("rejects a snippet with no content", testParseNoContent),
        ("rejects malformed XML", testParseMalformed),
        ("picks a trigger's snippet by scope specificity", testTriggerScopeMatching),
        ("ignores a trigger whose scope does not match", testTriggerScopeMismatch),

        ("session converts character offsets to byte offsets", testSessionByteOffsets),
        ("session declines a snippet with nothing to fill in", testSessionDeclinesLiteral),
        ("Tab walks the stops and then finishes", testSessionAdvance),
        ("Shift-Tab goes back but never past the first stop", testSessionRetreat),
        ("typing inside a stop grows it and shifts later stops", testSessionRebaseInside),
        ("an edit before the snippet shifts everything", testSessionRebaseBefore),
        ("an edit straddling a stop boundary ends the session", testSessionRebaseStraddle),
        ("mirror edits are ordered back to front", testSessionMirrorEdits),
        ("mirror ranges are updated to the new text length", testSessionMirrorRebase),
        ("byte offsets stay correct with multi-byte characters", testSessionMultiByte),

        ("every built-in snippet expands to something usable", testBuiltInSnippets),
        ("built-in triggers resolve, and a user snippet can replace one", testBuiltInOverride),
    ])

    // MARK: - Body parsing

    static func testLiteral() {
        expectEqual(SnippetBodyParser.parse("hello"), [.literal("hello")])
    }

    static func testBareStop() {
        expectEqual(SnippetBodyParser.parse("a$1b"),
                    [.literal("a"), .stop(index: 1, children: []), .literal("b")])
    }

    static func testPlaceholderStop() {
        expectEqual(SnippetBodyParser.parse("${1:name}"),
                    [.stop(index: 1, children: [.literal("name")])])
    }

    static func testNestedPlaceholder() {
        expectEqual(SnippetBodyParser.parse("${1:${2:inner}}"),
                    [.stop(index: 1, children: [.stop(index: 2, children: [.literal("inner")])])])
    }

    /// A stray `${` in real code (shell, template strings) must not swallow the rest of
    /// the body.
    static func testUnbalancedBrace() {
        expectEqual(SnippetBodyParser.parse("${1:oops"), [.literal("${1:oops")])
    }

    static func testEscapes() {
        expectEqual(SnippetBodyParser.parse(#"\$1 \\ \$"#), [.literal(#"$1 \ $"#)])
    }

    static func testLoneDollar() {
        expectEqual(SnippetBodyParser.parse("cost: $"), [.literal("cost: $")])
    }

    // MARK: - Expansion

    static func testExpandRanges() {
        let expansion = SnippetRenderer.expand("for ${1:item} in ${2:seq}:")
        expectEqual(expansion.text, "for item in seq:")
        expectEqual(expansion.stops.first?.index, 1)
        expectEqual(expansion.stops.first?.primaryRange, 4 ..< 8, "\"item\"")
        expectEqual(expansion.stops[1].primaryRange, 12 ..< 15, "\"seq\"")
    }

    /// The point of mirrors: `${1:name}` defines the text, and every later `$1` repeats it.
    static func testMirrors() {
        let expansion = SnippetRenderer.expand("${1:x} = $1 + $1")
        expectEqual(expansion.text, "x = x + x")
        let first = expansion.stops.first
        expectEqual(first?.index, 1)
        expectEqual(first?.ranges.count, 3, "one primary plus two mirrors")
        expectEqual(first?.ranges, [0 ..< 1, 4 ..< 5, 8 ..< 9])
        expectEqual(first?.placeholder, "x")
    }

    /// `$0` is the exit stop, so it must sort *after* the numbered ones — a plain numeric
    /// sort would put it first and Tab would jump to the end immediately.
    static func testStopOrdering() {
        let expansion = SnippetRenderer.expand("$0 ${2:b} ${1:a}")
        expectEqual(expansion.stops.map(\.index), [1, 2, 0])
    }

    static func testSynthesizedFinalStop() {
        let expansion = SnippetRenderer.expand("${1:a}")
        expectEqual(expansion.stops.map(\.index), [1, 0])
        expectEqual(expansion.stops.last?.primaryRange, 1 ..< 1, "at the very end")
    }

    static func testExplicitFinalStop() {
        let expansion = SnippetRenderer.expand("if ${1:cond} {\n\t$0\n}")
        expectEqual(expansion.stops.map(\.index), [1, 0])
        let zero = expansion.stops.last!
        expectEqual(String(Array(expansion.text)[zero.primaryRange.lowerBound...].prefix(2)), "\n}")
    }

    // MARK: - Variables

    static func testVariables() {
        var context = SnippetContext()
        context.selection = "chosen"
        context.fileName = "Main.swift"
        context.lineNumber = 42
        let expansion = SnippetRenderer.expand("$SELECTION|$TM_FILENAME|$TM_LINE_NUMBER",
                                               context: context)
        expectEqual(expansion.text, "chosen|Main.swift|42")
    }

    /// The common real case: wrapping a selection, but with sensible text when there
    /// isn't one.
    static func testVariableDefault() {
        let expansion = SnippetRenderer.expand("(${SELECTION:body})", context: SnippetContext())
        expectEqual(expansion.text, "(body)")
    }

    static func testUnknownVariable() {
        let expansion = SnippetRenderer.expand("${NOPE:fallback}", context: SnippetContext())
        expectEqual(expansion.text, "fallback")
    }

    // MARK: - File parsing

    private static let sampleXML = """
    <snippet>
      <content><![CDATA[for ${1:item} in ${2:seq}:
    \t$0]]></content>
      <tabTrigger>for</tabTrigger>
      <scope>source.python</scope>
      <description>for loop</description>
    </snippet>
    """

    static func testParseSnippetFile() {
        guard let snippet = try? SnippetParser.parse(data: Data(sampleXML.utf8), name: "for") else {
            expectTrue(false, "well-formed snippet should parse")
            return
        }
        expectEqual(snippet.tabTrigger, "for")
        expectEqual(snippet.scope, "source.python")
        expectEqual(snippet.description, "for loop")
        expectTrue(snippet.content.hasPrefix("for ${1:item}"))
        // CDATA must survive intact — it's the whole reason snippet bodies use it.
        expectTrue(snippet.content.contains("$0"))
    }

    static func testParseNoContent() {
        let xml = "<snippet><tabTrigger>x</tabTrigger></snippet>"
        expectThrows { _ = try SnippetParser.parse(data: Data(xml.utf8), name: "x") }
    }

    static func testParseMalformed() {
        expectThrows { _ = try SnippetParser.parse(data: Data("<snippet>".utf8), name: "x") }
    }

    // MARK: - Trigger lookup

    private static func store(_ snippets: [Snippet]) -> SnippetStore {
        // Empty directory: the store is exercised through its parsed list, not the disk.
        let store = SnippetStore(directories: [])
        store.replaceForTesting(snippets)
        return store
    }

    static func testTriggerScopeMatching() {
        let generic = Snippet(content: "generic", tabTrigger: "for", scope: nil, name: "g")
        let python = Snippet(content: "python", tabTrigger: "for", scope: "source.python", name: "p")
        let found = store([generic, python]).snippet(forTrigger: "for", scope: "source.python")
        expectEqual(found?.content, "python", "the language-specific snippet shadows the generic one")

        let elsewhere = store([generic, python]).snippet(forTrigger: "for", scope: "source.swift")
        expectEqual(elsewhere?.content, "generic", "and the generic one still applies elsewhere")
    }

    static func testTriggerScopeMismatch() {
        let python = Snippet(content: "python", tabTrigger: "for", scope: "source.python", name: "p")
        expectNil(store([python]).snippet(forTrigger: "for", scope: "source.swift"))
        expectNil(store([python]).snippet(forTrigger: "nope", scope: "source.python"))
    }

    // MARK: - Session

    private static func session(_ body: String, origin: Int = 0) -> SnippetSession? {
        SnippetSession(expansion: SnippetRenderer.expand(body), originByteOffset: origin)
    }

    static func testSessionByteOffsets() {
        // "for item in seq:" with origin 100 — stop 1 covers "item" at 4..<8.
        guard let session = session("for ${1:item} in ${2:seq}:", origin: 100) else {
            expectTrue(false, "session should start"); return
        }
        expectEqual(session.currentStop?.index, 1)
        expectEqual(session.currentStop?.primary, 104 ..< 108)
    }

    /// A body with no placeholders is just an insertion; tracking a session for it would
    /// put the editor into snippet mode with nowhere to Tab.
    static func testSessionDeclinesLiteral() {
        expectNil(session("plain text"))
        expectNil(session("trailing stop only $0"))
    }

    static func testSessionAdvance() {
        guard let session = session("${1:a} ${2:b}") else { expectTrue(false); return }
        expectEqual(session.currentStop?.index, 1)
        expectEqual(session.advance()?.index, 2)
        expectEqual(session.advance()?.index, 0, "the synthesized final stop")
        expectNil(session.advance(), "and then it is done")
        expectTrue(session.isFinished)
    }

    static func testSessionRetreat() {
        guard let session = session("${1:a} ${2:b}") else { expectTrue(false); return }
        session.advance()
        expectEqual(session.retreat()?.index, 1)
        expectEqual(session.retreat()?.index, 1, "stays put rather than throwing the snippet away")
        expectFalse(session.isFinished)
    }

    /// Typing "xy" into stop 1 (2 bytes replacing the 1-byte "a") must grow stop 1 and
    /// push stop 2 along by the same amount.
    static func testSessionRebaseInside() {
        guard let session = session("${1:a} ${2:b}") else { expectTrue(false); return }
        expectEqual(session.stops[0].primary, 0 ..< 1)
        expectEqual(session.stops[1].primary, 2 ..< 3)

        expectTrue(session.rebase(replaced: 0 ..< 1, newByteLength: 2))
        expectEqual(session.stops[0].primary, 0 ..< 2, "the edited stop grows")
        expectEqual(session.stops[1].primary, 3 ..< 4, "and later stops shift")
    }

    static func testSessionRebaseBefore() {
        guard let session = session("${1:a}", origin: 10) else { expectTrue(false); return }
        expectEqual(session.stops[0].primary, 10 ..< 11)
        expectTrue(session.rebase(replaced: 0 ..< 0, newByteLength: 5))
        expectEqual(session.stops[0].primary, 15 ..< 16)
    }

    /// Selecting across a placeholder's edge and replacing leaves no coherent answer for
    /// where that stop starts and ends, so the session has to give up rather than track
    /// ranges it can't trust.
    static func testSessionRebaseStraddle() {
        guard let session = session("${1:abc} ${2:d}") else { expectTrue(false); return }
        expectFalse(session.rebase(replaced: 1 ..< 5, newByteLength: 1))
        expectTrue(session.isFinished)
    }

    static func testSessionMirrorEdits() {
        // "x = x + x" — stop 1 at 0..<1 with mirrors at 4..<5 and 8..<9.
        guard let session = session("${1:x} = $1 + $1") else { expectTrue(false); return }
        expectEqual(session.currentStop?.ranges.count, 3)

        let edits = session.mirrorEdits(activeText: "value")
        expectEqual(edits.count, 2, "the primary is not rewritten — it is what was typed")
        expectTrue(edits[0].range.lowerBound > edits[1].range.lowerBound,
                   "back to front, so applying one doesn't invalidate the next")
        expectEqual(edits.map(\.replacement), ["value", "value"])
    }

    static func testSessionMirrorRebase() {
        guard let session = session("${1:x} = $1") else { expectTrue(false); return }
        _ = session.mirrorEdits(activeText: "abcd")
        // The mirror was 1 byte at 4..<5; after being rewritten to 4 bytes it is 4..<8.
        expectEqual(session.stops[0].ranges[1], 4 ..< 8)
    }

    /// Byte offsets, not character offsets: a multi-byte character before a stop shifts it
    /// by more than one.
    static func testSessionMultiByte() {
        guard let session = session("é${1:a}") else { expectTrue(false); return }
        expectEqual(session.currentStop?.primary, 2 ..< 3, "é is 2 UTF-8 bytes")
    }

    // MARK: - Built-ins

    /// A bundled snippet that doesn't parse is breakage shipped to every user, and one
    /// with no stops silently drops out of tab-stop navigation — both worth catching here
    /// rather than in a bug report.
    static func testBuiltInSnippets() {
        expectFalse(BuiltInSnippets.all.isEmpty)
        for snippet in BuiltInSnippets.all {
            let expansion = SnippetRenderer.expand(snippet.content)
            expectFalse(expansion.text.isEmpty, "\(snippet.name) expands to nothing")
            expectFalse(expansion.stops.isEmpty, "\(snippet.name) has no stops")
            expectTrue(expansion.stops.contains { $0.index == 0 },
                       "\(snippet.name) must end somewhere")
            expectTrue(snippet.tabTrigger?.isEmpty == false, "\(snippet.name) has no trigger")
            // Markers left in the output mean the body parser didn't understand them.
            expectFalse(expansion.text.contains("${"), "\(snippet.name) left a raw marker")
        }
    }

    static func testBuiltInOverride() {
        let store = SnippetStore(directories: [])
        expectEqual(store.snippet(forTrigger: "for", scope: "source.python")?.name, "for-python")
        expectNil(store.snippet(forTrigger: "definitely-not-a-trigger", scope: nil))

        // A user file with the same trigger and scope must win — built-ins load first
        // precisely so later entries can replace them.
        var replaced = BuiltInSnippets.all
        replaced.append(Snippet(content: "mine", tabTrigger: "for",
                                scope: "source.python", name: "user-for"))
        store.replaceForTesting(replaced)
        expectEqual(store.snippet(forTrigger: "for", scope: "source.python")?.name, "user-for")
    }
}
