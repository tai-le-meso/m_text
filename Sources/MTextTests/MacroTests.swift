import Foundation
import MTextCore
import MTextTestKit

enum MacroTests {

    static let suite = TestSuite("Macro", [
        ("parses a .sublime-macro array", testParse),
        ("parses a step with no args", testParseNoArgs),
        ("skips a malformed step but keeps the rest", testParseSkipsMalformed),
        ("tolerates // comments like the other JSON-ish formats", testParseComments),
        ("throws for a top-level object instead of an array", testParseNotArray),
        ("round-trips through serialize and parse", testRoundTrip),
        ("preserves argument types across a round trip", testRoundTripTypes),

        ("records nothing until started", testRecordsOnlyWhenStarted),
        ("coalesces a run of inserts into one step", testCoalescesInserts),
        ("a non-insert command breaks the run", testCommandBreaksRun),
        ("stop returns the macro and ends recording", testStop),
        ("stop returns nil when nothing was recorded", testStopEmpty),
        ("cancel discards what was captured", testCancel),
        ("starting again clears the previous recording", testRestart),
    ])

    // MARK: - Parsing

    private static let sample = """
    [
      {"command": "insert", "args": {"characters": "hello"}},
      {"command": "moveToBeginningOfLine:"}
    ]
    """

    static func testParse() {
        guard let macro = try? MacroParser.parse(data: Data(sample.utf8)) else {
            expectTrue(false, "a well-formed macro should parse")
            return
        }
        expectEqual(macro.steps.count, 2)
        expectEqual(macro.steps[0].command, "insert")
        expectEqual(macro.steps[0].insertedCharacters, "hello")
        expectEqual(macro.steps[1].command, "moveToBeginningOfLine:")
    }

    static func testParseNoArgs() {
        let macro = try? MacroParser.parse(data: Data(#"[{"command": "undo"}]"#.utf8))
        expectEqual(macro?.steps.first?.args.isEmpty, true)
    }

    /// A macro recorded by a newer build, or by real Sublime, should replay whatever it has
    /// in common rather than nothing at all.
    static func testParseSkipsMalformed() {
        let json = """
        [
          {"command": "undo"},
          {"nope": 1},
          {"command": ""},
          {"command": "redo"}
        ]
        """
        let macro = try? MacroParser.parse(data: Data(json.utf8))
        expectEqual(macro?.steps.map(\.command), ["undo", "redo"])
    }

    static func testParseComments() {
        let json = """
        // a hand-edited macro
        [ {"command": "undo"} ]
        """
        expectEqual((try? MacroParser.parse(data: Data(json.utf8)))?.steps.count, 1)
    }

    static func testParseNotArray() {
        expectThrows { _ = try MacroParser.parse(data: Data(#"{"command": "undo"}"#.utf8)) }
    }

    static func testRoundTrip() {
        let macro = Macro(steps: [.insert("abc"), MacroStep(command: "deleteBackward:")])
        guard let data = try? MacroParser.serialize(macro),
              let restored = try? MacroParser.parse(data: data) else {
            expectTrue(false, "serialize then parse should succeed")
            return
        }
        expectEqual(restored, macro)
    }

    /// Args go out through JSON and come back; a bool must not return as an int, which is
    /// the bug `SettingValue` exists to prevent.
    static func testRoundTripTypes() {
        let step = MacroStep(command: "move", args: [
            "forward": .bool(true),
            "amount": .int(3),
            "by": .string("words"),
        ])
        guard let data = try? MacroParser.serialize(Macro(steps: [step])),
              let restored = try? MacroParser.parse(data: data).steps.first else {
            expectTrue(false, "round trip should succeed")
            return
        }
        expectEqual(restored.args["forward"], .bool(true))
        expectEqual(restored.args["amount"], .int(3))
        expectEqual(restored.args["by"], .string("words"))
    }

    // MARK: - Recording

    static func testRecordsOnlyWhenStarted() {
        let recorder = MacroRecorder()
        recorder.recordInsert("x")
        expectTrue(recorder.steps.isEmpty, "not recording yet")
        expectFalse(recorder.isRecording)
    }

    /// Typing "hello" arrives as five `insertText` calls; five steps would make the file
    /// unreadable and replay slower for no benefit.
    static func testCoalescesInserts() {
        let recorder = MacroRecorder()
        recorder.start()
        for character in "hello" { recorder.recordInsert(String(character)) }
        expectEqual(recorder.steps.count, 1)
        expectEqual(recorder.steps.first?.insertedCharacters, "hello")
    }

    static func testCommandBreaksRun() {
        let recorder = MacroRecorder()
        recorder.start()
        recorder.recordInsert("foo")
        recorder.recordCommand("moveToBeginningOfLine:")
        recorder.recordInsert("bar")
        expectEqual(recorder.steps.count, 3, "the command splits the two typing runs")
        expectEqual(recorder.steps[0].insertedCharacters, "foo")
        expectEqual(recorder.steps[2].insertedCharacters, "bar")
    }

    static func testStop() {
        let recorder = MacroRecorder()
        recorder.start()
        recorder.recordInsert("a")
        let macro = recorder.stop()
        expectEqual(macro?.steps.count, 1)
        expectFalse(recorder.isRecording)
    }

    static func testStopEmpty() {
        let recorder = MacroRecorder()
        recorder.start()
        expectNil(recorder.stop(), "an empty recording is not worth keeping")
    }

    static func testCancel() {
        let recorder = MacroRecorder()
        recorder.start()
        recorder.recordInsert("a")
        recorder.cancel()
        expectTrue(recorder.steps.isEmpty)
        expectFalse(recorder.isRecording)
    }

    static func testRestart() {
        let recorder = MacroRecorder()
        recorder.start()
        recorder.recordInsert("first")
        recorder.start()
        recorder.recordInsert("second")
        expectEqual(recorder.steps.count, 1)
        expectEqual(recorder.steps.first?.insertedCharacters, "second")
    }
}
