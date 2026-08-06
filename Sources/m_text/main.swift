import AppKit
import MTextUI

// NSApplication bootstrap without storyboards, nibs, or Xcode.

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [MainWindowController] = []
    private var sessionManager: SessionManager!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before any window is restored, so the first editor is created already
        // themed rather than being built light and repainted a moment later.
        AppearanceController.shared.start()
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
        InputDiagnostics.installMonitor()
        InputDiagnostics.dumpWindowRender()
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

            /// The most basic property of a text editor, and the one nothing else here
            /// covered: a real key event, delivered to the window the way the OS delivers
            /// it, changes the document. Every other check drives the editor through
            /// method calls, which skips `keyDown` -> keymap -> `interpretKeyEvents`
            /// entirely — so a break anywhere along that path was invisible.
            func typingCheck() {
                let hit = controller.smokeTestViewUnderEditorCentre()
                check(hit == "EditorView", "a click in the editor's middle reaches it (hit \(hit))")
                // Before forcing anything: whoever holds focus as the app comes up is who
                // receives your keystrokes. Every other check here calls
                // `smokeTestFocusEditor()` first, which would paper over an app that opens
                // with focus somewhere the text can never reach.
                // NB: this harness can never hold a *key* window — a process launched from a
                // terminal isn't frontmost, so macOS refuses key status and the OS never
                // routes real key events here. That is why these checks inject events
                // directly, and why they cannot see a fault in delivery itself. Use
                // `MTEXT_INPUT_DEBUG=1` for that (see `InputDiagnostics`).
                check(window.canBecomeKey, "the window is allowed to become key")
                check(controller.smokeTestFocusEditor(), "the focused editor takes first responder")
                controller.smokeTestEditorText = ""

                func press(_ characters: String, keyCode: UInt16) {
                    guard let event = NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil,
                        characters: characters, charactersIgnoringModifiers: characters,
                        isARepeat: false, keyCode: keyCode)
                    else { return }
                    // Through NSApp, not the window: NSApplication offers every key-down to
                    // the main menu's `performKeyEquivalent` *before* the window ever sees
                    // it. A menu item whose key equivalent matches ordinary typing swallows
                    // the keystroke there, and a window-level injection cannot see that.
                    NSApp.sendEvent(event)
                }

                press("h", keyCode: 4)
                press("i", keyCode: 34)
                check(controller.smokeTestEditorText == "hi",
                      "typing inserts text (got \(String(reflecting: controller.smokeTestEditorText)))")

                press("\r", keyCode: 36)
                press("x", keyCode: 7)
                check(controller.smokeTestEditorText == "hi\nx",
                      "Return and a further key work (got \(String(reflecting: controller.smokeTestEditorText)))")

                press("\u{8}", keyCode: 51) // delete
                check(controller.smokeTestEditorText == "hi\n",
                      "Delete removes a character (got \(String(reflecting: controller.smokeTestEditorText)))")
            }

            /// Per-edit work that scales with document size — the diff gutter's whole-buffer
            /// LCS, spell check, the minimap, wrap — turns "slow" into "the app does not
            /// respond", which is indistinguishable from broken. Small synthetic buffers
            /// hide all of it, so this types into a realistically large one.
            func typingLatencyCheck() {
                controller.smokeTestFocusEditor()
                controller.smokeTestEditorText =
                    String(repeating: "let value = computeSomething(from: input, with: options)\n",
                           count: 20_000)
                func timePerKey() -> Double {
                    let started = ProcessInfo.processInfo.systemUptime
                    let keystrokes = 20
                    for _ in 0..<keystrokes {
                        guard let event = NSEvent.keyEvent(
                            with: .keyDown, location: .zero, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil,
                            characters: "z", charactersIgnoringModifiers: "z",
                            isARepeat: false, keyCode: 6)
                        else { return -1 }
                        window.sendEvent(event)
                    }
                    return (ProcessInfo.processInfo.systemUptime - started) / Double(keystrokes) * 1000
                }
                // Discard the first run: the completion caches scan once on first use by
                // design, and that one scan is not what this is guarding against.
                _ = timePerKey()
                let perKey = timePerKey()
                // The regression was 79 ms/key in release and 154 in debug — a keystroke
                // stalling the main thread outright. The budget is deliberately far below
                // that and above where a debug build sits (~12 ms), so it catches a return
                // of per-keystroke O(buffer) work without failing on ordinary noise.
                check(perKey < 30,
                      String(format: "typing stays responsive in a 20k-line file (%.1f ms/key)", perKey))
            }

            /// ⌘T, then typing into what it produced. Reported as "can't create new tabs and
            /// can't enter any text" — and nothing here covered tab creation at all, only
            /// tabs that already existed. Runs several times because the restored session
            /// carries ten tabs, so anything that degrades as the tab bar fills up (the bar
            /// scrolling, a container not being installed) shows up as a later iteration
            /// failing rather than the first.
            func newTabCheck() {
                for round in 1...4 {
                    let before = controller.smokeTestTabCount
                    controller.newTab(nil)
                    let after = controller.smokeTestTabCount
                    check(after == before + 1,
                          "⌘T adds a tab, round \(round) (\(before) -> \(after))")

                    controller.window?.layoutIfNeeded()
                    check(controller.smokeTestActiveEditorIsUsable,
                          "the new tab's editor is on screen and usable, round \(round) "
                          + "(\(controller.smokeTestActiveEditorVisibleRect))")

                    // The new tab must be the one that receives typing — a tab that is added
                    // but not activated looks identical to one that was never created.
                    controller.smokeTestFocusEditor()
                    controller.smokeTestEditorText = ""
                    guard let event = NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil,
                        characters: "q", charactersIgnoringModifiers: "q",
                        isARepeat: false, keyCode: 12)
                    else { return }
                    NSApp.sendEvent(event)
                    check(controller.smokeTestEditorText == "q",
                          "typing lands in the newly created tab, round \(round) "
                          + "(got \(String(reflecting: controller.smokeTestEditorText)))")
                }
            }

            /// What you *see* must be the tab the controller routes keys to. Every tab's
            /// container is stacked in the same place with the same constraints, so if two
            /// are un-hidden the topmost one wins the screen while typing goes to the active
            /// one — the document changes and the display does not, which is precisely the
            /// reported symptom. Checked on the restored session, which carries ten tabs.
            func tabVisibilityCheck(_ when: String) {
                let visible = controller.smokeTestVisibleContainerCount
                check(visible == 1, "exactly one tab container is visible \(when) (got \(visible))")
                check(controller.smokeTestActiveContainerIsVisible,
                      "and it is the active tab's \(when)")
            }

            /// Does text actually appear? Nothing else here asks that. Geometry checks and
            /// "draw was called" traces both pass while the view paints nothing, which is
            /// precisely the reported failure: keystrokes reach the document, `draw` runs,
            /// rows are counted, the caret advances, and the pane stays empty.
            func renderCheck() {
                controller.smokeTestSetWordWrap(false)
                controller.smokeTestEditorText = ""
                let blank = controller.smokeTestRenderedInkPixels()

                controller.smokeTestEditorText = String(repeating: "HELLO WORLD 12345\n", count: 30)
                let inked = controller.smokeTestRenderedInkPixels()

                check(blank >= 0 && inked >= 0, "could render the editor into a bitmap")
                check(inked > blank,
                      "text actually paints pixels (blank \(blank) -> with text \(inked))")

                // Guards the *measurement*: if the editor inks but a window-level snapshot
                // of the same moment comes back empty, then `cacheDisplay` is failing to
                // composite layer-backed descendants and no "the window is blank"
                // conclusion may be drawn from such a snapshot.
                let windowInk = controller.smokeTestWindowInkPixels()
                check(windowInk > 0,
                      "a window-level snapshot sees that same text (\(windowInk) ink pixels) "
                      + "— if this is 0 while the editor inks, the capture is unreliable")

                // The measurement above deliberately turned word wrap OFF first, which is
                // exactly how a wrap-only drawing fault stays invisible to it. T28 added a
                // clip in `drawText` that only applies while wrapping, so the wrapped case
                // has to be measured on its own.
                // Lines long enough to actually wrap — short ones never reach the clip.
                controller.smokeTestEditorText =
                    String(repeating: "the quick brown fox jumps over the lazy dog ", count: 40)
                    + "\n"
                let longUnwrapped = controller.smokeTestRenderedInkPixels()
                controller.smokeTestSetWordWrap(true)
                let longWrapped = controller.smokeTestRenderedInkPixels()
                controller.smokeTestSetWordWrap(false)
                check(longWrapped > blank,
                      "a genuinely wrapping line still paints (blank \(blank), "
                      + "unwrapped \(longUnwrapped), wrapped \(longWrapped))")
            }

            /// No view may paint outside itself. The blank-window bug was exactly this: the
            /// minimap, collapsed to zero width, kept a full-size unclipped backing layer
            /// that covered the editor and the tab bar. Every view-level check passed while
            /// it happened, so this is the one that has to exist.
            func layerContainmentCheck(_ when: String) {
                let escaping = controller.smokeTestLayerEscapingItsView()
                check(escaping == nil, "no layer paints outside its view \(when)"
                      + (escaping.map { " — \($0)" } ?? ""))
            }

            /// Branding: picking an appearance must actually repaint the editor, and must do
            /// so for tabs that already exist. The failure mode this guards is specific —
            /// `LayoutCache` bakes colours into each shaped `CTLine`, so an appearance switch
            /// that forgets to invalidate leaves already-drawn lines in the old palette while
            /// new ones use the new one. Colours are read back through the same accessors
            /// drawing uses, not from the token table, so agreeing with itself isn't enough.
            func appearanceCheck() {
                let controllerRef = AppearanceController.shared
                check(controllerRef.smokeTestRegisteredEditorCount > 0,
                      "editors are registered for theming "
                      + "(got \(controllerRef.smokeTestRegisteredEditorCount))")

                controllerRef.setPreference(.light)
                let lightBG = controller.smokeTestEditorBackgroundHex
                let lightFG = controller.smokeTestEditorForegroundHex
                controllerRef.setPreference(.dark)
                let darkBG = controller.smokeTestEditorBackgroundHex
                let darkFG = controller.smokeTestEditorForegroundHex

                check(lightBG != darkBG,
                      "switching appearance repaints the editor (\(lightBG) -> \(darkBG))")
                check(lightBG.uppercased() == "#F5F5F9" && darkBG.uppercased() == "#0D0C13",
                      "and lands on the brand surfaces (light \(lightBG), dark \(darkBG))")
                check(lightFG.uppercased() == "#15131E" && darkFG.uppercased() == "#F3F2F9",
                      "with the brand text colours (light \(lightFG), dark \(darkFG))")

                controllerRef.setPreference(.light)
                check(controller.smokeTestEditorBackgroundHex == lightBG,
                      "switching back restores the light surface exactly")

                // The colours above would still swap if shaped lines were left cached — and
                // those bake their foreground in, so the buffer would keep the old palette
                // while newly shaped lines used the new one. Assert the cache is actually
                // dropped, which is the part that can silently regress.
                controller.smokeTestEditorText = String(repeating: "let brand = 1\n", count: 40)
                controller.smokeTestForceLayout()
                let cachedBefore = controller.smokeTestCachedLineCount
                check(cachedBefore > 0, "lines are cached before the switch (got \(cachedBefore))")
                controllerRef.setPreference(.dark)
                check(controller.smokeTestCachedLineCount == 0,
                      "an appearance switch drops every shaped line "
                      + "(got \(controller.smokeTestCachedLineCount))")

                controllerRef.setPreference(.system)
                check(controllerRef.preference == .system,
                      "system is a state of its own, not a synonym for light or dark")
            }

            /// The appearance switch has to be *reachable*, not merely implemented. Nothing
            /// else here looks at the menu bar, so a command that exists in code but never
            /// reaches a menu — or reaches it disabled — looks exactly like a missing feature.
            func appearanceMenuCheck() {
                guard let view = NSApp.mainMenu?.items
                    .first(where: { $0.submenu?.title == "View" })?.submenu else {
                    check(false, "there is a View menu")
                    return
                }
                guard let appearance = view.items
                    .first(where: { $0.title == "Appearance" })?.submenu else {
                    check(false, "View contains an Appearance submenu")
                    return
                }
                // Delegates populate/tick on open; nothing has opened it yet.
                appearance.delegate?.menuNeedsUpdate?(appearance)
                let titles = appearance.items.map(\.title)
                check(titles == ["System", "Light", "Dark"],
                      "Appearance offers all three states (got \(titles))")
                let enabled = appearance.items.filter {
                    $0.target != nil && $0.action != nil && $0.isEnabled
                }
                check(enabled.count == 3,
                      "and every one is enabled and wired (got \(enabled.count))")
                check(appearance.items.filter { $0.state == .on }.count == 1,
                      "with exactly one ticked as current")

                // The control in the status bar. The menu item existed, was enabled and
                // correctly ticked, and was still never found — so "the command exists" is
                // not the property worth asserting on its own.
                check(controller.smokeTestAppearanceControlIsVisible,
                      "the status bar shows an appearance control")
                AppearanceController.shared.setPreference(.dark)
                check(controller.smokeTestAppearanceControlTitle == "Dark",
                      "which follows changes made elsewhere "
                      + "(got \(controller.smokeTestAppearanceControlTitle))")
                AppearanceController.shared.setPreference(.system)
                check(controller.smokeTestAppearanceControlTitle == "System",
                      "in both directions (got \(controller.smokeTestAppearanceControlTitle))")
            }

            /// Typing into the Command Palette has to filter it. Reported as the palette
            /// opening but not searching — and nothing here had ever sent a keystroke to
            /// anything other than an editor, so a panel that shows correctly while
            /// swallowing every key was invisible to the whole suite.
            func commandPaletteTypingCheck() {
                controller.showCommandPalette(nil)
                let palette = controller.smokeTestPalette
                let all = palette.smokeTestItemCount
                check(all > 10, "the palette lists the menu's commands (got \(all))")
                // A borderless panel that cannot become key never receives a keystroke.
                check(palette.smokeTestPanelCanBecomeKey, "its panel can become key")
                check(palette.smokeTestFieldHasFocus, "and its search field holds focus")

                for character in "appear" {
                    guard let event = NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: 0, context: nil,
                        characters: String(character),
                        charactersIgnoringModifiers: String(character),
                        isARepeat: false, keyCode: 0)
                    else { return }
                    NSApp.sendEvent(event)
                }
                check(palette.smokeTestQuery == "appear",
                      "typing reaches the field (got \(String(reflecting: palette.smokeTestQuery)))")
                let filtered = palette.smokeTestItemCount
                check(filtered > 0 && filtered < all,
                      "and filters the list (\(all) -> \(filtered))")

                // Put focus back. Now that the panel genuinely takes key status, leaving it
                // open would starve every later check of keystrokes — which is itself proof
                // the fix works.
                palette.dismiss()
                window.makeKeyAndOrderFront(nil)
                controller.smokeTestFocusEditor()
            }

            run([
                { layerContainmentCheck("at launch") },
                { commandPaletteTypingCheck() },
                { appearanceMenuCheck() },
                { appearanceCheck() },
                { renderCheck() },
                { tabVisibilityCheck("on the restored session") },
                { newTabCheck() },
                { tabVisibilityCheck("after creating tabs") },
                { controller.splitViewRight(nil) },
                { typingCheck() },
                { typingLatencyCheck() },
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

                // The reported failure was "it worked, then stopped", so typing is checked
                // a second time with every other feature's state left behind — a build run,
                // phantoms set, spell check on, folds made, and the find bar open.
                { typingCheck() },
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
