# m_text — Handoff

Written at the end of a long Cowork session, for whoever (or whatever) picks this up
next — most likely Claude Code in this same repo. `PLAN.md` and `TASKS.md` remain the
authoritative roadmap; this file covers **current state**.

**If something is broken, read `KNOWLEDGE.md` first** — it is the symptom-indexed record of
every bug solved here, the AppKit pitfalls behind them, what has been ruled out with
evidence, and how to diagnose this app. This file will not repeat it.

Updated in later Claude Code sessions, which fixed the blank-pane bug this file was
originally written around plus two follow-on ⌘F bugs. Those sessions *did* have a compiler
— use it.

## Ground rules for this project (unchanged)

- Pure Swift + AppKit. **No Xcode project, no SwiftUI, no nibs/storyboards, no XCTest,
  no third-party dependencies.** macOS 13+.
- **Offline by default.** There is exactly one network call site in the app —
  `UpdateChecker` — and it runs only when the user turns on `check_for_updates` (off by
  default) or picks *Check for Updates…* by hand. Nothing else opens a socket, and the
  smoke test asserts the setting is off out of the box. If you add a second call site,
  update this line; the guarantee is only worth what it says.
- Tests are a plain executable using the hand-rolled `MTextTestKit` harness, because
  XCTest ships inside Xcode.app and this builds with Command Line Tools alone.
- Build/run/test: `make` (release bundle), `make run` (bundle + `open`), **`make debug`
  (runs attached to the terminal — the only way to see `print()` output; `make run`
  detaches via `open` and swallows logs)**, `make test`, `make test FILTER=Session`.
- **The tree builds clean — no warnings, in debug *or* release.** Keep it that way, and
  check with `grep -E "warning:|error:"` rather than grepping for errors alone (see
  `KNOWLEDGE.md`, compile bug class #6).
- **The original session that wrote most of this had no compiler.** Code was verified by
  manual review and subagent review, then compiled by the user. Later sessions *do* build
  and run — use that; several bug classes only ever surfaced at real compile time, and the
  worst UI bugs only ever surfaced by running the app (see `KNOWLEDGE.md`).

## Where the project stands

**Phases 1–7 complete, plus Phase 4's find/replace-in-files and three of Phase 8.**

**The blank-pane bug that headed this file is FIXED** (see the post-mortem below, which
replaces the old "🔴 OPEN BUG" section), and **T86 (settings) has since landed**, closing
Phase 6. Two follow-on ⌘F bugs — a zero-width pane from "Split View Right", and the find bar
sitting in one pane while searching the other — are also fixed (see `KNOWLEDGE.md`), along
with the `MTEXT_SMOKE_TEST` hook added because of them.

| Task | Status |
|---|---|
| T80 Tab bar | ✅ |
| T81 Split panes | ✅ scoped to a single 2-pane split (deliberate, see TASKS.md) |
| T82 Sidebar | ✅ |
| T83 Project model | ✅ |
| T84 Session persistence | ✅ |
| T85 Hot exit | ✅ except undo-stack persistence (scoped out) |
| T86 Settings system | ✅ (`color_scheme` parses but isn't applied — see TASKS.md) |
| T90 Autocomplete | ✅ (its two document scans stalled typing until fixed — `KNOWLEDGE.md` S5) |
| T91 Snippets | ✅ (only typing/backspace keep a session alive — see TASKS.md) |
| T92 Code folding | ✅ (folds not persisted in the session — see TASKS.md) |
| T28 Word wrap | ✅ (no indented continuation rows — see TASKS.md) |
| T93 Minimap | ✅ (its unclipped layer once blanked the whole window — `KNOWLEDGE.md` S6) |
| T94 Macros | ✅ (replay is not a single undo step — see TASKS.md) |
| T95 Build systems | ✅ (diagnostics parsed at exit, not streamed — see TASKS.md) |
| T63 Find in Files | ✅ engine |
| T64 Results buffer | ✅ (⇧⌘F; buffer is editable, which desyncs the line map — see TASKS.md) |
| T65 Replace in Files | ✅ (⌥⇧⌘F; preview + confirm, refuses files changed since planning) |
| T102 Diff gutter | ✅ (diff vs disk, not vs VCS — see TASKS.md) |
| T101 Spell check | ✅ (F6; suggestions not wired to a context menu — see TASKS.md) |
| T105 Icon + DMG | ✅ (ad-hoc signed only — notarisation documented, not automated) |
| T103 Phantoms | ✅ (single-row annotations; wired to build errors — see TASKS.md) |
| Open folders | 🚧 phases 1–2 of 3 — multi-folder windows, drag & drop, Finder open, Open Recent, `mtext` CLI |
| Branding | ✅ logo + light/dark brand palette, View ▸ Appearance (see `Resources/Branding/README.md`) |

**Find in Files is usable**: ⇧⌘F prompts, sweeps the project, and streams results into a
reusable tab where double-click or Enter jumps to the match (T63 engine + T64 buffer).
**Phase 4 is now complete too** — ⌥⇧⌘F previews a replace into the results tab and asks
before writing (T65).

Remaining: **Phase 8** — T100 (plugin host) and T104 (vi mode); **T101, T102, T103 and T105
are done**. The app is packageable: `make dmg`. Plus the partial **T16/T17/T19** from
Phase 1.

⚠️ **Before starting T100 (JavaScriptCore plugin host), agree the sandboxing approach.** It
is a far larger execution surface than T95's build systems — arbitrary user JS with access to
the editor API, rather than a bounded "run this command when I press ⌘B".

⚠️ **T65 writes to files that are not open and have no undo stack.** `ReplaceInFiles.plan`
is read-only; `ReplaceInFiles.apply` is the only writer and is reachable from exactly one
call site, inside the confirmation alert's handler. It refuses any file whose checksum moved
since planning. Keep all three of those properties.

⚠️ **T95 is the only feature that runs an external process.** It executes solely from the
Build command, and `BuildSystem` (parsing) is deliberately separate from `BuildRunner`
(launching) so that stays easy to verify. Keep it that way.

Test status: **461 passed, 1646 assertions** — run, along with `swift build -c release`,
as of the branding work.

### Landed recently
Every task has a "detail (delivered)" paragraph in `TASKS.md` recording its scope decisions
and known gaps — read that for the task you're touching rather than re-deriving it.

- **T81–T85** project model, sidebar, split panes, session persistence, hot exit.
- **T86** settings: `Settings.swift` / `SettingsStore.swift` (layered `.sublime-settings`,
  live file-watch reload), `SettingsController`, ⌘, opening defaults and user file
  side by side.
- **T90** autocomplete: `Completions.swift`, `CompletionPopup` (non-activating panel).
- **T91** snippets: `Snippet.swift` (body syntax), `SnippetSession.swift` (byte-offset stop
  tracking + mirrors), `SnippetStore` / `BuiltInSnippets`, `EditorView+Snippets.swift`.
- **T92** folding: `Folding.swift` (`FoldFinder` + `FoldSet`), `EditorView+Folding.swift`.
- **T28** word wrap: `WordWrap.swift` (breaking), `RowMap.swift` (folds + wrap unified),
  `VisibleRows` replacing T92's `VisibleLines` throughout drawing.
- **T93** minimap: `Minimap.swift`, drawn from highlight spans over `RowMap` rows, mounted
  per tab beside the scroll view (`Tab.container`).
- **T94** macros: `Macro.swift` (model, `.sublime-macro` parser, recorder with insert
  coalescing), `EditorView+Macros.swift` (hooks in `insertText`/`doCommand`, replay).
- **T95** build systems: `BuildSystem.swift` (parse + variables + `file_regex`, no execution),
  `BuildRunner.swift` (the only `Process` launch), `BuildPanel.swift` (output + F4).
- **T63/T64** find in files: `FindInFiles.swift` (streaming engine, reuses `FileIndex.walk`
  and `SearchMatcher`) and `FindResults.swift` (results text + buffer-line→match map),
  surfaced as ⇧⌘F into a reusable results tab.
- **T65** replace in files: `ReplaceInFiles.swift` — two-phase plan/apply with a checksum
  staleness guard, previewed into the results tab and confirmed before writing (⌥⇧⌘F).
- **T102** diff gutter: `LineDiff.swift` (trimmed + capped LCS), `EditorView+Diff.swift`
  (generation-cached marks, gutter bars, Revert Hunk).
- **T101** spell check: `SpellCheckScopes.swift` (which ranges are eligible),
  `EditorView+SpellCheck.swift` (`NSSpellChecker`, cached per line, squiggles, F6/⌃F6).
- **Command Palette / Goto Anything could never be typed into** — a borderless
  `NSPanel` cannot become key, so ⌘P and ⌘⇧P listed everything and ignored every
  keystroke. Present since the initial commit; fixed by `PalettePanel`
  (`KNOWLEDGE.md` S7).
- **Landing page**: `docs/` (GitHub Pages, `main` / `/docs`) — one self-contained HTML file
  plus screenshots captured from the running app via `make screenshots`
  (`Sources/m_text/CaptureMode.swift`). Read `docs/README.md` before editing it: three separate
  blank-page bugs came from entrance effects deciding whether content was visible at all.
- **Branding**: `BrandTheme.swift` (light/dark tokens + WCAG contrast, asserted in
  `BrandThemeTests`), `ColorScheme.brand(_:)`, `AppearanceController` (three-state
  system/light/dark, live OS-flip handling), View ▸ Appearance, and the "Syntax stack"
  icon from `Resources/Branding/`. **Read `Resources/Branding/README.md` before
  touching any colour** — several values deliberately differ from the design system
  because the documented ones fail AA, and the tests enforce that.
- **T105** packaging: `make icon` / `make dmg` (`Tools/make-icon.swift` is the retired
  drawn-in-code placeholder, superseded by the brand iconset),
  `DISTRIBUTION.md` for the signing and notarisation steps that need an Apple account.
- **T103** phantoms: `Phantom.swift` + `RowMap` phantom rows, `EditorView+Phantoms.swift`,
  wired to build diagnostics so errors appear under the lines that caused them.

---

## Solved bugs and AppKit pitfalls → `KNOWLEDGE.md`

Three severe UI bugs have been fixed here (pane rendering blank on ⌘F/⌘P, ⌘F doing nothing
after a split, the find bar searching a different pane than it sat in), along with the
`NSSplitView`, focus, and layer pitfalls behind them and everything **ruled out with
evidence**.

All of it now lives in **`KNOWLEDGE.md`**, organised symptom-first so it's usable when
something recurs. Read that before investigating any rendering, pane, or focus problem —
several of the disproven theories in there fit every symptom perfectly and were still wrong.

`KNOWLEDGE.md` also carries the diagnosis playbook (`MTEXT_SMOKE_TEST`, `MTEXT_LAYOUT_DEBUG`,
session inspection, driving the app programmatically) and the compile-time bug classes that
used to be listed at the bottom of this file.

## UI smoke test — `MTEXT_SMOKE_TEST=1 make debug`

**`MTextTests` links only `MTextCore`, so nothing automated can see a window.** Every severe
bug in this project's history has lived in that gap.

`runSmokeTestIfRequested()` in `Sources/m_text/main.swift` makes checking repeatable: it
drives the real window controller through split → focus → find and *asserts* the properties
that actually broke — panes have usable width, clicking a pane's text focuses it, ⌘F opens
the bar in the focused pane (checked in both directions), and an open bar follows focus. It
prints ✓/✗ and exits non-zero.

It also drives **real `NSEvent` key-downs through the window** and asserts the document
changes, that a click in the editor's middle actually lands on the editor, and that typing
in a 20k-line buffer stays inside a per-keystroke budget. Everything else here drives the
editor by calling methods, which skips `keyDown` → keymap → `interpretKeyEvents` entirely —
that gap is where S5 lived.

⚠️ When adding a check, take the editor from the **controller** (`smokeTest*` hooks), never
by finding the first `EditorView` in the view tree: a pane holds one per tab, so the
view-tree lookup can silently measure a different editor than the one you are driving. That
has now produced a false result three times (T102, T103, and again while diagnosing S5).

Every assertion was verified to fail against the un-fixed code before being kept. **Extend it
whenever a UI bug escapes** — that is the point of it. Details and its known limits are in
`KNOWLEDGE.md`.

## Diagnostics

`Sources/MTextUI/LayoutDiagnostics.swift` — env-gated (`MTEXT_LAYOUT_DEBUG=1 make debug`)
view-tree, layer-tree and one-line trace dumps. **Deliberately no call sites**; add one where
you need it and remove it after.

`Sources/MTextUI/InputDiagnostics.swift` — env-gated (`MTEXT_INPUT_DEBUG=1 make debug`)
keyboard trace: per keystroke, whether the app received the event, whether the window is key,
who holds first responder, whether `EditorView.keyDown` ran, whether the keymap swallowed it,
and whether `insertText` moved the document generation. Unlike `LayoutDiagnostics` it *does*
have call sites — all `guard isEnabled` one-liners.

`MTEXT_RENDER_DUMP=/tmp/x.png` — writes a PNG of the window plus a **view tree** and a
**layer tree** (frames, hidden/zero-size flags, layer contents, opacity, `masksToBounds`).
The layer tree is what found S6, after every view-level signal had come back healthy.

⚠️ **The smoke test cannot see a "typing does nothing" bug.** A terminal-launched process is
never frontmost, so macOS refuses its window key status and never routes real key events to
it; the harness injects `NSEvent`s directly, which tests handling, not delivery. Use the
input trace for anything in that class — see `KNOWLEDGE.md` playbook §6.

⚠️ **Do not trust the PNG the app takes of itself** (`cacheDisplay`) as evidence of what is
on screen — on this layer-backed tree the same build produced an all-white, a partial, a
fully transparent and an all-black snapshot within minutes. It is fine as a *relative*
assertion inside one smoke run. For "what does the user actually see", ask for a screenshot,
and to find *why*, dump the layer tree. See `KNOWLEDGE.md` playbook §7 and S6.

## Other known issues / gaps

- **Undo history is not persisted** across restarts — the deliberately scoped-out part
  of T85. A restored hot-exit buffer starts with fresh undo history.
- Closing a *window* (⌘W/⌘⇧W) still prompts per dirty tab; hot exit is quit-only
  (matches Sublime).
- No arbitrary N-pane grid (2-pane cap), no drag-tab-between-panes. The status line is
  still window-level. The Find bar is now *mounted* inside the focused pane (see the
  post-mortem above) but is still a single shared instance with one query and one set of
  options — it is not yet genuinely per-pane, so ⌘F in the second pane moves the same bar
  rather than giving that pane its own.
- Sidebar duplicates `FileIndex`'s directory-watching logic rather than sharing it
  (accepted tradeoff, documented in TASKS.md T82).
- Content-based syntax auto-detect only covers the batch-1 languages.
- No find-in-files (T63–T65).
- Multi-window z-order is only approximately restored.

## Recurring bug classes and working practices → `KNOWLEDGE.md`

The compile-time bug classes that used to be listed here (missing `public init`, file-scoped
`private`, IUO tuple inference, macOS symlinks, `@objc`/NSObject) and the working practices
that paid off have moved to `KNOWLEDGE.md`, so there is one place to look rather than two
that drift apart.
