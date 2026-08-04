import AppKit
import MTextUI

// NSApplication bootstrap without storyboards, nibs, or Xcode.

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [MainWindowController] = []
    private var sessionManager: SessionManager!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
        sessionManager = SessionManager(windows: { [weak self] in self?.controllers ?? [] })
        if let restored = sessionManager.restoreWindows() {
            // Prepend rather than replace: a Finder "open with" can deliver
            // `application(_:openFile:)` before this method runs, and that window is
            // already in `controllers`. Discarding the restored session in that case
            // would be silent data loss — the next debounced save would overwrite
            // Session.json with just the one new window, and `pruneBuffers` would then
            // delete every stashed unsaved buffer from the previous session.
            controllers = restored + controllers
        } else if controllers.isEmpty {
            newWindow(nil)
        }
        runSmokeTestIfRequested()
    }

    /// Opt-in UI smoke check — `MTEXT_SMOKE_TEST=1 make debug`, exits non-zero on failure.
    ///
    /// Exists because `MTextTests` links only `MTextCore`, so nothing in the automated
    /// suite can see a window. Both of this project's worst bugs so far lived in exactly
    /// that gap: the blank pane (KNOWLEDGE.md) and then ⌘F silently doing nothing after
    /// "Split View Right" produced a zero-width pane. Each was found by hand-driving the
    /// app and reading geometry; this makes that repeatable.
    ///
    /// It drives the real window controller through split + find and asserts the two
    /// properties that were actually broken — every pane has usable width, and the find
    /// bar ends up visibly sized. Deliberately assertions rather than a tree dump: a dump
    /// needs a human to notice `0.0` in a wall of numbers, which is precisely what went
    /// unnoticed. Extend it when a UI bug escapes; that is the point of it.
    private func runSmokeTestIfRequested() {
        guard ProcessInfo.processInfo.environment["MTEXT_SMOKE_TEST"] != nil else { return }
        // stdout is block-buffered down a pipe, so a killed or crashing run would lose
        // everything printed.
        setvbuf(stdout, nil, _IONBF, 0)

        var failures: [String] = []
        func check(_ condition: Bool, _ description: String) {
            print(condition ? "  ✓ \(description)" : "  ✗ \(description)")
            if !condition { failures.append(description) }
        }

        /// Steps run one per run-loop turn with a gap between them: constraint changes and
        /// `NSSplitView` retiling both resolve at the *next* layout pass, never
        /// synchronously, so asserting immediately after acting reads stale geometry.
        func run(_ steps: [() -> Void], index: Int = 0) {
            guard index < steps.count else {
                print(failures.isEmpty ? "smoke test PASSED" : "smoke test FAILED: \(failures.count)")
                exit(failures.isEmpty ? 0 : 1)
            }
            steps[index]()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { run(steps, index: index + 1) }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            print("UI smoke test")
            guard let controller = self?.controllers.first, let window = controller.window else {
                print("  ✗ no window controller"); exit(1)
            }

            func descendants(of view: NSView, named name: String) -> [NSView] {
                var found: [NSView] = []
                func walk(_ v: NSView) {
                    if String(describing: type(of: v)) == name { found.append(v) }
                    v.subviews.forEach(walk)
                }
                walk(view)
                return found
            }
            /// The pane container views, in the same order as the controller's own `panes`.
            func paneViews() -> [NSView] {
                var found: [NSView] = []
                func walk(_ v: NSView) {
                    if v.superview.map({ String(describing: type(of: $0)) == "NSSplitView" }) == true,
                       v.superview !== window.contentView {
                        found.append(v)
                    }
                    v.subviews.forEach(walk)
                }
                walk(window.contentView!)
                return found
            }
            func findBarPaneIndex() -> Int? {
                guard let bar = descendants(of: window.contentView!, named: "FindBar").first else { return nil }
                return paneViews().firstIndex { bar.isDescendant(of: $0) }
            }
            /// Stands in for clicking into a pane's text: `EditorView`'s mouse handler does
            /// exactly this, and it is the path that used to bypass `activate(_:)`.
            func focusEditor(inPane index: Int) {
                let panes = paneViews()
                guard panes.indices.contains(index),
                      let editor = descendants(of: panes[index], named: "EditorView").first
                else { return }
                window.makeFirstResponder(editor)
            }
            /// ⌘F the way the menu actually delivers it: down the responder chain to the
            /// focused editor, *not* by calling the controller. Those are different code
            /// paths — the controller's own `performFind` is only the fallback used while
            /// the find field has focus — and only this one reflects what a keypress does.
            func pressCommandF() {
                guard let editor = window.firstResponder as? NSView,
                      String(describing: type(of: editor)) == "EditorView" else {
                    print("  ✗ ⌘F: first responder is not an editor"); return
                }
                _ = NSApp.sendAction(#selector(EditorView.performFind(_:)), to: editor, from: nil)
            }

            /// T92: folding changes the document view's height and the line↔row mapping,
            /// which is exactly the class of geometry that has broken badly before here.
            func foldingCheck() {
                let panes = paneViews()
                guard let editor = panes.first.flatMap({ descendants(of: $0, named: "EditorView").first })
                        as? EditorView else {
                    check(false, "found an editor to fold in")
                    return
                }
                // Must be taller than the viewport, or `updateFrameSize`'s
                // `max(viewport, content)` floor hides the change and the check can never
                // fail — which is exactly what it did the first time it was written.
                editor.text = String(repeating: "def f():\n    a\n    b\n", count: 120)
                editor.layoutSubtreeIfNeeded()
                let unfoldedHeight = editor.frame.height
                editor.foldAll(nil)
                editor.layoutSubtreeIfNeeded()
                let foldedHeight = editor.frame.height
                check(foldedHeight < unfoldedHeight,
                      "folding shrinks the document view (\(unfoldedHeight) -> \(foldedHeight))")

                editor.unfoldAll(nil)
                editor.layoutSubtreeIfNeeded()
                check(editor.frame.height == unfoldedHeight,
                      "unfolding restores it exactly (\(editor.frame.height) vs \(unfoldedHeight))")
            }

            /// T28: wrapping changes the row count, the canvas height, and — because the
            /// canvas becomes the viewport — its width too. All three have broken before in
            /// this file's geometry, so all three are asserted.
            func wrapCheck() {
                let panes = paneViews()
                guard let editor = panes.first.flatMap({ descendants(of: $0, named: "EditorView").first })
                        as? EditorView else {
                    check(false, "found an editor to wrap in")
                    return
                }
                editor.wordWrapEnabled = false
                editor.text = String(repeating: String(repeating: "word ", count: 60) + "\n", count: 40)
                editor.layoutSubtreeIfNeeded()
                let unwrappedHeight = editor.frame.height
                let unwrappedWidth = editor.frame.width

                editor.wordWrapEnabled = true
                editor.layoutSubtreeIfNeeded()
                check(editor.frame.height > unwrappedHeight,
                      "wrapping makes the canvas taller (\(unwrappedHeight) -> \(editor.frame.height))")
                check(editor.frame.width < unwrappedWidth,
                      "and no wider than the viewport (\(unwrappedWidth) -> \(editor.frame.width))")

                editor.wordWrapEnabled = false
                editor.layoutSubtreeIfNeeded()
                check(editor.frame.height == unwrappedHeight && editor.frame.width == unwrappedWidth,
                      "turning it off restores both exactly")
            }

            /// T93: the minimap takes width from the editor, so turning it on must shrink
            /// the editor's viewport and turning it off must give it back exactly — the same
            /// class of geometry that broke for folding and wrapping.
            func minimapCheck() {
                let panes = paneViews()
                guard let editor = panes.first.flatMap({ descendants(of: $0, named: "EditorView").first })
                        as? EditorView,
                      let strip = panes.first.flatMap({ descendants(of: $0, named: "Minimap").first })
                else {
                    check(false, "found an editor and a minimap")
                    return
                }
                editor.minimapEnabled = false
                editor.layoutSubtreeIfNeeded()
                let widthWithout = editor.enclosingScrollView?.frame.width ?? 0
                check(strip.frame.width == 0, "minimap is collapsed when off (\(strip.frame.width))")

                editor.minimapEnabled = true
                controller.window?.contentView?.layoutSubtreeIfNeeded()
                check(strip.frame.width > 50, "minimap takes real width when on (\(strip.frame.width))")
                let widthWith = editor.enclosingScrollView?.frame.width ?? 0
                check(widthWith < widthWithout,
                      "and the editor gives up that width (\(widthWithout) -> \(widthWith))")

                editor.minimapEnabled = false
                controller.window?.contentView?.layoutSubtreeIfNeeded()
                check((editor.enclosingScrollView?.frame.width ?? 0) == widthWithout,
                      "turning it off restores the editor width exactly")
            }

            /// T94: record → replay through the real editor. The unit tests cover the
            /// recorder and the file format; only a live editor can show that the hooks in
            /// `insertText`/`doCommand` fire and that replay doesn't re-record itself.
            func macroCheck() {
                let panes = paneViews()
                guard let editor = panes.first.flatMap({ descendants(of: $0, named: "EditorView").first })
                        as? EditorView else {
                    check(false, "found an editor to record in")
                    return
                }
                editor.wordWrapEnabled = false
                editor.minimapEnabled = false
                editor.text = ""
                window.makeFirstResponder(editor)

                editor.toggleMacroRecording(nil)
                editor.insertText("abc", replacementRange: NSRange(location: NSNotFound, length: 0))
                editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                editor.toggleMacroRecording(nil)

                let macro = EditorView.lastMacro
                check(macro?.steps.count == 2,
                      "recorded a coalesced insert plus the newline (got \(macro?.steps.count ?? -1))")
                check(macro?.steps.first?.insertedCharacters == "abc",
                      "five keystrokes coalesced into one insert step")

                let before = editor.text
                editor.playbackMacro(nil)
                check(editor.text == before + "abc\n",
                      "replay appended the recorded text once")
                // The bug this guards: replay running through the same hooks that recorded
                // it, doubling the macro every run.
                check(EditorView.lastMacro?.steps.count == 2,
                      "replay did not re-record itself (\(EditorView.lastMacro?.steps.count ?? -1) steps)")
            }

            /// T95: actually run a build. Only a live app can show that Process launches,
            /// output streams back, the panel appears and file_regex finds the error —
            /// the unit tests cover parsing and regex matching, not execution.
            /// Installs its own `.sublime-build` so the check is hermetic — it must not
            /// depend on whatever the machine happens to have configured, and it removes the
            /// fixture again in `buildResultCheck`.
            func installBuildFixture() -> URL? {
                guard let directory = BuildSystemStore.defaultDirectories.last else { return nil }
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent("ZZSmokeTest.sublime-build")
                let json = """
                {
                    "shell_cmd": "echo 'src/demo.txt:3:5: error: smoke test diagnostic'; exit 1",
                    "file_regex": "^(.+):([0-9]+):([0-9]+): (.+)$"
                }
                """
                try? Data(json.utf8).write(to: url)
                return url
            }
            var buildFixture: URL?

            func buildCheck() {
                buildFixture = installBuildFixture()
                check(buildFixture != nil, "installed a build fixture")
                controller.build(nil)
                let panels = descendants(of: window.contentView!, named: "BuildPanel")
                check(panels.count == 1, "build panel appeared (got \(panels.count))")
                check((panels.first?.frame.height ?? 0) > 50,
                      "and has real height (\(panels.first?.frame.height ?? 0))")
            }

            /// Checked a step later, so the process has exited and its output been parsed.
            func buildResultCheck() {
                let found = controller.smokeTestBuildDiagnostics
                check(found.count == 1, "file_regex found the error (got \(found.count))")
                check(found.first?.line == 2,
                      "line 3 in output is line 2 internally (got \(found.first?.line ?? -1))")
                check(found.first?.column == 4, "and column 5 is column 4")
                if let buildFixture { try? FileManager.default.removeItem(at: buildFixture) }
            }

            /// T102: the diff is only useful if it actually appears against the file on
            /// disk, and revert has to put the text back — neither is visible to the unit
            /// tests, which only see the diff algorithm.
            func diffCheck() {
                let root = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("mtext-diff-\(UUID().uuidString)")
                    .resolvingSymlinksInPath()
                try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let file = root.appendingPathComponent("diff.txt")
                try? Data("alpha\nbeta\ngamma\n".utf8).write(to: file)

                controller.smokeTestOpen(file)
                check(controller.smokeTestDiffMarkCount == 0,
                      "a freshly opened file has no diff marks (got \(controller.smokeTestDiffMarkCount))")

                controller.smokeTestEditorText = "alpha\nBETA\ngamma\n"
                check(controller.smokeTestDiffMarkCount > 0,
                      "editing marks the changed line (got \(controller.smokeTestDiffMarkCount))")

                controller.smokeTestRevertHunk(atLine: 1)
                check(controller.smokeTestEditorText.contains("beta"),
                      "revert put the original line back")
                check(controller.smokeTestDiffMarkCount == 0,
                      "and cleared the marks (got \(controller.smokeTestDiffMarkCount))")
            }

            /// T101: exercises the real NSSpellChecker. The unit tests cover which ranges
            /// are eligible; this covers that the checker is actually consulted, that a
            /// correct word is left alone, and that it is off unless asked for.
            func spellCheckCheck() {
                // Unambiguous nonsense rather than plausible typos: macOS's dictionary
                // accepts some real misspellings ("mispelling" passes), which would make the
                // assertion depend on the system dictionary rather than on our code.
                controller.smokeTestEditorText = "thiss worrd andd anotherr zzqqxx\n"
                controller.smokeTestSpellCheckEnabled = false
                check(controller.smokeTestMisspellingCount(onLine: 0) == 0,
                      "nothing is checked while spell check is off")

                controller.smokeTestSpellCheckEnabled = true
                let found = controller.smokeTestMisspellingCount(onLine: 0)
                check(found >= 2, "found the misspellings in a plain-text line (got \(found): \(controller.smokeTestMisspellingDescription(onLine: 0)))")

                controller.smokeTestEditorText = "this sentence is entirely correct\n"
                check(controller.smokeTestMisspellingCount(onLine: 0) == 0,
                      "a correct line reports nothing")
            }

            /// T103: a phantom has to *reserve a row*, pushing the lines below it down —
            /// that is the difference between an inline annotation and an overlay drawn on
            /// top of real text. Only a live editor shows the canvas actually growing.
            func phantomCheck() {
                controller.smokeTestSetWordWrap(false)
                controller.smokeTestClearPhantoms()
                // Taller than the viewport, so the canvas height is content-driven rather
                // than pinned to the viewport floor — the same trap the folding check hit.
                controller.smokeTestEditorText = String(repeating: "line of text\n", count: 200)
                let before = controller.smokeTestEditorHeight

                controller.smokeTestSetPhantom(line: 5, text: "error: something went wrong")
                let withPhantom = controller.smokeTestEditorHeight
                check(withPhantom > before,
                      "an annotation reserves a row (\(before) -> \(withPhantom))")

                controller.smokeTestClearPhantoms()
                check(controller.smokeTestEditorHeight == before,
                      "clearing gives the row back exactly")
            }

            run([
                { controller.splitViewRight(nil) },
                { foldingCheck() },
                { wrapCheck() },
                { minimapCheck() },
                { macroCheck() },
                { buildCheck() },
                { buildResultCheck() },
                { diffCheck() },
                { spellCheckCheck() },
                { phantomCheck() },
                {
                    let panes = paneViews()
                    check(panes.count == 2, "split produced two panes (got \(panes.count))")
                    for (index, pane) in panes.enumerated() {
                        // The regression: a pane present, focused, and zero-width.
                        check(pane.frame.width > 100, "pane \(index) has usable width (\(pane.frame.width))")
                    }
                },

                // ⌘F must open the bar in whichever pane has focus — checked in both
                // directions, because "always opens on the right" is exactly the bug.
                { focusEditor(inPane: 0) },
                {
                    check(controller.smokeTestFocusedPaneIndex == 0,
                          "clicking pane 0's text focuses pane 0 (got \(controller.smokeTestFocusedPaneIndex))")
                    pressCommandF()
                },
                {
                    check(findBarPaneIndex() == 0, "⌘F opens the find bar in focused pane 0 (got \(findBarPaneIndex().map(String.init) ?? "none"))")
                    if let bar = descendants(of: window.contentView!, named: "FindBar").first {
                        check(bar.frame.width > 100 && bar.frame.height > 10,
                              "find bar is visibly sized (\(bar.frame.size))")
                        check(!bar.isHiddenOrHasHiddenAncestor, "find bar is not hidden")
                    }
                },

                // Now the other pane, with the bar already open elsewhere.
                { focusEditor(inPane: 1) },
                {
                    check(controller.smokeTestFocusedPaneIndex == 1,
                          "clicking pane 1's text focuses pane 1 (got \(controller.smokeTestFocusedPaneIndex))")
                    check(findBarPaneIndex() == 1, "an open find bar follows focus to pane 1 (got \(findBarPaneIndex().map(String.init) ?? "none"))")
                    pressCommandF()
                },
                {
                    check(findBarPaneIndex() == 1, "⌘F opens the find bar in focused pane 1 (got \(findBarPaneIndex().map(String.init) ?? "none"))")
                    if let bar = descendants(of: window.contentView!, named: "FindBar").first {
                        check(bar.frame.width > 100, "find bar still visibly sized (\(bar.frame.size))")
                    }
                },
            ])
        }
    }

    /// T85 — hot exit: quitting stashes the whole session (unsaved buffers included)
    /// and never prompts about dirty tabs; the next launch restores everything,
    /// including the unsaved content, exactly as it was. Closing a *window* (⌘W/⌘⇧W)
    /// still prompts per dirty tab — hot exit is a quit behaviour, matching Sublime.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        sessionManager?.saveNow()
        return .terminateNow
    }

    /// Drop closed windows so the app doesn't accumulate every controller ever opened.
    @objc private func windowWillClose(_ note: Notification) {
        guard let closing = note.object as? NSWindow else { return }
        // Deallocate after AppKit finishes unwinding the close.
        DispatchQueue.main.async { [weak self] in
            self?.controllers.removeAll { $0.window === closing }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc func newWindow(_ sender: Any?) {
        let controller = MainWindowController()
        controllers.append(controller)
        controller.showWindow(nil)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let controller = MainWindowController()
        controllers.append(controller)
        controller.showWindow(nil)
        controller.open(url: URL(fileURLWithPath: filename))
        return true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.mainMenu = makeMainMenu()
app.activate(ignoringOtherApps: true)
app.run()
