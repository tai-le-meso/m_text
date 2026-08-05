import AppKit
import MTextCore

/// Env-gated trace of the keyboard path — `MTEXT_INPUT_DEBUG=1 make debug`.
///
/// Exists because the `MTEXT_SMOKE_TEST` harness **cannot reproduce a key window**: a
/// process launched from a terminal is not frontmost, so macOS refuses it key status and
/// never routes real key events to it. The harness therefore injects `NSEvent`s directly,
/// which proves the editor *handles* keys but says nothing about whether the OS ever
/// *delivers* them. "Typing does nothing" lives precisely in that gap.
///
/// The trace answers, in order, the only questions that matter when keys go missing:
///
/// 1. Does the key event reach the application at all? (the local monitor)
/// 2. Is the app active, the window key, and who holds first responder?
/// 3. Does it reach `EditorView.keyDown`, or is something upstream eating it?
/// 4. Does the keymap swallow it (`.command` with no handler, or `.pendingChord`)?
/// 5. Does `insertText` run, and does the document's generation actually move?
///
/// Whichever line stops appearing is the layer that broke. Unlike `LayoutDiagnostics`,
/// this one *does* have call sites — they are all `guard isEnabled` one-liners, so the
/// feature costs a boolean check when it is off.
public enum InputDiagnostics {

    public static let isEnabled = ProcessInfo.processInfo.environment["MTEXT_INPUT_DEBUG"] != nil

    public static func log(_ message: String) {
        guard isEnabled else { return }
        print("[input] \(message)")
    }

    /// Installs an application-level key-down monitor. Logs every key the app receives
    /// *before* the responder chain gets it, so a keystroke that never reaches the editor
    /// is still visible here — that difference is the whole point.
    public static func installMonitor() {
        guard isEnabled else { return }
        setvbuf(stdout, nil, _IONBF, 0)
        print("[input] tracing enabled — type in the window, then quit and send this log")
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first
            let responder = window?.firstResponder
            log("""
                key \(String(reflecting: event.charactersIgnoringModifiers ?? "")) \
                code=\(event.keyCode) mods=\(describe(event.modifierFlags)) | \
                appActive=\(NSApp.isActive) keyWindow=\(NSApp.keyWindow != nil) \
                windowIsKey=\(window?.isKeyWindow ?? false) \
                firstResponder=\(responder.map { String(describing: type(of: $0)) } ?? "nil")
                """)
            return event
        }
    }

    static func describe(_ flags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if flags.contains(.command) { parts.append("cmd") }
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option) { parts.append("opt") }
        if flags.contains(.shift) { parts.append("shift") }
        return parts.isEmpty ? "none" : parts.joined(separator: "+")
    }
}
