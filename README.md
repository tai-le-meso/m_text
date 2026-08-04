# m_text

A native macOS text editor — a Sublime Text clone built in pure Swift + AppKit.
No Xcode project, no SwiftUI, no third-party dependencies. 100% offline; all state stored locally.

- **PLAN.md** — Sublime Text feature analysis, architecture, phased roadmap
- **TASKS.md** — granular engineering tasks per phase
- **HANDOFF.md** — where the project stands right now, and what's next
- **KNOWLEDGE.md** — **read this when something breaks.** Symptom-indexed record of every
  bug solved here, the AppKit pitfalls behind them, what has been ruled out with evidence,
  and how to diagnose this app

## Build & run (no Xcode)

Requires macOS 13+ and Command Line Tools (`xcode-select --install`).

```sh
make                        # release build → build/m_text.app
make run                    # build and launch
make debug                  # debug build, attached to terminal
make test                   # run the test suite
make test FILTER=PieceTree  # run a subset
make test-release           # optimised build, includes performance budgets
make clean

MTEXT_SMOKE_TEST=1 make debug   # UI smoke check: drives split + find, exits non-zero on failure
```

The smoke check exists because the test suite links only `MTextCore` and so can never see
a window — the two worst bugs in this project's history both lived in that gap. It asserts
the specific things that broke rather than dumping a view tree; extend it when a UI bug
escapes. See `KNOWLEDGE.md`.

Tests do **not** use XCTest — that ships inside Xcode.app, and this project builds and
tests with Command Line Tools alone. `Sources/MTextTestKit` is a small assertion
harness and runner; `Sources/MTextTests` is a plain executable.

## Current state — Phases 1–6 complete, Phase 7 in progress

**Engine (MTextCore, no AppKit, fully unit tested)**

- **PieceTree** — piece table in an AVL-balanced rope, indexed by UTF-8 byte offset.
  Insert / delete / substring / line lookup are all O(log n), so edit cost is independent
  of file size. Value semantics give O(1) immutable snapshots for background workers.
- **Undo/redo** — edit groups with typing coalescence and caret restore; save point
  tracked by group identity, so undo-then-retype is correctly still dirty.
- **Encoding** — BOM and strict UTF-8 validation (rejects overlongs, surrogates,
  out-of-range), Latin-1 fallback that never loses bytes; LF/CRLF/CR detected on load
  and restored on save.
- **Atomic save** — temp file, fsync, swap, POSIX permissions preserved.

- **Selection** — multiple regions kept sorted and disjoint. Edits apply back-to-front
  with byte-offset rebasing, so every caret stays attached to its own text even when
  replacements differ in length, and the whole sweep is a single undo step.
- **Search** — literal find next/previous/all with case and whole-word options, used by
  ⌘D and find-all.
- **Transforms** — move/duplicate/join/delete/sort/unique/reverse lines, four case
  conversions, indent/outdent, comment toggle. Each is one undo step and rebases carets.

**UI (MTextUI)**

Custom CoreText-drawn editor view (no NSTextView) with multi-cursor and selection
rendering, a line-number gutter pinned during horizontal scroll, current-line highlight,
optional invisibles and rulers, and a `CTLine` cache so only visible lines are shaped.

**Tabs** — ⌘T (or Control+T) opens a new tab in a Sublime-style tab bar; each tab is a
fully independent editor with its own document, undo stack, selection and scroll
position, so switching tabs never loses any of that. Click to switch, hover for the ×
to close, drag to reorder, a dirty dot when a tab has unsaved changes, shrink-to-fit
down to a floor width with horizontal scroll past that. ⌘W closes the active tab (the
window itself closes when its last tab does); ⌘⇧W closes the window outright; ⌘⇧] /
⌘⇧[ cycle tabs; ⌘1–⌘9 jump to a tab by position. Closing a dirty tab, or a window with
unsaved tabs in the background, prompts before discarding anything.

Mouse: drag-select, double-click word, triple-click line, shift-click extend, ⌘-click to
add or remove a caret, ⌥-drag for rectangular selection.

Keyboard: full movement set (character/word/subword/line/page/document, each with a
shift-extend variant), smart Home, goal-column vertical movement, bracket auto-pairing
and wrapping, smart newline indent, `NSTextInputClient` so IME composition works.

Commands: ⌘D expand to next match, find-all, split into lines, add cursor above/below,
multi-cursor aware copy/cut/paste (one clipboard line per caret distributes), all line
and case transforms, ⌘/ comment toggle, font zoom, undo/redo, open/save.

**Syntax highlighting**

48 grammars are compiled in — full parity with Sublime Text's default package set. Core:
JSON, YAML, Java Properties, XML/HTML, Java, Swift, Python, Shell, TypeScript,
JavaScript, CSS, Markdown, SQL, Perl, PHP, Ruby, C, C++, C#, Objective-C, Rust, Go.
Batch 2: Lua, Makefile, Diff, TOML, R, Haskell, Scala, Clojure. Batch 3 (the long tail):
ASP, ActionScript, AppleScript, Batch File, D, Erlang, Graphviz (DOT), Groovy, LaTeX,
Lisp, MATLAB, OCaml, Pascal, ERB, Regular Expressions, reStructuredText, Tcl, Textile.
Two of Sublime's default packages are deliberately not separate grammars: "Text" is
exactly what the built-in Plain Text fallback already is, and "Rails" isn't a language of
its own — it's a set of Ruby/HTML/YAML/SQL embeddings, of which ERB is the one that
actually needed its own tokenizer, so that's what's built instead. Grammars are
`.sublime-syntax`, loaded through the same code path as user-supplied ones.

`.h` is ambiguous between C/C++/Objective-C, and `.m` between Objective-C and MATLAB —
first-match-wins registration order picks C and Objective-C respectively; use the Syntax
menu or Import for a project that needs the other one. Content-based auto-detect
(below) currently only recognises the batch-1 languages; batch 2/3 languages still need
a manual Syntax-menu pick on an untitled buffer, tracked as a follow-up in `TASKS.md`.

Pasting or typing real code into an untitled, unsaved buffer also auto-detects the
language from its content (heuristic keyword/pattern scoring — approximate by design),
so you don't have to open the Syntax menu by hand just because the file has no name yet.
It never overrides a real file's extension-based detection or a syntax you picked
yourself; a confident guess only kicks in for Plain Text with nothing else to go on.

To add a language, use **Syntax ▸ Import Syntax…** and pick `.sublime-syntax`,
`.tmLanguage`, `.sublime-color-scheme` or `.tmTheme` files, or a folder of them. Each is
validated by actually loading it, so a broken grammar is reported at import time rather
than silently failing to colour anything. Imports land in
`~/Library/Application Support/m_text/Packages` and outrank the built-ins, so you can
replace a bundled grammar. The Syntax menu rebuilds itself on open — no restart. Import
is entirely offline: it copies from a path you choose and never fetches.

**Find and replace**

⌘F find bar with regex, case, whole-word, wrap and preserve-case; incremental search,
all matches highlighted, ⌘G/⇧⌘G cycling, Replace and Replace All with `$1`/`\1` capture
references, and Find All to put a cursor on every match.

Known gaps, tracked in TASKS.md:
no find-in-files (T63–T65). The canvas is a single NSView, so documents with millions of
lines need the custom scroller.

**Navigation**

⌘P **Goto Anything** — bare query fuzzy-searches file names across every open tab's
folder; `:line[:column]` jumps within the current file; `@symbol` fuzzy-searches symbols
in the current file; `#text` fuzzy-searches the current file's line content. The first
three modes preview live as you arrow through results (Escape restores your original
caret position); picking a file only opens it on Enter/click.

⌘⇧R **Goto Symbol in Project** and **F12 Goto Definition** search a background,
on-demand index built from the same `entity.name.*` syntax highlighting scopes the
editor already computes — no separate parser per language. A single match jumps
straight there; multiple matches show a picker. Note: most grammars (including this
project's own) only tag *type* declarations this way, not functions or variables, so
Goto Definition is strongest for class/struct/interface names today.

⌘⇧P **Command Palette** lists every command in the app's own menus (so it can't drift
out of sync with them), fuzzy-searchable, most-recently-used first.

⌃- / ⌃⇧- **Jump back/forward** across every navigation above, and across tabs.

A **keymap engine** (`~/Library/Application Support/m_text/User/Default.sublime-keymap`)
parses `.sublime-keymap`-format JSON, including two-key chords like ⌘K ⌘B — a handful
ship by default, all prefixed `⌘K` since that combination has no menu shortcut of its
own. `context` predicates aren't evaluated (every binding is unconditionally active),
and a binding whose key collides with an existing menu shortcut can't be reached, since
AppKit resolves menu key equivalents before this engine ever sees the keystroke.

**Workspace** *(Phase 6, in progress)*

A **Project** menu opens either an ad hoc folder (Open Folder…) or a real
`.sublime-project` file (Switch Project…), scoping Goto Anything / Goto Symbol in
Project / Goto Definition to its folders instead of just open tabs' folders, and folding
its name into the window title. A **Sidebar** (View ▸ Toggle Sidebar, or ⌘K ⌘B) shows the
project's file tree in a lazily-loaded, FSEvents-refreshed `NSOutlineView`, with
new file/new folder/rename/delete/reveal-in-Finder from a right-click menu; opening a tab
reveals and selects it in the tree. **View ▸ Split View Right** splits the window into two
side-by-side panes (View ▸ Close Pane to collapse back to one) — each pane has its own
tab bar and active tab, sharing the window's Find bar and status line. This pass is
capped at exactly two panes (no arbitrary grid), a deliberate scope cut since nearly every
existing feature assumed one tab list per window; see TASKS.md's T81 entry for the
reasoning and remaining gaps.

**Session persistence and hot exit** — quitting saves the whole workspace (windows,
panes, tabs, cursors, scroll positions, project, sidebar, hand-picked syntaxes) and the
full text of every tab with unsaved changes, then quits silently — no save prompts, ever,
matching Sublime. Relaunching restores all of it, unsaved work included. State also
autosaves a few seconds after any change, so a crash loses almost nothing. Everything
lives in `~/Library/Application Support/m_text/Session`, entirely local. Undo history is
not yet persisted across restarts; closing an individual window (as opposed to quitting)
still prompts per unsaved tab.

**Settings** — plain `.sublime-settings` files (JSON, `//` comments allowed), layered so
each level overrides only the keys it actually names:

```
Default  ->  User  ->  Syntax  ->  Project  ->  View
```

**⌘,** opens the commented defaults and your own file side by side in a split. Your file
is `~/Library/Application Support/m_text/User/Preferences.sublime-settings`; a
syntax-specific file sits next to it named after the syntax (`Makefile.sublime-settings`
— the usual reason being `"translate_tabs_to_spaces": false`). Project settings go in the
`"settings"` object of a `.sublime-project`. Edits apply the moment you save, from this
editor or any other, and a file with a syntax error falls through to the layer below
rather than taking the app down. Supported: `font_face`, `font_size`, `tab_size`,
`translate_tabs_to_spaces`, `line_numbers`, `draw_white_space`, `highlight_line`,
`rulers`. `color_scheme` is read but not yet applied — schemes aren't indexed by name
yet. Menu toggles and font zoom write to the View layer, so saving a settings file won't
undo them.

**Autocomplete** — the list opens after two characters, offering words already in the
buffer, declarations in the current file, and project-wide symbols once a symbol index
exists (Goto Symbol or Goto Definition builds it). Matching is fuzzy and shares the same
scorer as ⌘P, so `sfn` finds `someFunctionName` — committing rewrites what you typed
rather than appending to it. **Tab** or **Enter** accepts, **Escape** dismisses (and stays
dismissed for that word), **↑/↓** move through the list, **⌃Space** forces it open at any
point. Set `"auto_complete": false` to stop it opening on its own while keeping ⌃Space.
The popup never takes keyboard focus, so typing continues straight through it.

**Snippets** — type a tab trigger and press **Tab**: `for` expands differently in Python,
Swift and C-family code, because triggers resolve by scope specificity. **Tab** and
**Shift-Tab** move between placeholders, **Escape** leaves the text as it stands. Repeating
a stop mirrors it — editing `${1:name}` updates every later `$1` as you type — and
`${SELECTION:default}` wraps whatever you had selected, falling back to the default text
when nothing was. **Edit ▸ Insert Snippet…** lists everything available if you haven't
memorised a trigger. Drop `.sublime-snippet` files into
`~/Library/Application Support/m_text/Snippets` to add your own; they override the built-ins
on the same trigger and scope. Paste, undo and line transforms end an active snippet rather
than risk mistracking it.

**Code folding** — click the triangle in the gutter, or **⌥⌘[** / **⌥⌘]** to fold and
unfold at the cursor. Regions are indent-based, so every language folds without needing
grammar support; blank lines stay inside a block rather than splitting it. **View ▸ Fold**
also has Fold/Unfold All and Fold Level 1–4. A folded line shows a ⋯ badge, and a fold
hiding the cursor opens by itself. Folds aren't saved across restarts yet.

**Word wrap** — **⌥⌘W**, or `"word_wrap": true`. Wraps to the window width by default; set
`"wrap_width"` to a column number to wrap to a ruler instead. Long words break rather than
running off the edge, cursor up/down steps through wrapped rows, and the gutter numbers the
line once rather than each row. Continuation rows aren't indented to match their line yet.

## Layout

```
Sources/MTextCore/   platform-free engine (no AppKit) — unit tested
  PieceTree.swift      AVL rope of pieces, UTF-8 byte index, line index
  TextDocument.swift   editing facade: positions, undo wiring, caches, file I/O
  UndoStack.swift      edit groups, coalescing, save-point identity
  TextEncoding.swift   BOM/UTF-8 detection, line-ending normalisation
  FileIO.swift         atomic load/save
  Settings.swift       layered .sublime-settings model, parser, resolver
  SettingsStore.swift  user/syntax layers on disk + live file-watch reload
  Completions.swift    autocomplete candidates + fuzzy ranking, generation-cached
  Snippet.swift        .sublime-snippet body syntax: stops, mirrors, placeholders, vars
  SnippetSession.swift live tab-stop tracking in byte offsets, mirror updates
  Folding.swift        indent-based fold regions
  WordWrap.swift       greedy word-aware line breaking, in character columns
  RowMap.swift         folds + wrap unified: document line <-> screen row
Sources/MTextUI/     AppKit UI: EditorView (CoreText), window controller
Sources/m_text/      executable: app bootstrap + programmatic main menu
Sources/MTextTestKit/  assertion harness + runner (XCTest replacement)
Sources/MTextTests/    unit, fuzz-vs-reference, and perf budget tests
Resources/           Info.plist (bundle assembled by Makefile)
```
