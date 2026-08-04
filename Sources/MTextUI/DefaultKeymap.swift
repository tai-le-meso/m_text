import Foundation

/// The built-in default chord bindings (T76), written as `.sublime-keymap`-format JSON
/// so it parses through the exact same `KeymapParser` a user's own override file does.
/// Embedded as a string literal rather than a bundled resource file, matching this
/// project's existing convention for built-in syntax grammars (see the `Grammars*.swift`
/// files) — no `Bundle.module` resource wiring to get wrong.
///
/// This is deliberately a **small, illustrative starter set**, not a claim of exact
/// parity with Sublime's real default keymap (whose precise Mac chord bindings aren't
/// verified here). Every binding below is a genuinely new two-key chord bound to a
/// command that has **no existing single-key menu shortcut** in `MainMenu.swift` today
/// (Show Line Numbers, Show Invisibles, and three of the Convert Case / Sort submenu
/// items all ship with an empty `keyEquivalent`) — chosen by hand-auditing every
/// `keyEquivalent` already in `MainMenu.swift` for both keys of each chord, since AppKit
/// tries menu key equivalents before an event ever reaches `EditorView.keyDown(with:)`
/// (see `KeymapEngine`'s doc comment): a chord whose second key collides with an
/// existing plain shortcut would silently never complete (that shortcut fires instead).
/// All five chords share the "cmd+k" prefix, the same convention Sublime itself uses —
/// plain ⌘K has no menu binding of its own. `cmd+k, cmd+b` is the literal example this
/// project's own task list names, and now that T82 has added a real sidebar, it carries
/// its real Sublime meaning (toggle the sidebar) rather than the placeholder
/// "toggle_line_numbers" it stood in for before one existed.
enum DefaultKeymap {
    static let json = """
    [
        { "keys": ["cmd+k", "cmd+b"], "command": "toggle_sidebar" },
        { "keys": ["cmd+k", "cmd+i"], "command": "toggle_invisibles" },
        { "keys": ["cmd+k", "cmd+u"], "command": "uppercase" },
        { "keys": ["cmd+k", "cmd+r"], "command": "reverse_lines" },
        { "keys": ["cmd+k", "cmd+y"], "command": "swap_case" }
    ]
    """
}
