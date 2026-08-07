import Foundation
import MTextCore
import MTextTestKit

enum BrandThemeTests {

    static let suite = TestSuite("BrandTheme", [
        ("body text clears AA on both surfaces", testTextContrast),
        ("every syntax colour clears AA on its own background", testSyntaxContrast),
        ("status colours clear AA in both modes", testStatusContrast),
        ("dark mode needs two primaries, not one", testDarkPrimarySplit),
        ("gutter stays legible rather than merely dim", testGutterContrast),
        ("the Swift palette matches the brand JSON", testMatchesBrandTokensJSON),
        ("appearance is three states and defaults to system", testAppearancePreference),
        ("contrast maths matches known WCAG values", testContrastMaths),
    ])

    // MARK: - Contrast

    /// The whole point of the palette: text has to be readable. Asserted rather than trusted,
    /// because the source design system's own values do *not* all pass (see `BrandTheme`).
    static func testTextContrast() {
        for (name, theme) in [("light", BrandTheme.light), ("dark", BrandTheme.dark)] {
            for (label, pair) in [("text on background", (theme.text, theme.background)),
                                  ("text on surface", (theme.text, theme.surface)),
                                  ("text on surface2", (theme.text, theme.surface2)),
                                  ("muted on background", (theme.muted, theme.background)),
                                  ("onPrimary on primaryFill", (theme.onPrimary, theme.primaryFill))] {
                let ratio = Contrast.ratio(pair.0, pair.1)
                expectTrue(ratio >= Contrast.bodyTextMinimum,
                           String(format: "%@ %@ is %.2f:1, below AA 4.5", name, label, ratio))
            }
        }
    }

    /// The icon's palette is drawn for its own dark field — its yellow measures 1.9:1 on
    /// white. Light mode therefore uses darkened counterparts, and this is what stops anyone
    /// "restoring" the icon's literal values into an unreadable light theme.
    static func testSyntaxContrast() {
        for (name, theme) in [("light", BrandTheme.light), ("dark", BrandTheme.dark)] {
            let background = name == "light" ? theme.surface : theme.background
            for (label, color) in [("keyword", theme.syntaxKeyword), ("string", theme.syntaxString),
                                   ("number", theme.syntaxNumber), ("function", theme.syntaxFunction),
                                   ("type", theme.syntaxType), ("caret", theme.caret)] {
                let ratio = Contrast.ratio(color, background)
                expectTrue(ratio >= Contrast.bodyTextMinimum,
                           String(format: "%@ syntax %@ is %.2f:1, below AA 4.5", name, label, ratio))
            }
        }
    }

    static func testStatusContrast() {
        for (name, theme) in [("light", BrandTheme.light), ("dark", BrandTheme.dark)] {
            let background = name == "light" ? theme.surface : theme.background
            for (label, color) in [("success", theme.success), ("warning", theme.warning),
                                   ("danger", theme.danger)] {
                let ratio = Contrast.ratio(color, background)
                expectTrue(ratio >= Contrast.bodyTextMinimum,
                           String(format: "%@ %@ is %.2f:1, below AA 4.5", name, label, ratio))
            }
        }
    }

    /// A white label needs the fill darker; purple text on a dark surface needs it lighter.
    /// Collapsing these into one token breaks one of the two jobs, so they must differ in
    /// dark mode — and both must still pass.
    static func testDarkPrimarySplit() {
        expectTrue(BrandTheme.dark.primaryFill != BrandTheme.dark.primaryAccent,
                   "dark mode must keep the fill and the accent apart")
        let onFill = Contrast.ratio(BrandTheme.dark.onPrimary, BrandTheme.dark.primaryFill)
        let accentOnSurface = Contrast.ratio(BrandTheme.dark.primaryAccent, BrandTheme.dark.surface)
        expectTrue(onFill >= Contrast.bodyTextMinimum,
                   String(format: "white on dark primaryFill is %.2f:1", onFill))
        expectTrue(accentOnSurface >= Contrast.bodyTextMinimum,
                   String(format: "dark primaryAccent on surface is %.2f:1", accentOnSurface))
        // Light mode has no such conflict, and shouldn't invent one.
        expectEqual(BrandTheme.light.primaryFill, BrandTheme.light.primaryAccent)
    }

    /// Line numbers are meant to recede, not to disappear.
    static func testGutterContrast() {
        for (name, theme) in [("light", BrandTheme.light), ("dark", BrandTheme.dark)] {
            let ratio = Contrast.ratio(theme.gutter, name == "light" ? theme.surface : theme.background)
            expectTrue(ratio >= 3.0,
                       String(format: "%@ gutter is %.2f:1, below the 3:1 floor", name, ratio))
        }
    }

    // MARK: - Source of record

    /// `Resources/Branding/brand-tokens.json` is the design deliverable; the Swift values are
    /// a transcription of it. This fails if they drift — which is the only real risk of
    /// hard-coding them, and it is worth catching in the suite rather than on screen.
    static func testMatchesBrandTokensJSON() {
        guard let json = loadBrandTokens() else {
            expectTrue(false, "could not read Resources/Branding/brand-tokens.json")
            return
        }
        for (name, theme) in [("light", BrandTheme.light), ("dark", BrandTheme.dark)] {
            guard let mode = json[name] as? [String: Any] else {
                expectTrue(false, "brand-tokens.json has no \(name) section")
                continue
            }
            let syntax = mode["syntax"] as? [String: Any] ?? [:]
            let expected: [(String, RGBAColor, Any?)] = [
                ("bg", theme.background, mode["bg"]),
                ("surface", theme.surface, mode["surface"]),
                ("surface2", theme.surface2, mode["surface2"]),
                ("border", theme.border, mode["border"]),
                ("text", theme.text, mode["text"]),
                ("muted", theme.muted, mode["muted"]),
                ("primary", theme.primary, mode["primary"]),
                ("primaryFill", theme.primaryFill, mode["primaryFill"]),
                ("primaryAccent", theme.primaryAccent, mode["primaryAccent"]),
                ("success", theme.success, mode["success"]),
                ("warning", theme.warning, mode["warning"]),
                ("danger", theme.danger, mode["danger"]),
                ("syntax.keyword", theme.syntaxKeyword, syntax["keyword"]),
                ("syntax.string", theme.syntaxString, syntax["string"]),
                ("syntax.number", theme.syntaxNumber, syntax["number"]),
                ("syntax.function", theme.syntaxFunction, syntax["function"]),
                ("syntax.type", theme.syntaxType, syntax["type"]),
                ("syntax.caret", theme.caret, syntax["caret"]),
                ("syntax.gutter", theme.gutter, syntax["gutter"]),
                ("syntax.selection", theme.selection, syntax["selection"]),
            ]
            for (key, swiftValue, raw) in expected {
                guard let css = raw as? String, let fromJSON = RGBAColor(css: css) else {
                    expectTrue(false, "\(name).\(key) missing or unparseable in brand-tokens.json")
                    continue
                }
                expectEqual(swiftValue, fromJSON, "\(name).\(key) drifted from brand-tokens.json (\(css))")
            }
        }
    }

    /// Walks up from the test binary to the repo root. The tests are a plain executable with
    /// no bundle, so there is no `Bundle.module` to ask.
    private static func loadBrandTokens() -> [String: Any]? {
        var directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for _ in 0 ..< 6 {
            let candidate = directory.appendingPathComponent("Resources/Branding/brand-tokens.json")
            if let data = try? Data(contentsOf: candidate),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return object
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    // MARK: - Preference

    static func testAppearancePreference() {
        expectEqual(AppearancePreference.allCases.count, 3)
        expectEqual(AppearancePreference(settingValue: nil), .system)
        expectEqual(AppearancePreference(settingValue: "dark"), .dark)
        expectEqual(AppearancePreference(settingValue: "LIGHT"), .light, "parsing is case-insensitive")
        expectEqual(AppearancePreference(settingValue: "sepia"), .system,
                    "an unknown value degrades to system rather than failing")
    }

    static func testContrastMaths() {
        let white = RGBAColor(css: "#FFFFFF")!
        let black = RGBAColor(css: "#000000")!
        expectTrue(abs(Contrast.ratio(white, black) - 21.0) < 0.01, "black on white is 21:1")
        expectTrue(abs(Contrast.ratio(white, white) - 1.0) < 0.001, "a colour on itself is 1:1")
        // A published reference point: #767676 is the lightest grey that passes on white.
        let grey = RGBAColor(css: "#767676")!
        expectTrue(Contrast.ratio(grey, white) >= 4.5 && Contrast.ratio(grey, white) < 4.6,
                   String(format: "#767676 on white is %.2f:1", Contrast.ratio(grey, white)))
    }
}
