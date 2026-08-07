import Foundation

/// One value out of a settings file.
///
/// Modelled explicitly rather than passing `[String: Any]` around, for two reasons: JSON
/// `true` and JSON `1` both arrive from `JSONSerialization` as `NSNumber` and are only
/// distinguishable by a `CFBooleanGetTypeID` check (done once, here, in `init(json:)`
/// instead of at every read site), and an `Equatable` value type lets a layer reload
/// cheaply answer "did anything actually change?" before rebuilding every editor.
public enum SettingValue: Equatable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case intArray([Int])
    case stringArray([String])

    /// nil for JSON types this app has no setting for (nested objects, null, mixed
    /// arrays) — an unknown *shape* is skipped exactly like an unknown *key*, so a
    /// settings file written for a newer version still loads everything else.
    init?(json: Any) {
        if let number = json as? NSNumber {
            // Must precede the `Int`/`Double` casts: an NSNumber wrapping a bool would
            // otherwise silently read as 0/1.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if String(cString: number.objCType) == "d" || String(cString: number.objCType) == "f" {
                self = .double(number.doubleValue)
            } else {
                self = .int(number.intValue)
            }
            return
        }
        if let text = json as? String { self = .string(text); return }
        if let array = json as? [Any] {
            let ints = array.compactMap { ($0 as? NSNumber).map { $0.intValue } }
            if ints.count == array.count, !array.isEmpty { self = .intArray(ints); return }
            let strings = array.compactMap { $0 as? String }
            if strings.count == array.count { self = .stringArray(strings); return }
            return nil
        }
        return nil
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let value): return value
        // Tolerated because real Sublime settings files use both spellings for the same
        // flag depending on their vintage.
        case .int(let value): return value != 0
        default: return nil
        }
    }

    public var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value): return Int(value)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let value): return value
        case .int(let value): return Double(value)
        default: return nil
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intArrayValue: [Int]? {
        if case .intArray(let value) = self { return value }
        return nil
    }
}

/// One file's — or one project's — worth of settings, before layering.
public struct SettingsLayer: Equatable {
    /// Where this came from, for diagnostics only (`"Default"`, `"User"`,
    /// `"Syntax: Swift"`, `"Project"`, `"View"`).
    public let name: String
    public let values: [String: SettingValue]

    public init(name: String, values: [String: SettingValue]) {
        self.name = name
        self.values = values
    }

    public static let empty = SettingsLayer(name: "empty", values: [:])
}

/// Parses `.sublime-settings` files: a JSON object, tolerating `//` line comments.
public enum SettingsParser {

    public enum ParseError: Error, Equatable { case notUTF8, notAnObject }

    public static func parse(data: Data, name: String) throws -> SettingsLayer {
        guard let text = String(data: data, encoding: .utf8) else { throw ParseError.notUTF8 }
        return try parse(text: text, name: name)
    }

    /// Reuses `KeymapParser.stripLineComments` rather than carrying a third copy of the
    /// same scan — `.sublime-keymap`, `.sublime-project` and `.sublime-settings` files
    /// all conventionally contain `//` comments despite none of them being strict JSON.
    public static func parse(text: String, name: String) throws -> SettingsLayer {
        let stripped = Data(KeymapParser.stripLineComments(text).utf8)
        let json = try JSONSerialization.jsonObject(with: stripped)
        guard let object = json as? [String: Any] else { throw ParseError.notAnObject }

        var values: [String: SettingValue] = [:]
        for (key, raw) in object {
            // Unrepresentable values are skipped, not fatal: one setting this build
            // doesn't understand must not cost the user the rest of the file.
            if let value = SettingValue(json: raw) { values[key] = value }
        }
        return SettingsLayer(name: name, values: values)
    }
}

/// The settings actually in force for one editor, after layering.
///
/// A flat struct of resolved values rather than a live query object: every consumer is a
/// view that needs concrete numbers to lay out with, and being `Equatable` means a
/// file-watch reload can skip the work entirely when nothing that matters changed
/// (editing a comment in the user file, or touching a key this build ignores).
public struct EditorSettings: Equatable {
    public var fontFace: String?
    public var fontSize: Double
    public var tabSize: Int
    public var translateTabsToSpaces: Bool
    public var lineNumbers: Bool
    public var drawWhiteSpace: Bool
    public var highlightLine: Bool
    public var rulers: [Int]
    public var colorScheme: String?
    /// T90 — whether the completion list opens on its own as you type. Off still leaves
    /// ⌃Space working, matching Sublime: disabling the automatic popup is a different
    /// preference from not wanting completion at all.
    public var autoComplete: Bool
    /// T28 — wrap long lines instead of scrolling horizontally.
    public var wordWrap: Bool
    /// Columns to wrap at. 0 means "the window width", which is the common case; a fixed
    /// number is for people who wrap to a ruler.
    public var wrapWidth: Int
    /// Whether m_text may check GitHub for a newer release in the background.
    ///
    /// **Off by default, and the only thing in this app that touches the network.** The
    /// project is offline by default; turning this on is the user opting in. Picking
    /// *Check for Updates…* by hand works regardless — that is an explicit request rather
    /// than background traffic.
    public var checkForUpdates: Bool
    /// T93 — the downsampled overview strip beside the editor.
    public var minimap: Bool
    /// T101 — spell check comments, strings and prose.
    public var spellCheck: Bool

    /// What one press of Tab inserts (and what indent/outdent shift by). Tabs mode always
    /// inserts a single `\t` regardless of `tab_size` — the width of a tab is a rendering
    /// question, not a how-many-characters-to-insert one.
    public var indentUnit: String {
        translateTabsToSpaces ? String(repeating: " ", count: max(1, tabSize)) : "\t"
    }
}

/// Resolves an ordered stack of layers into `EditorSettings`.
///
/// Precedence runs lowest to highest exactly as T86 specifies —
/// **default → user → syntax → project → view** — with each layer overriding only the
/// keys it actually mentions. That per-key granularity is the whole point: setting
/// `tab_size` for Makefiles must not also reset that syntax's font back to the default.
public enum SettingsResolver {

    /// Built-in defaults. The single source of truth for what ships out of the box —
    /// `defaultFileText` below is the documented, human-readable rendering of exactly
    /// these values, and the two are checked against each other in tests so the file a
    /// user reads can't drift from the values actually applied.
    public static let defaults: [String: SettingValue] = [
        "font_size": .double(13),
        "tab_size": .int(4),
        "translate_tabs_to_spaces": .bool(true),
        "line_numbers": .bool(true),
        "draw_white_space": .bool(false),
        "highlight_line": .bool(true),
        "rulers": .intArray([]),
        "auto_complete": .bool(true),
        "word_wrap": .bool(false),
        "wrap_width": .int(0),
        "minimap": .bool(false),
        "spell_check": .bool(false),
        "check_for_updates": .bool(false),
    ]

    public static var defaultLayer: SettingsLayer {
        SettingsLayer(name: "Default", values: defaults)
    }

    /// The read-only left-hand pane of "Preferences: Settings" — every shipped default
    /// with a comment explaining it, in the same `.sublime-settings` syntax the user's
    /// own file uses, so it doubles as copy-paste documentation.
    ///
    /// `SettingsTests` parses this and asserts it resolves identically to `defaults`, so
    /// this file and the values actually applied cannot drift apart.
    public static let defaultFileText = """
    // m_text default settings.
    //
    // This file is read-only and is overwritten on every launch. To change a setting,
    // copy the line into your own settings file (the other pane) and edit it there —
    // Preferences: Settings opens the two side by side.
    //
    // Settings are layered, each overriding only the keys it names:
    //     Default  ->  User  ->  Syntax  ->  Project  ->  View
    //
    // A syntax-specific file lives next to your user file and is named after the syntax,
    // e.g. "Makefile.sublime-settings" (handy for "translate_tabs_to_spaces": false).
    // Project settings go in the "settings" object of a .sublime-project file.
    {
        // Font family for the editor. Omitted by default, which means the system
        // monospaced font. Example: "Menlo".
        // "font_face": "Menlo",

        // Font size in points.
        "font_size": 13,

        // Width of a tab, in spaces.
        "tab_size": 4,

        // Insert spaces instead of a tab character when Tab is pressed.
        "translate_tabs_to_spaces": true,

        // Show the line-number gutter.
        "line_numbers": true,

        // Render spaces, tabs and line endings as visible glyphs. Also accepts the
        // Sublime spellings "none" / "selection" / "all"; anything but "none" is on.
        "draw_white_space": false,

        // Tint the line the caret is on.
        "highlight_line": true,

        // Vertical ruler columns, e.g. [80] or [80, 120]. Empty for none.
        "rulers": [],

        // Pop the completion list up automatically while typing. With this off, Control-Space
        // still opens it on demand.
        "auto_complete": true,

        // Check GitHub for a newer m_text once a day. Off by default: this is the only
        // setting that makes the app use the network at all.
        "check_for_updates": false,

        // Wrap long lines instead of scrolling sideways.
        "word_wrap": false,

        // Column to wrap at. 0 wraps to the window width; set a number to wrap to a ruler.
        "wrap_width": 0,

        // Show the minimap: a downsampled overview of the file beside the editor.
        "minimap": false,

        // Spell-check comments, strings and prose (not code identifiers).
        "spell_check": false,

        // Colour scheme by name, e.g. "Monokai". Omitted by default, which keeps
        // whichever scheme the app loaded at launch.
        // "color_scheme": "Monokai",
    }
    """

    public static func resolve(_ layers: [SettingsLayer]) -> EditorSettings {
        /// Last layer mentioning `key` wins; layers that omit it are transparent.
        func value(_ key: String) -> SettingValue? {
            for layer in layers.reversed() {
                if let value = layer.values[key] { return value }
            }
            return nil
        }

        // Falls back to `defaults` rather than to a literal, so a caller that forgets to
        // include `defaultLayer` still gets shipped behaviour instead of zeroes.
        func fallback(_ key: String) -> SettingValue? { defaults[key] }

        return EditorSettings(
            fontFace: value("font_face")?.stringValue,
            fontSize: value("font_size")?.doubleValue ?? fallback("font_size")?.doubleValue ?? 13,
            tabSize: max(1, value("tab_size")?.intValue ?? fallback("tab_size")?.intValue ?? 4),
            translateTabsToSpaces: value("translate_tabs_to_spaces")?.boolValue ?? true,
            lineNumbers: value("line_numbers")?.boolValue ?? true,
            drawWhiteSpace: whiteSpace(value("draw_white_space")),
            highlightLine: value("highlight_line")?.boolValue ?? true,
            rulers: value("rulers")?.intArrayValue ?? [],
            colorScheme: value("color_scheme")?.stringValue,
            autoComplete: value("auto_complete")?.boolValue ?? true,
            wordWrap: value("word_wrap")?.boolValue ?? false,
            wrapWidth: max(0, value("wrap_width")?.intValue ?? 0),
            checkForUpdates: value("check_for_updates")?.boolValue ?? false,
            minimap: value("minimap")?.boolValue ?? false,
            spellCheck: value("spell_check")?.boolValue ?? false
        )
    }

    /// `draw_white_space` is a bool in older Sublime settings and a string
    /// (`"none"`/`"selection"`/`"all"`) in newer ones. Both spellings are accepted since
    /// users copy snippets from both eras; this editor only renders all-or-nothing, so
    /// `"selection"` is treated as on rather than silently ignored.
    private static func whiteSpace(_ value: SettingValue?) -> Bool {
        guard let value else { return false }
        if let flag = value.boolValue { return flag }
        guard let text = value.stringValue?.lowercased() else { return false }
        return text != "none"
    }
}
