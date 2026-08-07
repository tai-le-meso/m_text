# Landing page

Live at <https://tai-le-meso.github.io/m_text/>.

Served by GitHub Pages from this folder — **Settings ▸ Pages ▸ Source: `main` / `/docs`**.
Plain HTML, CSS and JS in one file. No build step, no framework, nothing fetched from a CDN,
matching the app's own no-dependency rule.

## Screenshots are real

`assets/*.png` are captured from the running app, not mocked up:

```bash
make screenshots        # writes docs/assets/*.png
```

That drives `MTEXT_CAPTURE` (`Sources/m_text/CaptureMode.swift`), which opens a fresh window,
loads real source files so the syntax highlighting is genuine, and shoots dark, light, split
and the command palette. It prints a colour count and transparency figure per shot: the
capture path is `cacheDisplay`, which `KNOWLEDGE.md` playbook §7 records as unreliable on this
layer-backed tree, so **check that line before committing a shot** — anything reported
`** UNUSABLE **` came back blank or uniform and must not be shipped.

## The download button

It points at `releases/latest/download/m_text-macos-universal.dmg` — a **version-less** asset
name published by `release.yml` alongside the versioned DMG. GitHub resolves
`/releases/latest/download/<asset>` only for an exact filename, so linking
`m_text-1.0.0.dmg` would 404 the moment 1.0.1 shipped. Keep publishing that copy, or the
button breaks on the next release.

The `v1.0.0` label next to it is static text — update it when you cut a release, or drop it.

## Keeping the page truthful

Two things on the page restate facts that live elsewhere, and will rot silently if the source
changes:

- **The first-launch instructions** (Gatekeeper, `xattr -dr com.apple.quarantine`) mirror the
  release notes in `.github/workflows/release.yml`. They are only correct while builds are
  ad-hoc signed — once Developer ID signing and notarisation land, delete the callout from
  both places.
- **The release card** (`v1.0.0`, date, size, what's in it) is static. Update it when you cut
  a release, or replace it with a fetch from the GitHub API.

Copy buttons strip `.p` (prompt), `.c` (comment) and `.o` (sample output) before writing to
the clipboard, so what gets pasted is runnable. Mark any expected output with `.o` — without
it the output line is copied as though it were a command.

## One rule if you edit the page

**No entrance effect may decide whether content exists.** Everything is visible by default;
the animation is an enhancement layered on top:

- `.reveal` opacity is gated behind `.js`, so with JavaScript off the page is fully readable.
- Entrance effects are class-driven *transitions*, never `animation: … both`. A fill-mode
  animation freezes at its `from` state whenever it does not run — a backgrounded tab, an
  embedded webview, a preview crawler — which rendered this page completely blank.
- A timeout reveals everything regardless, because an `IntersectionObserver` never fires for a
  page that is not being rendered.

Each of those was a real blank-page bug during development, in that order.
