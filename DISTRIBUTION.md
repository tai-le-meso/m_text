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

**On anyone else's Mac, Gatekeeper will refuse an ad-hoc signed app.** What they see, and
what actually works, depends on the macOS version — and the advice everyone reflexively gives
is now wrong:

- **macOS 15 (Sequoia) and later** — *"Apple could not verify m_text.app is free of malware…"*.
  **Right-click → Open no longer works**; Apple removed that route. The user must attempt to
  open the app, then go to **System Settings → Privacy & Security → Open Anyway**.
- **macOS 14 and earlier** — *"m_text cannot be opened because the developer cannot be
  verified"*, and right-click → Open → Open does work.

Either way, `xattr -dr com.apple.quarantine <app>` clears it. That is also the fix when
`mtext .` appears to do nothing: a quarantined app is blocked identically from the shell, and
there is no dialog to click through.

To ship properly you need a Developer ID certificate and Apple's notary service — both require
an Apple Developer account (paid) and network access, which is why neither is wired into the
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

---

## Automated releases (CI/CD)

`.github/workflows/release.yml` runs on any `v*` tag and does the whole job: tests, a
universal DMG, verification, then a published GitHub Release with the DMG and its SHA-256.

```bash
git tag v1.0.0 && git push origin v1.0.0
```

`workflow_dispatch` builds the same artefact **without** publishing, for a dry run.

### What it guarantees, and what it cannot

Verified in the workflow, each an explicit failure rather than a hopeful step:

- the binary really is universal (`lipo` reports both `arm64` and `x86_64`),
- `CFBundleShortVersionString` equals the tag — a build can never claim a version it is not,
- the bundle's signature verifies,
- the DMG **mounts** and the app inside it verifies, so a corrupt image cannot ship.

It **cannot** make the download open cleanly on someone else's Mac. The build is ad-hoc
signed; Developer ID signing and notarisation both need a paid Apple account and secrets in
the repo. Until then the release notes carry the version-specific unblock instructions above.
Everything needed to add it later is documented here.

### Why the universal build looks the way it does

`swift build --arch arm64 --arch x86_64` shells out to `xcbuild` and therefore needs **full
Xcode**, which this project deliberately does not depend on. `make dmg UNIVERSAL=1` instead
runs two `--triple` builds and joins them with `lipo`, which works with the Command Line
Tools alone.

### The UI smoke test is not a release gate

CI runs `MTEXT_SMOKE_TEST` in a separate, non-blocking job. It drives a real `NSWindow`, and a
CI runner is a headless session whose window-server behaviour differs from a desk — this
project already has a documented case of exactly that (see `KNOWLEDGE.md` playbook §6). Its
output is posted to the job summary for information; it must not be able to block a release
on an environment quirk. `make test` (433 unit tests) *is* a gate.
