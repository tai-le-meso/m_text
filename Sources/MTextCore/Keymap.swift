import Foundation

/// One resolved keystroke within a `.sublime-keymap` binding — e.g. the "cmd+k" half of
/// `["cmd+k", "cmd+b"]`. Modeled after Sublime's own key-name vocabulary so an existing
/// `.sublime-keymap` file can mostly be dropped in as-is.
public struct KeyChord: Equatable, Hashable {

    public enum Modifier: String, CaseIterable {
        case command, control, option, shift
    }

    /// Lowercased: either a single character ("k", "p", "/") or one of the named keys
    /// recognised by `KeymapEngine` ("up", "f12", "escape", ...).
    public let key: String
    public let modifiers: Set<Modifier>

    public init(key: String, modifiers: Set<Modifier>) {
        self.key = key
        self.modifiers = modifiers
    }

    /// Parses one Sublime-style key string, e.g. `"cmd+shift+p"` or `"f12"`. Sublime
    /// also accepts `"super"` as an alias for the platform command key; accepted here
    /// too, since an imported keymap file may use either spelling. Returns `nil` for an
    /// unrecognised modifier name rather than silently dropping it — a binding with a
    /// key like `"hyper+x"` is rejected outright by `KeymapParser` instead of matching
    /// something the person who wrote it didn't intend.
    ///
    /// Can't express a literal `"+"` as the key itself: splitting on `+` turns
    /// `"cmd++"` into a trailing empty component, which fails to parse rather than
    /// being interpreted as `key: "+"`. A binding that genuinely needs the `+` key
    /// (e.g. for zoom) isn't representable today — a known gap, not a silent misparse.
    public static func parse(_ raw: String) -> KeyChord? {
        let parts = raw.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let last = parts.last, !last.isEmpty else { return nil }

        var modifiers: Set<Modifier> = []
        for part in parts.dropLast() {
            switch part {
            case "cmd", "super": modifiers.insert(.command)
            case "ctrl": modifiers.insert(.control)
            case "alt", "option": modifiers.insert(.option)
            case "shift": modifiers.insert(.shift)
            default: return nil
            }
        }
        return KeyChord(key: last, modifiers: modifiers)
    }
}

/// One `.sublime-keymap` entry: a one- or two-key sequence bound to a command name plus
/// optional arguments.
public struct KeymapEntry {
    public let keys: [KeyChord]
    public let command: String
    public let args: [String: Any]?

    public init(keys: [KeyChord], command: String, args: [String: Any]?) {
        self.keys = keys
        self.command = command
        self.args = args
    }
}

/// Parses `.sublime-keymap` files — a JSON array of `{"keys": [...], "command": "...",
/// "args": {...}}` objects.
///
/// Two deliberate simplifications, not bugs:
/// - Sublime's `"context"` conditional array (used to scope a binding to, say, "only
///   while the auto-complete popup is showing") is read but discarded — every parsed
///   entry is treated as unconditionally active. Full context-predicate evaluation would
///   need hooks into every subsystem a predicate can query (selection state, popup
///   visibility, panel focus, ...), which is out of scope here.
/// - A malformed individual entry (missing `"keys"`/`"command"`, or a key string with an
///   unrecognised modifier) is skipped rather than failing the whole file — one typo in
///   a large keymap shouldn't silently disable every other binding in it.
public enum KeymapParser {

    public enum ParseError: Error { case notAnArray, notUTF8 }

    public static func parse(data: Data) throws -> [KeymapEntry] {
        guard let text = String(data: data, encoding: .utf8) else { throw ParseError.notUTF8 }
        let stripped = Data(stripLineComments(text).utf8)
        let json = try JSONSerialization.jsonObject(with: stripped)
        guard let array = json as? [[String: Any]] else { throw ParseError.notAnArray }

        var entries: [KeymapEntry] = []
        for object in array {
            guard let rawKeys = object["keys"] as? [String], !rawKeys.isEmpty,
                  let command = object["command"] as? String
            else { continue }

            let chords = rawKeys.compactMap(KeyChord.parse)
            guard chords.count == rawKeys.count else { continue } // any unparseable key voids the entry

            entries.append(KeymapEntry(keys: chords, command: command, args: object["args"] as? [String: Any]))
        }
        return entries
    }

    /// Strips `//`-style line comments outside string literals — real `.sublime-keymap`
    /// files commonly include them even though they aren't valid JSON. Tracks whether
    /// it's inside a quoted string (respecting `\"` escapes) so a `//` that happens to
    /// appear inside a string value (a URL in an argument, say) isn't mistaken for the
    /// start of a comment.
    public static func stripLineComments(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var inString = false
        var escaped = false
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if inString {
                result.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                index += 1
                continue
            }
            if character == "\"" {
                inString = true
                result.append(character)
                index += 1
                continue
            }
            if character == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                while index < characters.count, characters[index] != "\n" { index += 1 }
                continue
            }
            result.append(character)
            index += 1
        }
        return result
    }
}
