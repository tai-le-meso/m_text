# Distributing m_text

Everything here except the last section runs offline with only the Command Line Tools —
no Xcode, no Apple Developer account, no network.

```sh
make icon    # draws the app icon and builds build/m_text.icns
make bundle  # release build → build/m_text.app (ad-hoc signed)
make dmg     # → build/m_text.dmg, drag-to-install layout
```

`make dmg` depends on `bundle`, which depends on `icon`, so `make dmg` alone is enough.

## The icon

`Tools/make-icon.swift` **draws** the icon with CoreGraphics and writes an `.iconset`;
`iconutil` (part of the Command Line Tools) turns that into `.icns`.

It is generated rather than checked in as binary art because this project has no design
tools and no network, a generated icon can be re-rendered at any size without anyone
needing an original artboard, and it keeps a blob nobody can diff out of the repository.
Edit the drawing code and re-run `make icon`; the Makefile rebuilds it whenever
`Tools/make-icon.swift` changes.

## The disk image

`hdiutil` ships with macOS. The staging folder gets an `/Applications` symlink, so the DMG
opens with the layout people expect: drag the app onto the shortcut.

## Signing and notarisation — *not* done by the Makefile

`make bundle` **ad-hoc signs** (`codesign --sign -`). That is enough to run the app on the
machine that built it, and nothing more.

**On anyone else's Mac, Gatekeeper will refuse an ad-hoc signed app.** They would have to
right-click → Open and confirm, or clear the quarantine attribute by hand. To ship
properly you need a Developer ID certificate and Apple's notary service — both require an
Apple Developer account (paid) and network access, which is why neither is wired into the
build here.

When you have those, the steps are:

**1. Sign with a Developer ID Application certificate.**

```sh
codesign --force --deep --options runtime --timestamp \
  --sign "Developer ID Application: YOUR NAME (TEAMID)" build/m_text.app
```

`--options runtime` enables the hardened runtime, which notarisation requires.
`--timestamp` needs network access.

**2. Notarise the disk image.** Store credentials once:

```sh
xcrun notarytool store-credentials "m_text-notary" \
  --apple-id you@example.com --team-id TEAMID --password APP_SPECIFIC_PASSWORD
```

An *app-specific password* from appleid.apple.com, not your Apple ID password.

```sh
make dmg
xcrun notarytool submit build/m_text.dmg --keychain-profile "m_text-notary" --wait
```

**3. Staple the ticket**, so the app validates without a network round-trip on first launch:

```sh
xcrun stapler staple build/m_text.dmg
xcrun stapler validate build/m_text.dmg
```

**4. Check what a user's Mac will actually see:**

```sh
spctl --assess --type execute --verbose build/m_text.app
```

### If notarisation is rejected

`xcrun notarytool log <submission-id> --keychain-profile "m_text-notary"` returns the
reasons. The usual ones for a project like this are a missing hardened runtime
(`--options runtime`), a missing secure timestamp (`--timestamp`), or a nested binary that
was not signed — `--deep` covers the last of those here, since the bundle contains a single
executable and no frameworks.

## Version numbers

`CFBundleShortVersionString` and `CFBundleVersion` live in `Resources/Info.plist` and are
not currently bumped by the build. Update them there before cutting a release.
