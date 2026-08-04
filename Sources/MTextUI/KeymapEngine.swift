import AppKit
import MTextCore

/// Turns key-down `NSEvent`s into keymap commands, one per `EditorView` (see
/// `EditorView.keymapEngine`). A single-key-with-modifiers binding resolves as soon as
/// its key is pressed; a two-key chord (⌘K ⌘B) waits for the second keystroke within
/// `chordTimeout`, matching Sublime's own chord behavior. `context` predicates aren't
/// evaluated (see `KeymapParser`'s doc comment) — every loaded binding is always active.
///
/// **Known limitations**:
/// - AppKit tries the app's `NSMenu` key equivalents *before* an event ever reaches
///   `EditorView.keyDown(with:)` (see `MainMenu.swift`). Any key in a binding — first or
///   otherwise — that collides with an existing plain menu shortcut will fire that menu
///   item instead of ever reaching this class. The bindings shipped in `DefaultKeymap`
///   were chosen specifically to avoid this (see its doc comment); a user's own override
///   file can still run into it for keys already claimed by a menu item, and there's no
///   detection or warning for that today.
/// - A binding can permanently "lose" to a longer one sharing its prefix. If a keymap
///   defines both `["cmd+k"]` and `["cmd+k", "cmd+x"]`, pressing plain ⌘K always resolves
///   to `.pendingChord` (never `.command`, even after `chordTimeout` elapses with no
///   second key) — matching happens only on the next keystroke, there's no timer-driven
///   flush of an unresolved shorter match. Avoid defining a standalone binding that is
///   also the prefix of a longer one.
public final class KeymapEngine {

    public enum MatchResult {
        /// A binding resolved completely; dispatch `command`/`args`.
        case command(String, [String: Any]?)
        /// The event matched the first key (or keys) of some longer binding; nothing
        /// dispatches yet — swallow the keystroke and wait for the next one.
        case pendingChord
        /// No loaded binding starts with this key (given whatever's already pending).
        case noMatch
    }

    /// How long a partial chord (just the first key of a longer binding) stays "live"
    /// before resetting — matches Sublime's own default chord timeout.
    public static let chordTimeout: TimeInterval = 1.0

    private var bindings: [KeymapEntry] = []
    private var pending: [KeyChord] = []
    private var pendingDeadline: Date?

    public init() {}

    /// User bindings are matched *before* built-in ones: for a given key sequence, the
    /// first matching entry wins, so a user override shadows the shipped default rather
    /// than running alongside it.
    public func load(userEntries: [KeymapEntry], defaultEntries: [KeymapEntry]) {
        bindings = userEntries + defaultEntries
        resetPending()
    }

    public func resetPending() {
        pending = []
        pendingDeadline = nil
    }

    public func match(_ event: NSEvent) -> MatchResult {
        if let pendingDeadline, Date() > pendingDeadline {
            resetPending()
        }
        guard let chord = KeymapEngine.chord(for: event) else {
            resetPending()
            return .noMatch
        }

        let candidate = pending + [chord]
        let matchingPrefix = bindings.filter { $0.keys.count >= candidate.count &&
                                               Array($0.keys.prefix(candidate.count)) == candidate }
        guard !matchingPrefix.isEmpty else {
            resetPending()
            return .noMatch
        }

        // Dispatch immediately only when nothing loaded could still extend this further
        // — otherwise wait for the next keystroke, so a chord and a same-prefixed
        // shorter binding don't race (see the doc comment on `DefaultKeymap` for how the
        // shipped bindings avoid this ambiguity in the first place).
        if let exact = matchingPrefix.first(where: { $0.keys.count == candidate.count }),
           !matchingPrefix.contains(where: { $0.keys.count > candidate.count }) {
            resetPending()
            return .command(exact.command, exact.args)
        }

        pending = candidate
        pendingDeadline = Date().addingTimeInterval(KeymapEngine.chordTimeout)
        return .pendingChord
    }

    // MARK: - Event → KeyChord

    private static func chord(for event: NSEvent) -> KeyChord? {
        guard let characters = event.charactersIgnoringModifiers,
              let scalar = characters.unicodeScalars.first,
              characters.unicodeScalars.count == 1
        else { return nil }

        let key = namedKey(forScalarValue: scalar.value) ?? String(characters).lowercased()
        guard !key.isEmpty else { return nil }
        return KeyChord(key: key, modifiers: modifiers(for: event))
    }

    private static func modifiers(for event: NSEvent) -> Set<KeyChord.Modifier> {
        var result: Set<KeyChord.Modifier> = []
        let flags = event.modifierFlags
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        return result
    }

    /// `NSXXXFunctionKey` constants surface here as single Unicode scalars in
    /// `charactersIgnoringModifiers` — the same idiom `CommandRegistry.displayKey`
    /// decodes in the other direction for menu-item display strings.
    private static func namedKey(forScalarValue value: UInt32) -> String? {
        switch value {
        case UInt32(NSUpArrowFunctionKey): return "up"
        case UInt32(NSDownArrowFunctionKey): return "down"
        case UInt32(NSLeftArrowFunctionKey): return "left"
        case UInt32(NSRightArrowFunctionKey): return "right"
        case UInt32(NSDeleteFunctionKey): return "forward_delete"
        case UInt32(NSF1FunctionKey) ... UInt32(NSF35FunctionKey):
            return "f\(Int(value) - Int(NSF1FunctionKey) + 1)"
        case 0x1B: return "escape"
        case 0x09: return "tab"
        case 0x0D, 0x03: return "enter"
        case 0x20: return "space"
        case 0x7F: return "backspace"
        default: return nil
        }
    }
}
