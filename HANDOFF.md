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
  no third-party dependencies.** macOS 13+. 100% offline — no network code anywhere.
- Tests are a plain executable using the hand-rolled `MTextTestKit` harness, because
  XCTest ships inside Xcode.app and this builds with Command Line Tools alone.
- Build/run/test: `make` (release bundle), `make run` (bundle + `open`), **`make debug`
  (runs attached to the terminal — the only way to see `print()` output; `make run`
  detaches via `open` and swallows logs)**, `make test`, `make test FILTER=Session`.
- **The original session that wrote most of this had no compiler.** Code was verified by
  manual review and subagent review, then compiled by the user. Later sessions *do* build
  and run — use that; several bug classes only ever surfaced at real compile time, and the
  worst UI bugs only ever surfaced by running the app (see `KNOWLEDGE.md`).

## Where the project stands

Phases 1–6 complete. **Phase 7 (Intelligence) is in progress.**

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
| T90 Autocomplete | ✅ (project symbols need an index built by Goto Symbol/Definition first) |
| T91 Snippets | ✅ (only typing/backspace keep a session alive — see TASKS.md) |
| T92 Code folding | ✅ (folds not persisted in the session — see TASKS.md) |
| T28 Word wrap | ✅ (no indented continuation rows — see TASKS.md) |

Phase 7 in progress: **T90 ✅, T91 ✅, T92 ✅**, and **T28 ✅** (word wrap, carried over from
Phase 2 — it was waiting on T92's line↔row mapping). **T93 (minimap) is the next task**, per
`TASKS.md`; it can render from `RowMap` rather than re-deriving layout.

Test status: **323 passed, 1272 assertions** — run, along with `swift build -c release`,
as of T28. (The 8 `SessionTests` that had never been executed when this file was first
written have since run clean.)

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

Every assertion was verified to fail against the un-fixed code before being kept. **Extend it
whenever a UI bug escapes** — that is the point of it. Details and its known limits are in
`KNOWLEDGE.md`.

## Diagnostics

`Sources/MTextUI/LayoutDiagnostics.swift` — env-gated (`MTEXT_LAYOUT_DEBUG=1 make debug`)
view-tree, layer-tree and one-line trace dumps. **Deliberately no call sites**; add one where
you need it and remove it after.

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
- No word wrap (T28, deferred to land with folding); no find-in-files (T63–T65).
- Multi-window z-order is only approximately restored.

## Recurring bug classes and working practices → `KNOWLEDGE.md`

The compile-time bug classes that used to be listed here (missing `public init`, file-scoped
`private`, IUO tuple inference, macOS symlinks, `@objc`/NSObject) and the working practices
that paid off have moved to `KNOWLEDGE.md`, so there is one place to look rather than two
that drift apart.
