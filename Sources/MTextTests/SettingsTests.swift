import Foundation
import MTextCore
import MTextTestKit

enum SettingsTests {

    static let suite = TestSuite("Settings", [
        ("parses a plain settings object", testParseObject),
        ("tells bools apart from the numbers 0 and 1", testBoolVsNumber),
        ("strips // comments the way keymap and project files do", testStripsComments),
        ("skips values whose shape has no setting, keeping the rest", testSkipsUnrepresentable),
        ("throws for a top-level array instead of an object", testThrowsForNonObject),
        ("resolves shipped defaults with no other layer", testDefaultsOnly),
        ("a watched file change reloads without deadlocking", testWatchDoesNotDeadlock),
        ("later layers win per key, not wholesale", testPerKeyOverride),
        ("applies the full default->user->syntax->project->view order", testFullPrecedence),
        ("derives indentUnit from tab_size and translate_tabs_to_spaces", testIndentUnit),
        ("accepts draw_white_space as both a bool and a Sublime string", testDrawWhiteSpace),
        ("clamps tab_size to at least 1", testTabSizeFloor),
        ("documented default file matches the values actually applied", testDefaultFileMatchesDefaults),
        ("reads .sublime-settings files out of the user directory", testStoreLoadsUserAndSyntax),
        ("ignores the generated read-only Default file as a layer", testStoreIgnoresDefaultFile),
        ("falls through a corrupt file to the layer below", testStoreSkipsCorruptFile),
        ("project settings parse out of a .sublime-project", testProjectSettingsLayer),
    ])

    // MARK: - Parsing

    static func testParseObject() {
        let layer = try? SettingsParser.parse(text: """
        { "tab_size": 2, "font_face": "Menlo", "rulers": [80, 120] }
        """, name: "t")
        expectEqual(layer?.values["tab_size"], .int(2))
        expectEqual(layer?.values["font_face"], .string("Menlo"))
        expectEqual(layer?.values["rulers"], .intArray([80, 120]))
    }

    /// `JSONSerialization` hands back `NSNumber` for both `true` and `1`; without the
    /// `CFBooleanGetTypeID` check they'd be indistinguishable and every bool setting
    /// would read as an int.
    static func testBoolVsNumber() {
        let layer = try? SettingsParser.parse(text: """
        { "line_numbers": true, "tab_size": 1 }
        """, name: "t")
        expectEqual(layer?.values["line_numbers"], .bool(true))
        expectEqual(layer?.values["tab_size"], .int(1))
    }

    static func testStripsComments() {
        let layer = try? SettingsParser.parse(text: """
        // leading comment
        {
            "tab_size": 8, // trailing comment
            "font_face": "a // b"
        }
        """, name: "t")
        expectEqual(layer?.values["tab_size"], .int(8))
        // The `//` inside the string is content, not a comment.
        expectEqual(layer?.values["font_face"], .string("a // b"))
    }

    static func testSkipsUnrepresentable() {
        let layer = try? SettingsParser.parse(text: """
        { "tab_size": 3, "nested": { "a": 1 }, "mixed": [1, "two"] }
        """, name: "t")
        expectEqual(layer?.values["tab_size"], .int(3))
        expectNil(layer?.values["nested"])
        expectNil(layer?.values["mixed"])
    }

    static func testThrowsForNonObject() {
        expectThrows { _ = try SettingsParser.parse(text: "[1, 2]", name: "t") }
    }

    // MARK: - Resolution

    static func testDefaultsOnly() {
        let settings = SettingsResolver.resolve([SettingsResolver.defaultLayer])
        expectEqual(settings.tabSize, 4)
        expectEqual(settings.fontSize, 13)
        expectTrue(settings.translateTabsToSpaces)
        expectTrue(settings.lineNumbers)
        expectFalse(settings.drawWhiteSpace)
        expectEqual(settings.rulers, [])
        expectNil(settings.fontFace)
    }

    /// The point of layering: a syntax file setting only `tab_size` must not reset the
    /// font the user set globally.
    static func testPerKeyOverride() {
        let user = SettingsLayer(name: "User", values: ["font_size": .double(16),
                                                        "tab_size": .int(4)])
        let syntax = SettingsLayer(name: "Syntax", values: ["tab_size": .int(2)])
        let settings = SettingsResolver.resolve([SettingsResolver.defaultLayer, user, syntax])
        expectEqual(settings.tabSize, 2, "syntax wins for the key it names")
        expectEqual(settings.fontSize, 16, "and leaves the user's font alone")
    }

    static func testFullPrecedence() {
        func layer(_ name: String, _ size: Int) -> SettingsLayer {
            SettingsLayer(name: name, values: ["tab_size": .int(size)])
        }
        let stack = [SettingsResolver.defaultLayer,
                     layer("User", 2), layer("Syntax", 3), layer("Project", 4), layer("View", 5)]

        expectEqual(SettingsResolver.resolve(stack).tabSize, 5, "view is highest")
        expectEqual(SettingsResolver.resolve(Array(stack.dropLast())).tabSize, 4, "then project")
        expectEqual(SettingsResolver.resolve(Array(stack.dropLast(2))).tabSize, 3, "then syntax")
        expectEqual(SettingsResolver.resolve(Array(stack.dropLast(3))).tabSize, 2, "then user")
        expectEqual(SettingsResolver.resolve(Array(stack.dropLast(4))).tabSize, 4, "then the default")
    }

    static func testIndentUnit() {
        var settings = SettingsResolver.resolve([SettingsResolver.defaultLayer])
        expectEqual(settings.indentUnit, "    ", "4 spaces by default")

        settings.tabSize = 2
        expectEqual(settings.indentUnit, "  ")

        // Tab mode inserts one tab whatever `tab_size` says — that setting is about how
        // wide a tab *renders*, not how many characters to insert.
        settings.translateTabsToSpaces = false
        expectEqual(settings.indentUnit, "\t")
    }

    static func testDrawWhiteSpace() {
        func resolve(_ value: SettingValue) -> Bool {
            SettingsResolver.resolve([
                SettingsResolver.defaultLayer,
                SettingsLayer(name: "u", values: ["draw_white_space": value]),
            ]).drawWhiteSpace
        }
        expectTrue(resolve(.bool(true)))
        expectFalse(resolve(.bool(false)))
        expectFalse(resolve(.string("none")))
        expectTrue(resolve(.string("all")))
        expectTrue(resolve(.string("selection")), "rendered all-or-nothing, so not 'none' means on")
    }

    /// A zero or negative `tab_size` would make `indentUnit` an empty string, so Tab
    /// would insert nothing at all.
    static func testTabSizeFloor() {
        let settings = SettingsResolver.resolve([
            SettingsResolver.defaultLayer,
            SettingsLayer(name: "u", values: ["tab_size": .int(0)]),
        ])
        expectEqual(settings.tabSize, 1)
        expectEqual(settings.indentUnit, " ")
    }

    /// Guards the one real risk in shipping documentation as a file: that the commented
    /// defaults a user reads drift away from the values the app actually applies.
    static func testDefaultFileMatchesDefaults() {
        guard let layer = try? SettingsParser.parse(text: SettingsResolver.defaultFileText,
                                                    name: "Default") else {
            expectTrue(false, "the documented default file must itself parse")
            return
        }
        let fromFile = SettingsResolver.resolve([layer])
        let fromCode = SettingsResolver.resolve([SettingsResolver.defaultLayer])
        expectEqual(fromFile, fromCode)
    }

    // MARK: - Store

    /// Real temp directories rather than a fake filesystem, matching `FileIndexTests`.
    /// `resolvingSymlinksInPath()` because `/var` is a symlink to `/private/var` on macOS
    /// — see the compile bug classes in KNOWLEDGE.md.
    private static func withTempDirectory(_ body: (URL) throws -> Void) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mtext-settings-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try? body(root)
    }

    private static func write(_ text: String, to directory: URL, named name: String) {
        try? Data(text.utf8).write(to: directory.appendingPathComponent(name))
    }

    static func testStoreLoadsUserAndSyntax() {
        withTempDirectory { directory in
            write(#"{ "tab_size": 2 }"#, to: directory, named: "Preferences.sublime-settings")
            write(#"{ "translate_tabs_to_spaces": false }"#, to: directory,
                  named: "Makefile.sublime-settings")

            let store = SettingsStore(userDirectory: directory)
            let swift = store.settings(syntaxName: "Swift")
            expectEqual(swift.tabSize, 2, "user layer applies to every syntax")
            expectTrue(swift.translateTabsToSpaces)

            // The classic reason per-syntax settings exist at all.
            let make = store.settings(syntaxName: "Makefile")
            expectEqual(make.tabSize, 2)
            expectFalse(make.translateTabsToSpaces)
            expectEqual(make.indentUnit, "\t")
        }
    }

    /// `Default.sublime-settings` is generated for the read-only pane. Loading it as a
    /// user layer would re-apply every default *above* the user's own file and silently
    /// undo their settings.
    static func testStoreIgnoresDefaultFile() {
        withTempDirectory { directory in
            write(#"{ "tab_size": 2 }"#, to: directory, named: "Preferences.sublime-settings")
            let store = SettingsStore(userDirectory: directory)
            _ = try? store.writeDefaultFile()
            store.reload()
            expectEqual(store.settings(syntaxName: nil).tabSize, 2)
        }
    }

    static func testStoreSkipsCorruptFile() {
        withTempDirectory { directory in
            write("{ this is not json", to: directory, named: "Preferences.sublime-settings")
            let store = SettingsStore(userDirectory: directory)
            expectEqual(store.settings(syntaxName: nil).tabSize, 4, "falls back to the default")
            expectTrue(store.userLayer.values.isEmpty)
        }
    }

    static func testProjectSettingsLayer() {
        let json = """
        {
            "folders": [{ "path": "." }],
            "settings": { "tab_size": 8, "rulers": [100] }
        }
        """
        let url = URL(fileURLWithPath: "/tmp/x.sublime-project")
        guard let project = try? ProjectParser.parse(data: Data(json.utf8), projectFileURL: url) else {
            expectTrue(false, "project with a settings object should parse")
            return
        }
        expectEqual(project.settings.values["tab_size"], .int(8))

        let settings = SettingsResolver.resolve([SettingsResolver.defaultLayer, project.settings])
        expectEqual(settings.tabSize, 8)
        expectEqual(settings.rulers, [100])
    }

    /// Writing into the watched directory must reload, not hang.
    ///
    /// The file-system source used to run its handler on the same serial queue that
    /// `reload()` blocks on with `queue.sync`, so the handler waited on the queue it was
    /// already running on and libdispatch trapped it — the app died every time Settings was
    /// opened, because opening Settings writes the generated defaults file into exactly this
    /// directory. A timeout here *is* the assertion: against the old code this never fires.
    static func testWatchDoesNotDeadlock() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("m_text_SettingsWatch_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SettingsStore(userDirectory: directory)
        store.reload()
        let changed = DispatchSemaphore(value: 0)
        store.onChange = { changed.signal() }
        store.startWatching()
        defer { store.stopWatching() }

        // The same shape the app writes: a real settings file appearing in the directory.
        let file = directory.appendingPathComponent("Preferences.sublime-settings")
        try? Data(#"{"tab_size": 7}"#.utf8).write(to: file)

        // `onChange` is delivered on the main queue, and this harness runs on it, so the
        // semaphore cannot simply be waited on — pump the run loop instead.
        let deadline = Date().addingTimeInterval(5)
        while changed.wait(timeout: .now()) == .timedOut, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }

        expectTrue(Date() < deadline, "the watcher reloaded instead of deadlocking")
        expectEqual(store.userLayer.values["tab_size"], .int(7),
                    "and the new value was actually picked up")
    }
}
