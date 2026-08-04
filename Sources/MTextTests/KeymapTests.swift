import Foundation
import MTextCore
import MTextTestKit

enum KeymapTests {

    static let suite = TestSuite("Keymap", [
        ("parses a plain key with no modifiers", testParsePlainKey),
        ("parses stacked modifiers in any written order", testParseModifiers),
        ("accepts \"super\" as an alias for cmd", testParseSuperAlias),
        ("rejects an unrecognised modifier name", testParseUnknownModifier),
        ("parses a well-formed keymap array", testParseKeymapArray),
        ("skips a malformed entry without failing the whole file", testSkipsMalformedEntry),
        ("strips line comments outside strings", testStripLineComments),
        ("keeps a // that appears inside a string value", testStripLineCommentsInsideString),
        ("throws for a top-level object instead of an array", testThrowsForNonArray),
    ])

    static func testParsePlainKey() {
        let chord = KeyChord.parse("f12")
        expectEqual(chord?.key, "f12")
        expectEqual(chord?.modifiers, [])
    }

    static func testParseModifiers() {
        let chord = KeyChord.parse("cmd+shift+p")
        expectEqual(chord?.key, "p")
        expectEqual(chord?.modifiers, [.command, .shift])
    }

    static func testParseSuperAlias() {
        let chord = KeyChord.parse("super+k")
        expectEqual(chord?.key, "k")
        expectEqual(chord?.modifiers, [.command])
    }

    static func testParseUnknownModifier() {
        expectNil(KeyChord.parse("hyper+x"))
    }

    static func testParseKeymapArray() throws {
        let json = """
        [
            { "keys": ["cmd+k", "cmd+b"], "command": "toggle_line_numbers" },
            { "keys": ["cmd+shift+p"], "command": "show_command_palette", "args": {"x": 1} }
        ]
        """
        let entries = try KeymapParser.parse(data: Data(json.utf8))
        expectEqual(entries.count, 2)
        expectEqual(entries[0].keys, [KeyChord(key: "k", modifiers: [.command]),
                                      KeyChord(key: "b", modifiers: [.command])])
        expectEqual(entries[0].command, "toggle_line_numbers")
        expectNil(entries[0].args)
        expectEqual(entries[1].command, "show_command_palette")
        expectTrue(entries[1].args?["x"] as? Int == 1)
    }

    static func testSkipsMalformedEntry() throws {
        let json = """
        [
            { "keys": ["cmd+k"], "command": "good_one" },
            { "keys": ["hyper+x"], "command": "bad_modifier" },
            { "command": "missing_keys" },
            { "keys": ["cmd+j"] }
        ]
        """
        let entries = try KeymapParser.parse(data: Data(json.utf8))
        expectEqual(entries.count, 1)
        expectEqual(entries.first?.command, "good_one")
    }

    static func testStripLineComments() {
        let text = "{\n  // a comment\n  \"a\": 1\n}"
        let stripped = KeymapParser.stripLineComments(text)
        expectFalse(stripped.contains("comment"))
        expectTrue(stripped.contains("\"a\": 1"))
    }

    static func testStripLineCommentsInsideString() {
        let text = "{ \"url\": \"https://example.com\" }"
        let stripped = KeymapParser.stripLineComments(text)
        expectEqual(stripped, text)
    }

    static func testThrowsForNonArray() {
        let json = "{ \"not\": \"an array\" }"
        expectThrows {
            _ = try KeymapParser.parse(data: Data(json.utf8))
        }
    }
}
