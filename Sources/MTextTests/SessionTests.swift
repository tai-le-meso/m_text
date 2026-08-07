import Foundation
import MTextCore
import MTextTestKit

/// T84/T85 — the pure-Foundation half of session persistence: the `Codable` model
/// and `SessionStore`'s file handling. The AppKit capture/restore glue in
/// `MainWindowController`/`SessionManager` is not unit-testable here, consistent
/// with the rest of MTextUI.
enum SessionTests {

    static let suite = TestSuite("Session", [
        ("model round-trips through JSON", testModelRoundTrip),
        ("store saves and loads a session", testStoreRoundTrip),
        ("load returns nil for a missing file", testLoadMissing),
        ("load returns nil for corrupt JSON", testLoadCorrupt),
        ("load returns nil for a future format version", testLoadFutureVersion),
        ("buffers round-trip and keep exact text", testBufferRoundTrip),
        ("prune deletes stale buffers and keeps referenced ones", testPrune),
        ("readBuffer rejects names that could escape the directory", testBufferNameSafety),
        ("every folder of a multi-folder window round-trips", testMultipleFoldersRoundTrip),
        ("a session from an older build still restores its folder", testLegacySingleFolderMigrates),
        ("the legacy field is not written back out", testLegacyFieldNotRewritten),
        ("a window with no folders restores none", testNoFolders),
    ])

    /// The regression this replaces: only `folders.first` was stored, so every other root of
    /// a multi-folder window vanished on relaunch.
    static func testMultipleFoldersRoundTrip() {
        let window = SessionWindow(adHocFolderPaths: ["/tmp/a", "/tmp/b", "/tmp/c"])
        let state = SessionState(version: 1, windows: [window])
        let data = try! JSONEncoder().encode(state)
        let decoded = try! JSONDecoder().decode(SessionState.self, from: data)
        expectEqual(decoded.windows[0].adHocFolderPaths, ["/tmp/a", "/tmp/b", "/tmp/c"])
        expectEqual(decoded.windows[0].restorableFolderPaths, ["/tmp/a", "/tmp/b", "/tmp/c"])
    }

    /// Sessions on disk predate `adHocFolderPaths`. Decoding must not fail and must not lose
    /// the folder — a version bump would have discarded every window and unsaved buffer.
    static func testLegacySingleFolderMigrates() {
        let json = """
        {"version":1,"windows":[{"adHocFolderPath":"/tmp/legacy","sidebarVisible":true,
         "focusedPaneIndex":0,"panes":[]}]}
        """
        let decoded = try! JSONDecoder().decode(SessionState.self, from: Data(json.utf8))
        let window = decoded.windows[0]
        expectEqual(window.adHocFolderPaths, [], "the new field is genuinely absent")
        expectEqual(window.restorableFolderPaths, ["/tmp/legacy"], "but the folder still restores")
        expectTrue(window.sidebarVisible, "the rest of the window decodes normally")
    }

    /// The legacy key is read, never written, so it disappears on the first save rather than
    /// lingering as a second source of truth.
    static func testLegacyFieldNotRewritten() {
        var window = SessionWindow(adHocFolderPaths: ["/tmp/a"])
        window.adHocFolderPath = "/tmp/legacy"
        let data = try! JSONEncoder().encode(SessionState(version: 1, windows: [window]))
        let text = String(data: data, encoding: .utf8)!
        expectFalse(text.contains("adHocFolderPath\""), "the old key is not encoded")
        expectTrue(text.contains("adHocFolderPaths"))
    }

    static func testNoFolders() {
        let window = SessionWindow(projectFilePath: "/tmp/x.sublime-project")
        expectEqual(window.restorableFolderPaths, [], "a project-file window has no ad hoc folders")
    }

    private static func makeTempDirectory() -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("m_text_SessionTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func sampleState() -> SessionState {
        let tab1 = SessionTab(filePath: "/tmp/a.swift", caretLine: 12, caretColumn: 4,
                              scrollX: 0, scrollY: 240, syntaxScope: "source.swift")
        let tab2 = SessionTab(bufferFile: "Buffer-0.txt", caretLine: 0, caretColumn: 0,
                              encodingRaw: "utf8", lineEndingRaw: "crlf")
        let window = SessionWindow(frame: [10, 20, 900, 620],
                                   projectFilePath: "/tmp/p.sublime-project",
                                   sidebarVisible: true,
                                   focusedPaneIndex: 1,
                                   panes: [SessionPane(tabs: [tab1], activeIndex: 0),
                                           SessionPane(tabs: [tab2], activeIndex: 0)])
        return SessionState(windows: [window])
    }

    static func testModelRoundTrip() throws {
        let state = sampleState()
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(SessionState.self, from: data)
        expectEqual(decoded, state)
    }

    static func testStoreRoundTrip() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)

        let state = sampleState()
        try store.save(state)
        expectEqual(store.load(), state)

        // Overwriting replaces, not appends.
        let empty = SessionState(windows: [])
        try store.save(empty)
        expectEqual(store.load(), empty)
    }

    static func testLoadMissing() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        expectNil(SessionStore(directory: dir).load())
    }

    static func testLoadCorrupt() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)
        try Data("{not json!".utf8).write(to: store.sessionFileURL)
        expectNil(store.load(), "corrupt session must read as no session, not crash launch")
    }

    static func testLoadFutureVersion() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)
        let future = "{\"version\": \(SessionState.currentVersion + 1), \"windows\": []}"
        try Data(future.utf8).write(to: store.sessionFileURL)
        expectNil(store.load(), "a newer format must not be half-understood")
    }

    static func testBufferRoundTrip() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)

        // Exact text, including trailing newline, emoji, and Windows line endings —
        // the buffer must be byte-faithful or hot exit silently corrupts work.
        let text = "line one\r\nline two 🚀\r\n\r\n"
        let name = try store.writeBuffer(text, index: 3)
        expectEqual(name, "Buffer-3.txt")
        expectEqual(store.readBuffer(named: name), text)
        expectNil(store.readBuffer(named: "Buffer-99.txt"), "missing buffer reads as nil")
    }

    static func testPrune() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)

        let keep = try store.writeBuffer("keep me", index: 0)
        let stale = try store.writeBuffer("stale", index: 1)
        // A non-buffer file in the directory must never be touched by pruning.
        try store.save(SessionState(windows: []))

        store.pruneBuffers(keeping: [keep])
        expectEqual(store.readBuffer(named: keep), "keep me")
        expectNil(store.readBuffer(named: stale))
        expectTrue(FileManager.default.fileExists(atPath: store.sessionFileURL.path),
                   "prune must only remove Buffer-* files")
    }

    static func testBufferNameSafety() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)

        // These names come from JSON on disk, which anyone can edit — none of them may
        // reach the file system as a path.
        expectNil(store.readBuffer(named: "../Session.json"))
        expectNil(store.readBuffer(named: "Buffer-../../../etc/passwd"))
        expectNil(store.readBuffer(named: "Buffer-0/../../x.txt"))
        expectNil(store.readBuffer(named: "/etc/passwd"))
        expectNil(store.readBuffer(named: "Session.json"), "only Buffer-* names are readable")
    }
}
