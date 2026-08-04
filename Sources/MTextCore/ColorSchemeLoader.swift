import Foundation

/// Loads `.sublime-color-scheme` (JSON with comments and trailing commas) and
/// `.tmTheme` (XML property list) colour schemes.
public enum ColorSchemeLoader {

    public static func load(contentsOf url: URL) throws -> ColorScheme {
        let data = try Data(contentsOf: url)
        switch url.pathExtension.lowercased() {
        case "tmtheme":
            return try loadTMTheme(data)
        default:
            return try loadSublimeScheme(data, name: url.deletingPathExtension().lastPathComponent)
        }
    }

    // MARK: - .sublime-color-scheme

    public static func loadSublimeScheme(_ data: Data, name fallbackName: String) throws -> ColorScheme {
        let text = String(decoding: data, as: UTF8.self)
        let cleaned = JSONC.stripComments(text)
        guard let object = try JSONSerialization.jsonObject(
            with: Data(cleaned.utf8), options: [.fragmentsAllowed]) as? [String: Any]
        else {
            throw GrammarLoadError(reason: "colour scheme is not a JSON object")
        }

        var scheme = ColorScheme(name: (object["name"] as? String) ?? fallbackName)

        // `variables` let a scheme name its palette and reference it as var(name).
        let variables = (object["variables"] as? [String: String]) ?? [:]
        func color(_ raw: Any?) -> RGBAColor? {
            guard let string = raw as? String else { return nil }
            return RGBAColor(css: resolve(string, variables))
        }

        if let globals = object["globals"] as? [String: Any] {
            var resolved = SchemeGlobals()
            resolved.background = color(globals["background"])
            resolved.foreground = color(globals["foreground"])
            resolved.caret = color(globals["caret"])
            resolved.selection = color(globals["selection"])
            resolved.inactiveSelection = color(globals["inactive_selection"])
            resolved.lineHighlight = color(globals["line_highlight"])
            resolved.gutterForeground = color(globals["gutter_foreground"])
            resolved.gutterBackground = color(globals["gutter"])
            resolved.invisibles = color(globals["invisibles"])
            scheme.setGlobals(resolved)
        }

        var rules: [ColorScheme.Rule] = []
        for entry in (object["rules"] as? [[String: Any]]) ?? [] {
            guard let selector = entry["scope"] as? String, !selector.isEmpty else { continue }
            let style = TokenStyle(
                foreground: color(entry["foreground"]),
                background: color(entry["background"]),
                fontStyle: FontStyle(parsing: (entry["font_style"] as? String) ?? "")
            )
            rules.append(ColorScheme.Rule(selector: ScopeSelector(selector), style: style))
        }
        scheme.setRules(rules)
        return scheme
    }

    /// Expands `var(name)` references, following chains.
    private static func resolve(_ value: String, _ variables: [String: String]) -> String {
        var current = value
        for _ in 0 ..< 8 {
            guard current.hasPrefix("var("), current.hasSuffix(")") else { return current }
            let name = String(current.dropFirst(4).dropLast()).trimmingCharacters(in: .whitespaces)
            guard let next = variables[name] else { return current }
            current = next
        }
        return current
    }

    // MARK: - .tmTheme

    public static func loadTMTheme(_ data: Data) throws -> ColorScheme {
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let top = object as? [String: Any] else {
            throw GrammarLoadError(reason: "tmTheme is not a dictionary")
        }
        var scheme = ColorScheme(name: (top["name"] as? String) ?? "Theme")
        var rules: [ColorScheme.Rule] = []

        for entry in (top["settings"] as? [[String: Any]]) ?? [] {
            guard let settings = entry["settings"] as? [String: Any] else { continue }

            // The first entry, with no scope, carries the editor-wide colours.
            guard let selector = entry["scope"] as? String, !selector.isEmpty else {
                var globals = SchemeGlobals()
                globals.background = RGBAColor(css: settings["background"] as? String ?? "")
                globals.foreground = RGBAColor(css: settings["foreground"] as? String ?? "")
                globals.caret = RGBAColor(css: settings["caret"] as? String ?? "")
                globals.selection = RGBAColor(css: settings["selection"] as? String ?? "")
                globals.lineHighlight = RGBAColor(css: settings["lineHighlight"] as? String ?? "")
                globals.invisibles = RGBAColor(css: settings["invisibles"] as? String ?? "")
                globals.gutterForeground = RGBAColor(css: settings["gutterForeground"] as? String ?? "")
                globals.gutterBackground = RGBAColor(css: settings["gutter"] as? String ?? "")
                scheme.setGlobals(globals)
                continue
            }

            let style = TokenStyle(
                foreground: RGBAColor(css: settings["foreground"] as? String ?? ""),
                background: RGBAColor(css: settings["background"] as? String ?? ""),
                fontStyle: FontStyle(parsing: (settings["fontStyle"] as? String) ?? "")
            )
            rules.append(ColorScheme.Rule(selector: ScopeSelector(selector), style: style))
        }
        scheme.setRules(rules)
        return scheme
    }
}

/// Strips comments and trailing commas so `JSONSerialization` can read the
/// JSON-with-comments dialect Sublime uses for settings, keymaps and schemes.
public enum JSONC {

    public static func stripComments(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)

        var inString = false
        var escaped = false
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]

            if inString {
                result.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                index = text.index(after: index)
                continue
            }

            if character == "\"" {
                inString = true
                result.append(character)
                index = text.index(after: index)
                continue
            }

            if character == "/" {
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == "/" {
                    while index < text.endIndex, text[index] != "\n" { index = text.index(after: index) }
                    continue
                }
                if next < text.endIndex, text[next] == "*" {
                    index = text.index(after: next)
                    while index < text.endIndex {
                        if text[index] == "*" {
                            let after = text.index(after: index)
                            if after < text.endIndex, text[after] == "/" {
                                index = text.index(after: after)
                                break
                            }
                        }
                        index = text.index(after: index)
                    }
                    continue
                }
            }

            result.append(character)
            index = text.index(after: index)
        }
        return removeTrailingCommas(result)
    }

    private static func removeTrailingCommas(_ text: String) -> String {
        var characters = Array(text)
        var inString = false
        var escaped = false
        var lastComma: Int?

        var index = 0
        while index < characters.count {
            let character = characters[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                index += 1
                continue
            }
            switch character {
            case "\"":
                inString = true
                lastComma = nil
            case ",":
                lastComma = index
            case "]", "}":
                if let comma = lastComma { characters[comma] = " " }
                lastComma = nil
            case " ", "\t", "\n", "\r":
                break // whitespace between a comma and the closer is fine
            default:
                lastComma = nil
            }
            index += 1
        }
        return String(characters)
    }
}
