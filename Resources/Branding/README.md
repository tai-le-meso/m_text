# m_text branding assets

Source of record for the app's identity. The design deliverable lives here unmodified;
the code transcribes it and the tests assert the two agree.

| File | Role |
| --- | --- |
| `brand-tokens.json` | **Source of record** for every colour. `BrandThemeTests` re-reads it and fails if `BrandTheme.swift` drifts. |
| `m_text.iconset/` | Apple-named PNG pairs; `make icon` turns these into `build/m_text.icns`. |
| `icon/m_text-icon.svg` | Vector source of the mark (direction 2d, "Syntax stack"). |
| `icon/m_text-icon-animated.svg` | Caret-blink variant — **in-app/web only**, an app icon cannot animate. |
| `icon/m_text-{16..1024}.png` | Flat exports. |
| `branding-spec.html` | The spec sheet the palette was signed off from. |

## How it is wired

- **Colours** — `Sources/MTextCore/BrandTheme.swift` holds the light and dark token sets, and
  `ColorScheme.brand(_:)` maps them onto scope selectors. Transcribed into Swift rather than
  parsed at runtime because the editor needs colours before any file could be read, and
  `MTextCore` has no bundle access; the drift test is what makes that safe.
- **Appearance** — `Sources/MTextUI/AppearanceController.swift`, three states
  (`system`/`light`/`dark`), View ▸ Appearance, persisted in `UserDefaults`.
- **Icon** — `make icon` → `iconutil` → `build/m_text.icns`, referenced by `CFBundleIconFile`.

## Decisions worth knowing before changing any of this

**Contrast is asserted, not assumed.** Every text/background pair measures ≥ 4.5:1 in
`BrandThemeTests`. Two values in the source design system do not pass and were deliberately
changed: the status colours fail on white (light mode uses darkened counterparts at the same
hue), and dark mode needs `primaryFill` *darker* for white labels but `primaryAccent`
*lighter* for purple-on-dark text — one token cannot do both jobs. Restoring either to its
"documented" value reintroduces a failure the suite will catch.

**The icon's palette is drawn for its own dark field.** Its yellow is 1.9:1 on white. Light
mode therefore uses darkened counterparts of the icon's colours rather than the literal ones.

**Dynamic `NSColor`s do not solve appearance switching here** — the usual AppKit advice does
not apply. `LayoutCache` shapes each line into a `CTLine` with a concrete `CGColor`, so an
already-shaped line keeps whatever colour it was built with. The switch has to re-apply the
scheme and drop the cache; `AppearanceController` does, and a smoke assertion checks the
cache actually empties (verified to fail when the invalidation is removed).

## Open / not done

- **Icon palette vs UI palette.** The mark is ZaWin cyan (`#00A9E0`) while the chrome is
  mesoneer purple (`#3B2A78`). Left as designed, per the handoff's recommendation: the cyan
  returns as the caret and keyword colour, which ties the dock icon to the editor surface.
  The alternatives — re-tint the icon purple, or move the whole app to ZaWin blue — are a
  brand decision, not a code one.
- **Manrope is not bundled.** It is the brand typeface and is not a macOS system font, so UI
  chrome currently falls back to the system font. No `.ttf` shipped in the asset zip; drop the
  SIL OFL files into the bundle's resources to finish this.
- **Only the editor surface is themed.** Tab bar, sidebar, find bar and status line still use
  system colours. They follow the light/dark switch correctly because AppKit resolves them,
  but they are not yet painted in brand tokens.
