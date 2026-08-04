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

            run([
                { controller.splitViewRight(nil) },
                { foldingCheck() },
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
