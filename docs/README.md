# Landing page

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
