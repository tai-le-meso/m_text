import AppKit
import MTextCore

// T94 — recording the command stream and replaying it.
//
// Recording taps the two places every editing action already funnels through:
// `insertText` for typed text and `doCommand(by:)` for everything else. Nothing else needs
// to know it is being recorded, which is what keeps the feature from spreading into every
// command.
extension EditorView {

    /// One recorder for the whole app, not one per view: a macro recorded in one tab is
    /// expected to replay in another, and recording is a modal, app-wide state — two tabs
    /// recording different macros at once has no sensible meaning.
    public static let macroRecorder = MacroRecorder()

    /// The last recorded (or loaded) macro, replayed by Playback. Also app-wide, for the
    /// same reason.
    public static var lastMacro: Macro?

    // MARK: - Recording

    /// Called from `insertText`. Guarded on `isReplayingMacro` so replay doesn't re-record
    /// what it is replaying and double the macro every run.
    func recordMacroInsert(_ characters: String) {
        guard EditorView.macroRecorder.isRecording, !isReplayingMacro else { return }
        EditorView.macroRecorder.recordInsert(characters)
    }

    /// Called from `doCommand(by:)`.
    ///
    /// Records the **selector name** (`"moveToBeginningOfLine:"`) rather than translating to
    /// Sublime's own command vocabulary. Those names are a distinct snake_case language that
    /// only partly overlaps `NSResponder`'s selectors, and inventing a mapping for every
    /// movement and deletion command would be a large table that silently drops whatever it
    /// missed. Replay accepts both: a Sublime name resolves through `KeymapCommands`, and
    /// anything else is treated as a selector — so macros recorded here are portable within
    /// this app, and macros written for Sublime replay to the extent their commands are in
    /// that table.
    func recordMacroCommand(_ selector: Selector) {
        guard EditorView.macroRecorder.isRecording, !isReplayingMacro else { return }
        // Recording the recording controls themselves would make every macro end by
        // stopping itself.
        let name = NSStringFromSelector(selector)
        guard !EditorView.macroExcludedSelectors.contains(name) else { return }
        EditorView.macroRecorder.recordCommand(name)
    }

    /// Commands that must never enter a macro: the macro controls themselves, and anything
    /// that would make replay recurse.
    static let macroExcludedSelectors: Set<String> = [
        NSStringFromSelector(#selector(EditorView.toggleMacroRecording(_:))),
        NSStringFromSelector(#selector(EditorView.playbackMacro(_:))),
    ]

    // MARK: - Commands

    /// ⌃⌘Q — start recording, or stop and keep what was captured. One toggle rather than two
    /// commands, matching Sublime, because "am I recording?" is the only state to convey.
    @objc public func toggleMacroRecording(_ sender: Any?) {
        if EditorView.macroRecorder.isRecording {
            if let macro = EditorView.macroRecorder.stop() {
                EditorView.lastMacro = macro
                onMacroStatus?("Recorded \(macro.steps.count) step\(macro.steps.count == 1 ? "" : "s")")
            } else {
                onMacroStatus?("Nothing recorded")
            }
        } else {
            EditorView.macroRecorder.start()
            onMacroStatus?("Recording macro…")
        }
    }

    /// ⌃⌘P — replay the last recorded or loaded macro.
    @objc public func playbackMacro(_ sender: Any?) {
        guard let macro = EditorView.lastMacro, !macro.isEmpty else {
            NSSound.beep()
            onMacroStatus?("No macro recorded")
            return
        }
        run(macro)
    }

    /// Runs every step. The whole replay is wrapped in one undo group where possible, so a
    /// macro that made twenty edits undoes as one action rather than twenty.
    func run(_ macro: Macro) {
        guard !isReplayingMacro else { return }   // a macro must not replay itself
        isReplayingMacro = true
        defer { isReplayingMacro = false }

        for step in macro.steps {
            if let characters = step.insertedCharacters {
                insertText(characters, replacementRange: notFoundRange)
                continue
            }
            // A Sublime command name first, then fall back to reading it as a selector —
            // see `recordMacroCommand` for why both are accepted.
            if let selector = KeymapCommands.selector(forCommand: step.command, args: nil),
               NSApp.sendAction(selector, to: nil, from: self) {
                continue
            }
            let selector = NSSelectorFromString(step.command)
            guard responds(to: selector) || NSStringFromSelector(selector).hasSuffix(":") else { continue }
            doCommand(by: selector)
        }
        onMacroStatus?("Replayed \(macro.steps.count) step\(macro.steps.count == 1 ? "" : "s")")
    }
}
