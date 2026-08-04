import Foundation

/// An sRGB colour, kept platform-free so MTextCore stays AppKit-free.
public struct RGBAColor: Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Parses `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`, and `rgb()`/`rgba()` /
    /// `hsl()`/`hsla()` — the forms `.sublime-color-scheme` uses.
    public init?(css: String) {
        var text = css.trimmingCharacters(in: .whitespaces).lowercased()

        if text.hasPrefix("#") {
            let characters = Array(text.dropFirst())
            // Shorthand forms double each digit: #f0a == #ff00aa.
            let digitsPerChannel = (characters.count == 3 || characters.count == 4) ? 1 : 2
            let channels = characters.count / digitsPerChannel
            guard channels == 3 || channels == 4,
                  characters.count == channels * digitsPerChannel else { return nil }

            var values: [Double] = []
            for channel in 0 ..< channels {
                let slice = characters[(channel * digitsPerChannel) ..< ((channel + 1) * digitsPerChannel)]
                let hex = digitsPerChannel == 1
                    ? String(repeating: String(slice), count: 2)
                    : String(slice)
                guard let value = UInt8(hex, radix: 16) else { return nil }
                values.append(Double(value) / 255)
            }
            self.init(red: values[0], green: values[1], blue: values[2],
                      alpha: values.count > 3 ? values[3] : 1)
            return
        }

        let isHSL = text.hasPrefix("hsl")
        guard text.hasPrefix("rgb") || isHSL,
              let open = text.firstIndex(of: "("),
              let close = text.lastIndex(of: ")")
        else { return nil }

        text = String(text[text.index(after: open) ..< close])
        let parts = text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3 else { return nil }

        func scalar(_ raw: String, max: Double) -> Double {
            if raw.hasSuffix("%") {
                return (Double(raw.dropLast()) ?? 0) / 100
            }
            return (Double(raw) ?? 0) / max
        }

        let alpha = parts.count > 3 ? min(1, max(0, scalar(parts[3], max: 1))) : 1

        if isHSL {
            let hue = (Double(parts[0].replacingOccurrences(of: "deg", with: "")) ?? 0) / 360
            let saturation = scalar(parts[1], max: 100)
            let lightness = scalar(parts[2], max: 100)
            let (r, g, b) = RGBAColor.hslToRGB(hue: hue, saturation: saturation, lightness: lightness)
            self.init(red: r, green: g, blue: b, alpha: alpha)
            return
        }
        self.init(red: scalar(parts[0], max: 255),
                  green: scalar(parts[1], max: 255),
                  blue: scalar(parts[2], max: 255),
                  alpha: alpha)
    }

    static func hslToRGB(hue: Double, saturation: Double, lightness: Double) -> (Double, Double, Double) {
        guard saturation > 0 else { return (lightness, lightness, lightness) }
        let q = lightness < 0.5 ? lightness * (1 + saturation) : lightness + saturation - lightness * saturation
        let p = 2 * lightness - q

        func channel(_ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return (channel(hue + 1.0 / 3), channel(hue), channel(hue - 1.0 / 3))
    }
}

public struct FontStyle: Equatable {
    public var bold = false
    public var italic = false
    public var underline = false

    public init(bold: Bool = false, italic: Bool = false, underline: Bool = false) {
        self.bold = bold
        self.italic = italic
        self.underline = underline
    }

    public init(parsing raw: String) {
        let tokens = raw.lowercased().split(whereSeparator: { $0 == " " || $0 == "," })
        bold = tokens.contains("bold")
        italic = tokens.contains("italic")
        underline = tokens.contains("underline")
    }

    public var isPlain: Bool { !bold && !italic && !underline }
}

/// Resolved appearance for a run of text.
public struct TokenStyle: Equatable {
    public var foreground: RGBAColor?
    public var background: RGBAColor?
    public var fontStyle: FontStyle

    public init(foreground: RGBAColor? = nil, background: RGBAColor? = nil,
                fontStyle: FontStyle = FontStyle()) {
        self.foreground = foreground
        self.background = background
        self.fontStyle = fontStyle
    }
}

/// Editor chrome colours a scheme defines outside its scope rules.
public struct SchemeGlobals {
    public var background: RGBAColor?
    public var foreground: RGBAColor?
    public var caret: RGBAColor?
    public var selection: RGBAColor?
    public var inactiveSelection: RGBAColor?
    public var lineHighlight: RGBAColor?
    public var gutterForeground: RGBAColor?
    public var gutterBackground: RGBAColor?
    public var invisibles: RGBAColor?

    public init() {}
}

/// A colour scheme: globals plus scope-selector rules.
public struct ColorScheme {

    public struct Rule {
        public let selector: ScopeSelector
        public let style: TokenStyle
    }

    /// Memo held by reference, not inline: a value-type cache would be copied on
    /// write for every token resolved through a `let` scheme, which is slower than
    /// having no cache at all.
    private final class StyleCache {
        var entries: [ScopeStack: TokenStyle] = [:]
    }

    public var name: String
    public private(set) var globals: SchemeGlobals
    public private(set) var rules: [Rule]
    private let cache = StyleCache()

    public init(name: String, globals: SchemeGlobals = SchemeGlobals(), rules: [Rule] = []) {
        self.name = name
        self.globals = globals
        self.rules = rules
    }

    public mutating func setGlobals(_ globals: SchemeGlobals) {
        self.globals = globals
        clearCache()
    }

    public mutating func setRules(_ rules: [Rule]) {
        self.rules = rules
        clearCache()
    }

    /// Highest-scoring matching rule wins; later rules break ties, matching TextMate.
    ///
    /// Not thread-safe: resolve styles on the thread that draws.
    public func style(for scopes: ScopeStack) -> TokenStyle {
        if let cached = cache.entries[scopes] { return cached }

        var best: (score: Int, style: TokenStyle)?
        for rule in rules {
            guard let score = rule.selector.score(against: scopes) else { continue }
            if let current = best, score < current.score { continue }
            best = (score, rule.style)
        }

        var style = best?.style ?? TokenStyle()
        if style.foreground == nil { style.foreground = globals.foreground }
        cache.entries[scopes] = style
        return style
    }

    public func clearCache() {
        cache.entries.removeAll(keepingCapacity: true)
    }

    /// A readable default so the editor works before any scheme is loaded.
    /// Colours are nil where the platform's own label/background colours should win,
    /// which keeps light/dark mode working without shipping two schemes.
    public static func builtInDefault() -> ColorScheme {
        func rule(_ selector: String, _ hex: String, _ style: FontStyle = FontStyle()) -> Rule {
            Rule(selector: ScopeSelector(selector),
                 style: TokenStyle(foreground: RGBAColor(css: hex), fontStyle: style))
        }
        return ColorScheme(name: "m_text Default", globals: SchemeGlobals(), rules: [
            rule("comment", "#6E7781", FontStyle(italic: true)),
            rule("string", "#0A6E3E"),
            rule("constant.numeric", "#0550AE"),
            rule("constant.language", "#0550AE"),
            rule("constant.character.escape", "#B5651D"),
            rule("keyword", "#CF222E"),
            rule("keyword.operator", "#8250DF"),
            rule("storage", "#CF222E"),
            rule("storage.type", "#CF222E"),
            rule("entity.name.function", "#8250DF"),
            rule("entity.name.type", "#953800"),
            rule("entity.name.class", "#953800"),
            rule("entity.name.tag", "#116329"),
            rule("entity.other.attribute-name", "#0550AE"),
            rule("support.function", "#8250DF"),
            rule("support.type", "#953800"),
            rule("variable.parameter", "#24292F"),
            rule("variable.language", "#CF222E"),
            rule("punctuation.definition.comment", "#6E7781"),
            rule("invalid", "#FFFFFF"),
            rule("markup.bold", "#24292F", FontStyle(bold: true)),
            rule("markup.italic", "#24292F", FontStyle(italic: true)),
            rule("markup.heading", "#0550AE", FontStyle(bold: true)),
            rule("markup.underline.link", "#0550AE", FontStyle(underline: true)),
        ])
    }
}
