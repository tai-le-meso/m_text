import Foundation

/// The m_text brand palette — the "Syntax stack" (icon direction 2d) identity, as a light and
/// a dark token set.
///
/// Values come from `Resources/Branding/brand-tokens.json`, which is the design deliverable
/// and stays in the repo as the source of record. They are transcribed here rather than
/// parsed at runtime: the editor needs colours before any file could be read, a missing or
/// malformed resource would leave the app unthemed, and `MTextCore` deliberately has no
/// bundle access. `BrandThemeTests` re-reads the JSON and fails if the two ever drift.
///
/// **Every text-on-background pair here measures ≥ 4.5:1 (WCAG AA for body text)** — asserted
/// in the tests, not assumed. Two consequences of that measurement are baked into the values
/// and are easy to "fix" back into failures:
///
/// - The design system's status colours do **not** pass on white. Light mode uses darkened
///   counterparts at the same hue; dark mode keeps the originals, which pass on a dark field.
/// - "Primary lightened 30%" cannot be a single dark-mode token. A white label needs the fill
///   *darker* (`primaryFill`), while purple text on a dark surface needs it *lighter*
///   (`primaryAccent`). One value fails one of the two jobs, so there are two.
///
/// The syntax palette is lifted from the icon, which is why the caret and keywords are cyan:
/// it is what ties the dock icon to the editor surface. The icon's colours are drawn for its
/// own dark field and collapse on a white one (its yellow is 1.9:1 on white), so light mode
/// uses darkened counterparts rather than the icon's literal values.
public struct BrandTheme {

    // MARK: - Surfaces and text

    public let background: RGBAColor
    public let surface: RGBAColor
    public let surface2: RGBAColor
    public let border: RGBAColor
    public let text: RGBAColor
    public let muted: RGBAColor

    // MARK: - Brand

    /// Purple for chrome. `fill` carries `onPrimary` text; `accent` is purple *as* text or as
    /// an active-state tint. In light mode they are the same value; in dark they cannot be.
    public let primary: RGBAColor
    public let primaryFill: RGBAColor
    public let primaryAccent: RGBAColor
    public let onPrimary: RGBAColor

    // MARK: - Status

    public let success: RGBAColor
    public let warning: RGBAColor
    public let danger: RGBAColor

    // MARK: - Editor surface

    public let syntaxKeyword: RGBAColor
    public let syntaxString: RGBAColor
    public let syntaxNumber: RGBAColor
    public let syntaxFunction: RGBAColor
    public let syntaxType: RGBAColor
    public let caret: RGBAColor
    public let selection: RGBAColor
    public let gutter: RGBAColor

    /// The icon's own field colour, for chrome that should match the dock icon.
    public static let iconField = RGBAColor(css: "#1E2939")!
    public static let iconCaret = RGBAColor(css: "#00A9E0")!

    private static func color(_ css: String) -> RGBAColor {
        // Force-unwrapped deliberately: these are compile-time constants from the brand
        // sheet, and a typo should fail loudly in the first test run rather than silently
        // theme the editor with a default.
        guard let color = RGBAColor(css: css) else {
            preconditionFailure("BrandTheme: malformed colour literal \(css)")
        }
        return color
    }

    public static let light = BrandTheme(
        background: color("#F5F5F9"),
        surface: color("#FFFFFF"),
        surface2: color("#F0F0F5"),
        border: color("#E7E7EF"),
        text: color("#15131E"),
        muted: color("#6D6B7E"),
        primary: color("#3B2A78"),
        primaryFill: color("#3B2A78"),
        primaryAccent: color("#3B2A78"),
        onPrimary: color("#FFFFFF"),
        success: color("#0F8843"),
        warning: color("#996F09"),
        danger: color("#E12D33"),
        syntaxKeyword: color("#007FA8"),
        syntaxString: color("#008937"),
        syntaxNumber: color("#987000"),
        syntaxFunction: color("#C75200"),
        syntaxType: color("#8B4EFF"),
        caret: color("#007FA8"),
        selection: color("rgba(59,42,120,0.14)"),
        gutter: color("#6D6B7E")
    )

    public static let dark = BrandTheme(
        background: color("#0D0C13"),
        surface: color("#17151F"),
        surface2: color("#211E2C"),
        border: color("#2A2837"),
        text: color("#F3F2F9"),
        muted: color("#9794A8"),
        primary: color("#8571CD"),
        primaryFill: color("#7D67C9"),
        primaryAccent: color("#8571CD"),
        onPrimary: color("#FFFFFF"),
        success: color("#12A150"),
        warning: color("#B4820A"),
        danger: color("#E5484D"),
        syntaxKeyword: color("#00A9E0"),
        syntaxString: color("#00C950"),
        syntaxNumber: color("#EFB000"),
        syntaxFunction: color("#FF6900"),
        syntaxType: color("#955EFF"),
        caret: color("#00A9E0"),
        selection: color("rgba(131,111,204,0.24)"),
        gutter: color("#9794A8")
    )

    public static func theme(dark isDark: Bool) -> BrandTheme { isDark ? .dark : .light }
}

// MARK: - Appearance preference

/// Which appearance the app runs in. **Three states, never a boolean** — "follow the system"
/// is a distinct choice from "light", and collapsing it loses the user's intent the moment
/// the OS switches.
public enum AppearancePreference: String, CaseIterable {
    case system
    case light
    case dark

    public static let settingKey = "appearance"

    /// Parsed leniently from the settings file; anything unrecognised means `.system` rather
    /// than an error, matching how every other setting here degrades.
    public init(settingValue: String?) {
        self = AppearancePreference(rawValue: (settingValue ?? "").lowercased()) ?? .system
    }

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

// MARK: - Contrast

/// WCAG relative luminance and contrast, so the brand pairs can be *asserted* rather than
/// trusted. Kept in the shipping target rather than the tests because it is also what any
/// future scheme work should check itself against.
public enum Contrast {

    /// WCAG 2.1 relative luminance. Alpha is ignored — composite first if it matters.
    public static func relativeLuminance(_ color: RGBAColor) -> Double {
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.red)
            + 0.7152 * channel(color.green)
            + 0.0722 * channel(color.blue)
    }

    /// Contrast ratio between two opaque colours, from 1:1 to 21:1.
    public static func ratio(_ a: RGBAColor, _ b: RGBAColor) -> Double {
        let la = relativeLuminance(a), lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// AA for body text.
    public static let bodyTextMinimum = 4.5
}
