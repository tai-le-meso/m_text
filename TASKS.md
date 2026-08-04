# m_text — Task Breakdown

Granular engineering tasks per phase. `→ Tn` = depends on task n. Sizes: S (<1d), M (1–3d), L (3–5d).

## Phase 0 — Runnable shell ✅ (scaffolded)

| # | Task | Size |
|---|---|---|
| T1 | Package.swift (targets: MTextCore, MTextUI, m_text executable) | S |
| T2 | Makefile: swift build → .app bundle assembly → codesign → run | S |
| T3 | NSApplication bootstrap w/o storyboard: main.swift, AppDelegate, main menu | S |
| T4 | MainWindowController: NSWindow + NSScrollView hosting EditorView | S |
| T5 | EditorView v0: CALayer-backed NSView, CoreText line drawing, blinking cursor, click-to-position | M |
| T6 | TextBuffer v0 (line-array storage; replaced in P1), insert/delete API | S |
| T7 | Keyboard input: keyDown → interpretKeyEvents → insertText/doCommand; arrows, backspace, newline | M |
| T8 | File open/save (⌘O/⌘S/⌘⇧S) via NSOpenPanel/NSSavePanel, dirty-dot in title | S |

## Phase 1 — Text engine ✅ (except T16/T17/T19)

| # | Task | Size | Status |
|---|---|---|---|
| T10 | PieceTree: piece table in an AVL rope, insert/delete/substring O(log n) | L | ✅ |
| T11 | Line index in piece nodes: offset↔(line,col) O(log n) | M | ✅ |
| T12 | Immutable snapshots for background readers (value semantics + COW buffers) | M | ✅ |
| T13 | UndoStack: edit groups (coalesce typing runs), caret restore, redo | M | ✅ |
| T14 | Encoding detect (BOM + strict UTF-8 validation), Latin-1 fallback; LF/CRLF/CR | M | ✅ |
| T15 | Atomic save (temp + fsync + swap), preserve POSIX permissions | S | ✅ (xattrs still TODO) |
| T16 | Full NSTextInputClient: document-wide index space, underlined marked text, candidate positioning | L | partial — per-line index space; composition works |
| T17 | Large file path: lazy line indexing, benchmark 100MB open <1s | M | partial — perf tests cover 200k lines |
| T18 | PieceTree behind the TextDocument facade; unit + fuzz tests vs naive string | M | ✅ |
| T19 | File-changed-on-disk detection (FSEvents) + reload prompt / auto-reload setting | M | `hasExternalChanges()` only |

## Phase 2 — Editor feel ✅ (except T28)

| # | Task | Size | Status |
|---|---|---|---|
| T20 | Selection model: [Region(anchor,head)], sort/merge, back-to-front edit mapping with byte-offset rebasing | M | ✅ |
| T21 | Multi-cursor: ⌘-click add/remove caret, ⌘D expand next match, find-all, split-into-lines, add caret above/below | L | ✅ (⌘K⌘D skip TODO) |
| T22 | Column selection (⌥-drag) | M | ✅ (middle-mouse TODO) |
| T23 | Movement: character/word/subword/line/doc/page, with-selection variants, smart Home, ⌘L expand line | M | ✅ (paragraph TODO) |
| T24 | Bracket auto-pair + wrap-selection, step-over closer, smart backspace over pair | S | ✅ |
| T25 | Smart indent: keep indent, indent after `{`, closer on its own line | M | ✅ |
| T26 | Line ops: move/duplicate/join/delete/sort/unique/reverse; case transforms | M | ✅ (transpose TODO) |
| T27 | Comment toggle (line) | S | ✅ (token by extension; block comments + syntax metadata in Phase 3) |
| T28 | Word wrap layout (wrap at view width/ruler), wrapped-line cursor movement | L | deferred — interacts with folding (T92) |
| T29 | Gutter: line numbers, caret-line emphasis, current-line highlight | M | ✅ (fold arrows with T92) |
| T30 | Render extras: whitespace glyphs, rulers | S | ✅ (indent guides TODO) |
| T31 | LayoutCache: CTLine cache invalidated by document generation | M | ✅ |
| T32 | Scroll/zoom: ⌘+/− font zoom, scroll-to-caret with gutter compensation | S | ✅ |

**Known gaps carried forward:** multi-cursor typing does not coalesce into one undo
step per keystroke run (each keystroke is its own step); no custom scroller yet, so
documents with millions of lines exceed a single NSView's usable height.

## Phase 3 — Syntax + themes ✅

| # | Task | Size | Status |
|---|---|---|---|
| T40 | YAML subset parser for .sublime-syntax | M | ✅ |
| T41 | Context stack machine: match/push/pop/set/embed, captures→scopes | L | ✅ (`with_prototype`, `branch`/`fail` unsupported — diagnostic emitted) |
| T42 | Regex shim over NSRegularExpression (`\h`, POSIX classes, `\G`) | M | ✅ |
| T43 | Scope model: names, selector matching with specificity + exclusions | M | ✅ |
| T44 | Incremental engine: per-line entry-state cache, convergence stop | L | ✅ |
| T45 | Background highlighting: snapshot in, generation-stamped batches out | M | ✅ |
| T46 | Colour schemes: .sublime-color-scheme (JSONC) and .tmTheme loaders | M | ✅ |
| T47 | Spans applied as CTLine attributes; progressive, visible-first paint | M | ✅ |
| T48 | Bundled grammars: JSON, Markdown, Swift, Python, Shell, XML/HTML | M | ✅ (JS/TS, CSS, YAML still TODO) |
| T49 | Scope-aware bracket matching with unbalanced indication | S | ✅ |
| T50 | Syntax auto-detect by extension and first line + Syntax menu | S | ✅ |

Also delivered: a `.tmLanguage` (TextMate) loader, cross-grammar `include: scope:…`
resolution, and a user Packages folder (`~/Library/Application Support/m_text/Packages`)
scanned at launch so drop-in grammars override the built-ins.

## Phase 4 — Find (in-buffer ✅, in-files pending)

| # | Task | Size | Status |
|---|---|---|---|
| T60 | Find bar: fields, regex/case/word/wrap/preserve-case toggles, count badge | M | ✅ (relocated — see below) |
| T61 | Incremental in-buffer search, all-match highlight, ⌘G/⇧⌘G cycle | M | ✅ |
| T62 | Replace / Replace All with `$1`/`\1` captures, preserve-case | M | ✅ (in-selection scope modelled, no UI yet) |
| T63 | Find in Files: parallel file walker (excludes binaries/patterns), streaming matcher | L | — |
| T64 | Results buffer: grouped by file, context lines, double-click → jump, live append | M | — |
| T65 | Replace in Files with preview + confirm | M | — |

Search is line-oriented, so a regex cannot span a line break — a deliberate consequence
of keeping memory bounded on large files. `SearchQuery` is the single model behind ⌘D,
⌘E and the find bar, so options behave identically everywhere.

**T60 relocation (post-Phase 6):** the find bar originally sat at the window bottom as a
sibling of the whole pane split view, so showing it resized *every* pane and tab bar. It
is now mounted into the focused pane's `findBarHost` (`Pane.swift`), between the tab bar
and the editor — the Sublime/TextEdit position — so showing it resizes only that pane's
editor container. This was the fix for the long-running "pane renders blank when Find or
a palette opens" bug; the full post-mortem, including seven things ruled out with
evidence, is in `KNOWLEDGE.md`. Fixed alongside it: `EditorView`'s frame could collapse to
its content size and never recover, because `updateFrameSize()` first ran before Auto
Layout had resolved the scroll view's size and nothing recomputed it on viewport resize.
Still one shared `FindBar` per window, not one per pane.

## Phase 3.5 — Grammar import ✅ (ad-hoc, added mid-stream)

Not in the original breakdown — added after Phase 4 in response to a request for
importing external syntax definitions (e.g. Java/Spring grammars) without a rebuild.

| # | Task | Size | Status |
|---|---|---|---|
| T55 | PackageManager: validate-by-loading, install into `~/Library/Application Support/m_text/Packages` | M | ✅ |
| T56 | Grammar/theme raw-string conversion (avoid embedded-quote literal bugs), split into 3 files | S | ✅ |
| T57 | Additional bundled grammars: Java, YAML, .properties, JS/TS, CSS | M | ✅ (12 grammars total) |
| T58 | Dynamic Syntax menu (NSMenuDelegate-driven) + Import/Reveal/Reload commands | M | ✅ |
| T59 | Tests + compile-error sweep for import path and new grammars | S | ✅ |

## Phase 3.6 — Sublime grammar parity + content-based detection ✅ batch 1 (ad-hoc)

Requested directly: compare the built-in set against every syntax Sublime Text ships by
default (from `sublimehq/Packages`, the authoritative list — Sublime's shipped set is
ASP, ActionScript, AppleScript, Batch File, Binary, C#, C++, CSS, Clojure, D, Diff,
Erlang, Git Formats, Go, Graphviz, Groovy, HTML, Haskell, JSON, Java, JavaScript, LaTeX,
Lisp, Lua, Makefile, Markdown, Matlab, OCaml, Objective-C, PHP, Pascal, Perl, Python, R,
Rails, Regular Expressions, RestructuredText, Ruby, Rust, SQL, Scala, ShellScript, TCL,
TOML, Text, Textile, XML, YAML), then close the gap and add content-based auto-detect
for untitled buffers. Chosen scope was full parity — too large for one pass given every
grammar is hand-written and there is no local Swift compiler to check any of them
against, so it is being delivered in batches.

| # | Task | Size | Status |
|---|---|---|---|
| T110 | Batch 1 — highest-value languages: SQL, Perl, Rust, Go, C, C++, C#, Objective-C, PHP, Ruby (10 grammars, 22 built in total) | L | ✅ |
| T111 | `ContentSniffer`: heuristic keyword/pattern scoring across the built-in languages, wired into `EditorView.didEdit` (paste and typing), gated to untitled + Plain Text + auto-detect-still-on so it can never override a real file or a manual choice | M | ✅ |
| T112 | Tests: `testBuiltInGrammarsLoad` already sweeps every entry in `BuiltInGrammars.all` generically; added extension-detection cases (incl. the `.h` → C default) and `ContentSniffer` true-positive/declines-to-guess cases | S | ✅ |
| T113 | Batch 2: Lua, Makefile, Diff, TOML, R, Haskell, Scala, Clojure (30 built in total) | M | ✅ |
| T114 | Batch 3 (long tail): ASP, ActionScript, AppleScript, Batch File, D, Erlang, Graphviz, Groovy, LaTeX, Lisp, Matlab, OCaml, Pascal, ERB, Regular Expressions, RestructuredText, TCL, Textile (48 built in total) | L | ✅ |

Full Sublime default-package parity is now delivered, with two deliberate substitutions:
"Rails" isn't a language of its own in Sublime either — it's a set of Ruby/HTML/YAML/SQL
embeddings, of which ERB (`<% %>` / `<%= %>` inside HTML) is the one that actually needs
its own tokenizer, so that's what got built; the rest of what "Rails" covers is just
Ruby, already in batch 1. "Text" isn't a grammar, it's exactly what `text.plain` already
is, so there's nothing to add.

Known gaps: `.h` is inherently ambiguous between C/C++/Objective-C, and `.m` between
Objective-C and MATLAB — first-match-wins registration order picks C and Objective-C
respectively, which can be wrong for a C++/Objective-C or MATLAB project (Syntax ▸ pick
manually, or Import a project-specific grammar, both already override it).
Content-sniffing (`ContentSniffer`) only covers the batch-1 languages so far — extending
its heuristics to the batch 2/3 grammars is unstarted, tracked as a follow-up, not a
correctness bug (untitled buffers in those languages just stay on Plain Text until a
syntax is picked by hand). It is a heuristic, not a parser either way — it can
occasionally guess wrong or decline to guess at all on short/ambiguous pastes, by design
(a wrong silent guess would be worse than staying on Plain Text).

## Phase 5 — Navigation

Started directly. No project/folder concept exists yet (Phase 6, unbuilt), so the file
index's scan roots are derived from currently-open tabs' file directories rather than a
real project root — reasonable now, and Phase 6's project model can hand it real roots
later without changing `FileIndex` itself.

| # | Task | Size | Status |
|---|---|---|---|
| T70 | Fuzzy scorer (shared): boundary/camel/consecutive bonuses, gap penalties; benchmark 100k entries | M | ✅ |
| T71 | Overlay palette widget: borderless panel, list view, incremental filter (shared by ⌘P/⌘⇧P) | M | ✅ |
| T72 | File index actor: folder walk + FSEvents invalidation + exclude patterns | M | ✅ |
| T73 | Goto Anything ⌘P: files; `:line`, `@symbol` (current file), `#fuzzy` text; preview-on-highlight | L | ✅ |
| T74 | Symbol index from highlight scopes (entity.name.*); project-wide ⌘⇧R; Goto Definition F12 | L | ✅ |
| T75 | Command Palette ⌘⇧P: registry-driven, shows keybindings, recent-first | M | ✅ |
| T76 | Keymap engine: JSON .sublime-keymap, chords (⌘K ⌘B), context predicates, user override file | L | ✅ |
| T77 | Jump history: ⌃- / ⌃⇧- back/forward across files | S | ✅ |

**T70–T72 detail (delivered):** `FuzzyMatcher` (`Sources/MTextCore/FuzzyMatcher.swift`) is
a single greedy left-to-right subsequence scorer — first-available-match rather than a
full DP table, same tradeoff Sublime's own scorer makes — with word-boundary, camelCase,
and consecutive-run bonuses and a gap/leading-character penalty; `rank(query:candidates:)`
sorts matches descending. Covered by `FuzzyMatcherTests` (8 cases, hand-traced scores)
and a 100k-candidate benchmark in `PerformanceTests` (< 0.25s budget). `Palette`
(`Sources/MTextUI/Palette.swift`) is a floating borderless `NSPanel` (search field +
`NSTableView` list, `NSVisualEffectView` background) reusable by both Goto Anything and
the Command Palette — incremental filter callback, arrow-key/Enter/Escape handling
matching `FindBar`'s `doCommand(by:)` idiom, click-away dismiss, bolded fuzzy-match
ranges. UI code has no automated test coverage (same gap as the rest of MTextUI); it was
reviewed carefully in place of that. `FileIndex` (`Sources/MTextCore/FileIndex.swift`)
walks one or more root folders with an exclude-name set (`.git`, `node_modules`, `build`,
etc.), capped at 200k files, and live-invalidates via one
`DispatchSourceFileSystemObject` per walked directory (real invalidation, not polling),
capped at 4,000 open watchers — beyond either cap, `refresh()` still works, only the
automatic rewalk-on-change stops. This is the first `DispatchSourceFileSystemObject`/raw
POSIX-fd code in the project (no `FSEventStream` C-callback bridging, which was judged
too risky to get right without a compiler); follows `HighlightService`'s existing plain-
class-plus-serial-queue concurrency idiom rather than introducing a Swift `actor`. The
pure walk logic is `public static` and covered by `FileIndexTests` (4 cases against real
temp directories); the queue/watcher orchestration isn't separately unit-tested.

**T73–T77 detail (delivered):** All wired directly into `MainWindowController.swift`
rather than extension files, since `Tab` is `private` (file-scoped, not module-scoped) —
new code needed direct access to the same file's `tabs`/`activeTab`/`editor`. Goto
Anything (T73) dispatches on query prefix: bare = fuzzy file search (`FileIndex` +
`FuzzyMatcher`), `:line[:column]` = jump within the current file, `@symbol` = fuzzy
search over `SymbolExtractor.extractSymbols(from:grammar:)` for the current file only,
`#text` = fuzzy line-content search (capped at 50,000 scanned lines). The first three
modes preview live as you arrow through (`EditorView.didMoveSelection`); file and
project-symbol results only navigate on commit, to avoid speculatively opening tabs.
`SymbolExtractor` (`Sources/MTextCore/SymbolExtractor.swift`) pulls `entity.name.*`-scoped
spans out of a already-highlighted file — a real limitation inherited from the grammars
themselves: most of the 48 built-in grammars only tag *type* declarations this way, not
functions or variables (Java's `class`/`interface` are the cleanest case, since the
grammar pushes a dedicated `type_name` context). `SymbolIndex`
(`Sources/MTextCore/SymbolIndex.swift`) runs `SymbolExtractor` across every file
`FileIndex` reports, on a background queue with the same generation-stamping idiom as
`FileIndex`/`HighlightService` — on demand only (Goto Symbol in Project ⌘⇧R, Goto
Definition F12), not on every save, capped at 20,000 files / 2 MB per file. Goto
Definition jumps directly for a single match, shows a disambiguation palette for
multiple; the jump-history origin is snapshotted synchronously at the F12 keypress
(not read later inside the async index-completion callback, which could be seconds
after the caret has moved on) and is only actually pushed once a match is confirmed, so
a miss doesn't leave a dead entry for ⌃- to land on. Command Palette (T75)
(`Sources/MTextUI/CommandRegistry.swift`) derives its command list by walking the app's
own `NSMenu` tree recursively rather than hand-maintaining a second list — nested
submenu items get their parent's title folded in (`"Line: Indent"`), and dispatch goes
through the original `NSMenuItem` (its real `target`/`representedObject`), not a bare
selector, since some actions (the Syntax menu's `setSyntaxFromMenu(_:)`) read
`representedObject` off the menu item they were sent. Recently-used commands are
persisted via `UserDefaults`, capped at 20. Keymap engine (T76)
(`Sources/MTextCore/Keymap.swift`, `Sources/MTextUI/KeymapEngine.swift`) parses
`.sublime-keymap`-format JSON (with a hand-rolled `//`-comment stripper, since real
Sublime keymap files aren't strictly valid JSON) into one- or two-key chord bindings;
`context` predicates are read but discarded — every binding is unconditionally active, a
documented gap, not an oversight. **Known architectural limitation:** AppKit tries the
app's `NSMenu` key equivalents before any event reaches `EditorView.keyDown(with:)`, so a
keymap binding whose key collides with an existing plain menu shortcut never reaches the
engine at all; the five shipped default chords (`Sources/MTextUI/DefaultKeymap.swift`,
all prefixed `cmd+k`) were chosen by hand-auditing every shortcut in `MainMenu.swift` to
avoid this, but a user's own override file has no such protection. A keymap engine also
can't fire while an IME composition is active (`EditorView` now checks `hasMarkedText()`
first). Jump history (T77) is one stack pair (`jumpBackStack`/`jumpForwardStack`) reused
for two purposes: real ⌃-/⌃⇧- back/forward navigation, and restoring the original caret
position if a Goto Anything/Goto Definition session is cancelled without committing.
None of the AppKit-facing pieces (`Palette`, `KeymapEngine`'s event matching,
`MainWindowController`'s orchestration) have automated test coverage — reviewed by
hand and via subagent instead, matching the rest of MTextUI. `SymbolExtractor`,
`SymbolIndex`, and `Keymap`/`KeymapParser`'s pure parsing logic are unit-tested
(`SymbolExtractorTests`, `SymbolIndexTests`, `KeymapTests`).

## Phase 6 — Workspace

| # | Task | Size | Status |
|---|---|---|---|
| T80 | Tab bar (custom view): reorder, close, dirty dot, overflow menu | L | ✅ pulled forward, ahead of Phase 5 — see below |
| T81 | Split panes: 2/3/4 columns, rows, grid; focus routing; move-tab-to-pane | L | ✅ scoped to single 2-pane split — see below |
| T82 | Sidebar: NSOutlineView file tree, FSEvents refresh, rename/delete/new, reveal | L | ✅ |
| T83 | Project model: .sublime-project folders + settings + excludes; Switch Project | M | ✅ |
| T84 | Session persistence: window frames, panes, tabs, cursors, scroll | M | ✅ |
| T85 | Hot exit: unsaved buffers + undo stacks to disk (debounced autosave of state), silent quit, full restore | L | ✅ except undo stacks — see below |
| T86 | Settings system: layered JSON-with-comments (default→user→syntax→project→view), live file-watch reload, "Preferences: Settings" opens side-by-side | L | ✅ |

**T80 detail (delivered):** each tab is an independent `EditorView` + `NSScrollView`
pair — its own document, undo stack, selection and scroll position — stacked in one
container with only the active one visible, so switching tabs needs no state
save/restore. A custom `TabBar` (`Sources/MTextUI/TabBar.swift`) draws the row: click to
switch, × to close (hover-revealed, always shown on the active tab), a dirty dot when
there's no close button to show, drag to reorder, shrink-to-fit down to a floor width
with horizontal scroll beyond that, and a trailing **+** for a new tab. ⌘T (and a hidden
Control+T, for muscle memory from other editors/browsers) opens a new tab; ⌘W closes the
active one (closing a window's last tab closes the window); ⌘⇧W closes the window
outright; ⌘⇧] / ⌘⇧[ cycle tabs; hidden ⌘1–⌘9 jump to a tab by position (9 = last).
Closing a dirty tab prompts Save/Don't Save/Cancel; closing a window with any dirty
background tab (which the window's own `isDocumentEdited` flag can't see, since that
only reflects the active tab) is caught separately via `NSWindowDelegate
.windowShouldClose`. Known gaps: that window-close prompt is warn-only (no per-file
save, unlike the single-tab close flow); no "reopen closed tab"; no tab overflow menu
(⋮) — only horizontal scroll; dock/Finder "open file" still opens a new window rather
than a tab in an existing one.

**T83 detail (delivered):** `Project`/`ProjectFolder`/`ProjectParser`
(`Sources/MTextCore/Project.swift`) parse `.sublime-project` JSON (folders with `path`
resolved relative to the project file's own directory, optional `name`,
`folder_exclude_patterns`/`file_exclude_patterns` — glob patterns like `*.pyc` are
dropped rather than mismatched, since `FileIndex` has no glob matcher; plain names are
kept). Reuses `KeymapParser.stripLineComments` for the same `//`-comments-in-JSON
tolerance keymap files already needed. New **Project** menu (between File and Edit):
**Open Folder…** synthesizes an ad hoc single-folder project with no file on disk;
**Switch Project…** loads a real `.sublime-project` file (panel filtered to that
extension via an `NSOpenSavePanelDelegate`, the same no-registered-UTType pattern
`SyntaxMenuController`'s import panel already uses); **Close Project** reverts to the
pre-T83 fallback. `currentProject` is per-window (`MainWindowController` is one window),
not persisted across relaunches (session restore is T84's job). Goto Anything/Goto
Symbol in Project/Goto Definition now scan the open project's folders instead of only
open tabs' containing folders when a project is open, falling back to the old
tab-derived approximation otherwise — one shared `fileIndexRoots()`/
`applyFileIndexScanScope(roots:)` pair replaces three previously-duplicated call sites.
Window title folds in the project name (`"foo.swift — Widgets"`) when one is open.
Known gaps: `follow_symlinks` and `"settings"`/`"build_systems"` keys are read past but
not applied anywhere; no in-app project editing (no "Edit Project" or "Add Folder to
Project…"); a project whose folders no longer exist on disk fails silently (empty
results) rather than surfacing an error.

**T81 detail (delivered, deliberately scoped down):** rather than the full N-pane
grid/rows/columns layout originally scoped, this pass ships a single 2-pane
side-by-side split (and back to one) — a scope decision made explicitly with the user
up front, since nearly every existing feature (Goto Anything, Jump History, Command
Palette, keymap dispatch, the tab bar itself) assumed exactly one tab list per window,
and a full grid refactor would have touched all of it with no compiler available to
verify correctness as the work went. The old per-window `tabs`/`activeTab`/`tabBar`
state moved into a new `Pane` class (`Sources/MTextUI/Pane.swift`); `MainWindowController`
now holds `panes: [Pane]` and `focusedPaneIndex`, with `tabs`/`activeTab` kept as
get-only computed properties forwarding to `focusedPane` so the bulk of pre-existing,
already-reviewed code kept working unchanged while becoming pane-aware for free. A new
`allTabs` (flattened across every pane) backs the handful of call sites that genuinely
need window-wide reach: syntax re-detection on grammar reload, the project-folder
fallback for file-index scanning, jump-history existence checks, and the dirty-tab count
on window close. **Split View Right** (View menu) opens a second pane and focuses it;
**Close Pane** closes the focused pane, prompting once with a combined dirty-tab count
(mirroring the existing window-close-confirmation pattern) if it holds unsaved tabs
rather than one prompt per tab. Clicking a tab, its × , or its pane's **+** now resolves
the firing tab bar back to its owning pane first, so both panes' tab bars work
independently. Known gaps: no arbitrary N-pane grid (2 panes, side-by-side, is the hard
ceiling this pass); no drag-a-tab-between-panes; the Find bar and the status line stay
window-level/shared rather than becoming per-pane, an explicit scope cut alongside the
2-pane-only decision. (The Find bar has since been *mounted* inside the focused pane —
see T60's relocation note under Phase 4 — but it remains one shared instance with a
single query, not a per-pane bar.)

**T81 bug fixed later:** `splitViewRight` added the new pane to the split view but never
placed the divider, and a classic `NSSplitView` does not lay out a newly added arranged
subview — so every split produced a second pane that was **focused but zero-width and
invisible**, and the broken state persisted through the session file. Fixed with
`adjustSubviews()` *plus* an explicit `setPosition(_:ofDividerAt:)` (proportional
adjustment alone can't rescue a zero-width subview), a matching `adjustSubviews()` in
`removePane`, and a `constrainMaxCoordinate` that reserves 200pt for the trailing pane so
the divider can't be dragged to recreate it. This went unnoticed from T81 until the find
bar moved inside the pane and started vanishing with it — ⌘F fired, mounted the bar at the
correct height and zero width, and looked like it did nothing. Full write-up plus the
`MTEXT_SMOKE_TEST=1` hook added in response are in `KNOWLEDGE.md`.

**T81 second bug fixed later:** `focusedPaneIndex` was only maintained by `activate(_:)`,
but clicking into a pane's *text* calls `window.makeFirstResponder` straight from
`EditorView`'s mouse handler and bypasses it — so the controller kept thinking the old pane
was focused. The status line described the wrong document, and the shared find bar (which
targets the focused pane's editor while staying mounted where it was opened) ended up
hovering over one pane while searching another. Fixed with
`EditorView.onDidBecomeFirstResponder` → `focusedPaneDidChange(to:)`, plus
`moveFindBarToFocusedPaneIfNeeded()` called from every place focus can move. Note the trap
documented in `KNOWLEDGE.md`: clearing the abandoned pane's matches must use the new
`clearSearchHighlights()`, not `dismissFind()`, because the latter restores first responder
to its own editor and silently undoes the focus change.

**T82 detail (delivered):** a new `Sidebar` (`Sources/MTextUI/Sidebar.swift`), an
`NSOutlineView`-backed file tree fed by `Project`'s folders (or a tab-derived fallback
when no project is open), lazily loading each directory's children only on first expand
and watching it for changes with its own `DispatchSourceFileSystemObject` (the same
`open(path, O_EVTONLY)` idiom `FileIndex` already used, independently re-implemented here
since `FileIndex`'s watcher is tightly coupled to its flat-list full-tree-walk model, an
accepted duplication given time constraints). New file/new folder/rename/delete/reveal in
Finder are available from a per-row context menu (built in `menuNeedsUpdate(_:)` off
`outlineView.clickedRow`, so it targets whatever row was right-clicked even if unselected).
Opening a tab now calls `sidebar.reveal(_:)` to expand and select its file in the tree.
**Toggle Sidebar** (View menu, and the restored ⌘K ⌘B chord, which previously had no
sidebar to toggle and stood in for line-number toggling instead) shows/hides it via a new
`sidebarSplitView` wrapping the sidebar and the pane area, with min/max width constraints
enforced through `NSSplitViewDelegate`. Two bugs caught by review before landing: a
watcher-callback path that could leak one file descriptor and one live dispatch source
per filesystem change to a watched directory (fixed with a re-entrancy guard in
`watchDirectory(_:)`), and a `reveal(_:)` path comparison that used `.standardizedFileURL`
instead of `.resolvingSymlinksInPath()` and would misfire under macOS's `/private/var` vs
`/var` symlinking (fixed the same way `FileIndexTests` needed earlier). Known gaps: no
project-file editing from the sidebar itself; `.sublime-project`'s `follow_symlinks` isn't
modeled (symlinked children are shown and walked like any other directory); no unit test
coverage, consistent with the rest of `MTextUI`'s AppKit-facing code.

**T84 + T85 detail (delivered together):** a `Codable` session model + `SessionStore`
(`Sources/MTextCore/Session.swift`, unit-tested in `SessionTests`) records every window's
frame, project, sidebar visibility, panes, tabs, carets, scroll offsets, and any
hand-picked syntax to `~/Library/Application Support/m_text/Session/Session.json`; each
*dirty* tab's full text is additionally stashed to a `Buffer-N.txt` file alongside
(hot exit), with its real encoding/line-ending recorded so a later ⌘S still writes the
file's own convention. `SessionManager` (`Sources/MTextUI/SessionManager.swift`) saves
debounced (3s after the last change — `refreshChrome` posts a notification on every
edit/caret move/tab switch, so a crash loses at most a few seconds of *session state*;
documents themselves are only written by explicit saves and by dirty-buffer stashing)
and synchronously in `applicationShouldTerminate`, which then returns `.terminateNow`:
quit never prompts about unsaved tabs — that is the whole hot-exit contract, matching
Sublime. Launch restores every window (`AppDelegate` falls back to one blank window when
there's no session); restore is best-effort by design — a corrupt/future-versioned
session file, a deleted document, a vanished project file, or an off-screen saved frame
each degrade gracefully rather than blocking launch, and hot-exit content beats the file
on disk (it's strictly newer). Buffer-file names read back from JSON are validated
(`Buffer-` prefix, no path separators) so a tampered session file can't read outside the
session directory; stale buffers are pruned after every save. Known gaps: **undo stacks
are not persisted** (the one scoped-out piece of T85 — serializing PieceTree/UndoStack
is a project of its own; a restored buffer starts with fresh history), closing a
*window* (⌘W/⌘⇧W) still prompts per dirty tab (hot exit is quit-only), multi-window
z-order is approximate, and the Find bar/jump history/overlay state are not part of the
session.

**T86 detail (delivered):** `Sources/MTextCore/Settings.swift` models one value
(`SettingValue`) and one file's worth (`SettingsLayer`), parses `.sublime-settings` via
`SettingsParser` — reusing `KeymapParser.stripLineComments` rather than carrying a third
copy of the same JSONC scan — and resolves an ordered stack into a flat, `Equatable`
`EditorSettings` (`SettingsResolver`). Precedence is
**default → user → syntax → project → view**, each layer overriding only the keys it
actually names: that per-key granularity is the whole point, since setting `tab_size` for
Makefiles must not also reset that syntax's font. `SettingValue` disambiguates JSON `true`
from JSON `1` with a `CFBooleanGetTypeID` check once at parse time (they are both
`NSNumber` out of `JSONSerialization`), and silently drops values whose *shape* it has no
setting for — a file written for a newer build still contributes everything else instead
of being rejected. Supported keys: `font_face`, `font_size`, `tab_size`,
`translate_tabs_to_spaces`, `line_numbers`, `draw_white_space` (bool *or* the newer
`"none"`/`"selection"`/`"all"` string spellings), `highlight_line`, `rulers`,
`color_scheme`.

`SettingsStore` (`Sources/MTextCore/SettingsStore.swift`) owns the on-disk layers —
`~/Library/Application Support/m_text/User/Preferences.sublime-settings` plus
`<SyntaxName>.sublime-settings` — and live-reloads by watching the *directory*, not the
files: an atomic save (which this app itself performs) replaces the inode and leaves a
per-file watch pointing at nothing, and a directory watch also catches a syntax file being
created for the first time. A file that fails to parse is dropped rather than fatal, and
the previous good copy is deliberately *not* retained — continuing to apply superseded
values while the user stares at the text they just typed would be worse than falling
through to the layer below. The generated read-only `Default.sublime-settings` is
explicitly excluded from being loaded as a layer, since re-applying every default *above*
the user's file would silently undo their own settings. `SettingsController.shared`
(MTextUI) holds one store per process and broadcasts `settingsDidChange`, mirroring
`SyntaxMenuController`.

`Project.settings` is now a real layer — the `"settings"` object used to be read past.
The **view** layer is per-editor (`EditorView.viewOverrides`): View ▸ Show Line
Numbers/Invisibles and font zoom now record overrides at the top of the stack instead of
assigning the property directly, which they used to do — and which meant the next
settings-file reload silently undid the toggle. Font zoom also now overrides only
`font_size`, so zooming no longer discards a `font_face` chosen in settings, and Reset
Zoom clears the override rather than hardcoding 13pt. Settings are re-resolved on every
event that can move a layer: tab creation, file load, syntax change (manual, restored, or
after a grammar import), project open/close, and a view override. **⌘,** ("Settings…",
named for current macOS rather than Sublime's "Preferences") writes the commented defaults
to disk, ensures the user file exists, opens the split, and shows one in each pane.

Known gaps: `color_scheme` parses and round-trips but is **not applied** — colour schemes
are installed by `PackageManager` yet never indexed by name, so there is nothing to look
one up in and every editor uses `ColorScheme.builtInDefault()`; wiring it needs a scheme
registry, which is a Phase 3 gap rather than part of T86. Settings are not persisted into
the session (they don't need to be — they're files). There is no in-app settings UI beyond
editing the file, matching Sublime. `word_wrap` is absent because word wrap itself is
(T28). 16 tests in `SettingsTests`, including one that parses the documented default file
and asserts it resolves identically to the values in code, so the documentation a user
reads cannot drift from what the app applies.

## Phase 7 — Intelligence

| # | Task | Size | Status |
|---|---|---|---|
| T90 | Autocomplete: buffer-word + index symbols, inline popup, fuzzy ranked, tab/enter policy | L | ✅ |
| T91 | Snippets: .sublime-snippet parser, tab stops $1/$2, mirrors, placeholders, $SELECTION vars | L | ✅ |
| T92 | Code folding: indent-based regions, fold UI in gutter, folded-line layout | L | ✅ |
| T93 | Minimap: downsampled render from highlight spans, viewport drag | M | |
| T94 | Macros: record command stream, replay, save/load | M | |
| T95 | Build systems: .sublime-build, run via Process, output panel, error regex + F4 navigation | M | |

**T90 detail (delivered):** `Sources/MTextCore/Completions.swift` is the whole policy, pure
and platform-free: `CompletionItem`, a buffer-word scanner, and `CompletionEngine.complete`,
which takes a prefix plus a word list plus a symbol list and returns a ranked list. Ranking
goes through the shared `FuzzyMatcher` (T70) rather than a second scorer, so ⌘P, ⌘⇧P and
autocomplete agree on what a good match is — and its word-boundary and consecutive-run
bonuses already float true prefix matches above scattered ones, which is what a completion
list wants. Because it is fuzzy, committing *replaces* the typed prefix instead of appending
to it (`sfn` → `someFunctionName`), which is why `commitCompletion` selects the word and
replaces it. Candidates come from three places, deduplicated by text with symbols winning
over plain words (a declaration carries a location worth showing): identifier-like words in
the buffer, the current file's `entity.name.*` symbols via `SymbolExtractor`, and whatever
`SymbolIndex` already holds project-wide. That last one deliberately never *starts* an
index — this is the keystroke path, and kicking off a project-wide symbol walk from a
keypress is exactly how typing starts to stutter; Goto Symbol/Goto Definition remain what
populate it.

`BufferWordIndex` caches the word scan against `TextDocument.generation`, the same staleness
mechanism `LayoutCache` and `HighlightService` use, so a run of keystrokes extending one word
reuses a single scan. A `PerformanceTests` case asserts the cold scan of a 100k-line buffer
stays under 2s, that 20 cached lookups beat one cold scan, and that one keystroke's ranking
stays under 0.1s.

`CompletionPopup` (MTextUI) is a `.nonactivatingPanel` added as a child window, only ever
`orderFront`ed and **never made key** — deliberately not built on `Palette`, which is the
opposite in both respects (modal, owns its own search field, takes focus). Keeping the editor
as first responder is what lets Tab/Enter/Escape/arrows be reinterpreted in the editor's own
`doCommand(by:)` via `handleCompletionCommand`, with no second event monitor and no fighting
the responder chain; it also keeps the caret blinking and the selection tinted while the list
is up, and it stays clear of the failure mode behind the blank-pane bug, which was triggered
precisely by the editor losing focus to an overlay.

Policy: auto-opens at 2 typed characters (1 matches nearly every word in the buffer, so the
list would be constant noise); **Tab and Enter** both commit, matching Sublime's default;
Escape dismisses and suppresses re-opening for that word *and anything it grows into*, so
dismissing at `col` then typing `our` stays dismissed; starting a different word or pressing
⌃Space clears the suppression. ⌃Space ("Complete", Edit menu) forces the list open at any
prefix length including zero, where it sorts alphabetically since there is no query to rank
by. Backspace keeps an open list in step but never opens one — backspacing is how you escape
a bad completion. Multi-caret declines entirely: there is no single prefix, and committing
would have to pick one caret's word to apply everywhere. The list dismisses on focus loss,
scroll, viewport resize, and document replacement, since it is positioned in screen
coordinates against the caret. Hooked into `insertText` rather than `didEdit` so that paste,
line transforms, undo and Replace All don't trigger it. New setting `auto_complete` (T86,
default true) turns the automatic popup off while leaving ⌃Space working.

Known gaps: project symbols are only offered once something else has built the index, so a
freshly launched window sees buffer words plus current-file symbols until then. No completion
*kinds* beyond word/symbol (no function-signature detail, no parameter hints), no
`auto_complete_selector` scope filtering, and no snippet completions — snippets are T91. The
popup has no automated tests, consistent with the rest of MTextUI's AppKit-facing code; the
engine has 15 in `CompletionTests` plus the perf case.

**T91 detail (delivered):** `Sources/MTextCore/Snippet.swift` parses snippet *body* syntax
into a node tree (`SnippetBodyParser`) and renders it (`SnippetRenderer`) — `$1`,
`${1:placeholder}` including nesting, `$0`, `$VAR`/`${VAR:default}`, and `\$`/`\\` escapes,
with an unbalanced `${` falling back to literal text so a stray brace in shell or template
code can't swallow the rest of the body. Parsing and rendering are separate so one parse can
expand repeatedly with different variables. **Mirrors** work by a pre-pass that resolves each
index's default text before rendering, so `${1:x} = $1 + $1` renders all three occurrences
and records three ranges for stop 1. Stops are ordered 1, 2, 3 … with `$0` **last** (a plain
numeric sort would put the exit stop first and Tab would jump straight to the end), and a
`$0` is synthesized at the end when the body omits one, so Tab always has somewhere final to
land. Variables: `SELECTION`/`TM_SELECTED_TEXT`, `TM_FILENAME`, `TM_FILEPATH`,
`TM_DIRECTORY`, `TM_CURRENT_LINE`, `TM_LINE_NUMBER`, `TM_CURRENT_WORD`, `TM_TAB_SIZE`; an
unknown *or empty* variable falls through to its `${VAR:default}`, which is what makes
"wrap the selection, or type something here" work.

`SnippetParser` reads `.sublime-snippet` XML via Foundation's `XMLParser` rather than a
hand-rolled scanner — unlike `.sublime-syntax` (YAML) and `.sublime-settings` (JSONC) this
really is XML, with CDATA bodies that the platform already handles correctly. `SnippetStore`
scans the Packages and Snippets folders, skipping any file that fails to parse rather than
losing the rest, and resolves a tab trigger by **scope specificity** using the same
`ScopeSelector` colour schemes use — so `for` expands differently in Python, Swift and
C-family code. Built-ins load first and file-based snippets are appended, so an equally
specific user snippet replaces a bundled one.

`SnippetSession` (also MTextCore, so it is unit-tested without a window) tracks stops as
absolute **UTF-8 byte ranges**, matching `TextDocument.byteOffset(of:)` — the coordinate
space multi-cursor editing already rebases in. It handles Tab/Shift-Tab navigation, rebases
every range across an edit, and computes mirror updates **back to front** so applying one
can't invalidate the next. An edit *straddling* a stop boundary deliberately ends the
session: the user has replaced across a placeholder's edge and there is no longer a coherent
answer for where that stop begins.

`EditorView+Snippets.swift` is the AppKit half. Tab now means four things in order — advance
the snippet, expand a tab trigger, indent a multi-line selection, insert an indent —
matching Sublime's own precedence; Shift-Tab steps back; Escape abandons the snippet leaving
the text as it stands. **Insert Snippet…** (Edit menu, and therefore the Command Palette)
offers every loaded snippet through the existing `Palette`/`FuzzyMatcher`, with the tab
trigger as the subtitle so you learn it for next time. Eight built-in snippets ship
(`BuiltInSnippets`), covered by a test asserting each one parses, has a trigger, has stops,
ends somewhere, and leaves no raw markers.

Known gaps: **only typing and backspace keep a session alive.** `didEdit` receives just the
resulting selection, not what changed, so paste, line transforms, undo and Replace All can't
describe their edit precisely (`pendingSnippetEdit`) and deliberately *end* the session
rather than rebase stops against an edit whose shape is unknown — corrupting the document
would be far worse. Auto-pair and step-over-closer inside a placeholder end it for the same
reason. Multi-caret snippet insertion is refused outright (no single prefix, and a mirrored
snippet has no meaning applied at several places at once). Nested placeholders parse and
render but the inner stop is navigable rather than replaced-as-a-unit. No snippet completions
in the autocomplete list (they are trigger- and palette-driven only), and no
`.sublime-completions` files. 32 tests in `SnippetTests`.

**T92 detail (delivered):** `Sources/MTextCore/Folding.swift` computes **indent-based**
regions (`FoldFinder`) — chosen over syntax-based because it costs nothing per language and
so all 48 grammars fold correctly on day one; brace-aware folding would be more precise for
C-family code and could be added without changing the region model. A blank line reports
*no* indent so it can sit inside a fold (otherwise every paragraph break would chop a
function into pieces), and trailing blanks are trimmed off a region so folding a function
doesn't swallow the gap before the next one.

The important piece is `FoldSet`, which owns the **document-line ↔ visual-row mapping**.
Once anything can be folded, line *n* is no longer row *n*, and every piece of geometry has
to go through it: `lineTop`, hit testing (`position(at:)`), vertical movement,
`updateFrameSize`, and span invalidation. **T28 (word wrap) is deferred to land against this
same abstraction** — it needs the identical split between "line in the file" and "row on
screen", which is why the two were always paired in the roadmap. `FoldSet` also handles
nesting (an outer fold absorbs those it encloses, a region already hidden is ignored, a
partial overlap is refused as not-sane nesting) and `adjust(afterEditAt:linesDelta:)` to
keep folds attached to their text across edits, dropping any collapsed to nothing.

Drawing iterates a new `VisibleLines` (screen-ordered document lines) rather than a
`ClosedRange`, because visible lines are no longer contiguous. It walks *rows* and maps each
to a line instead of walking a line range and skipping hidden ones: with a large region
collapsed the span between first and last visible line can be the whole document, and
skipping through it every repaint would make drawing O(document) instead of O(screen).
Selections and search matches spanning a fold paint only the rows on screen.

UI: a gutter triangle on every foldable line (filled when collapsed, faint when open) with a
click target that toggles it and does *not* move the caret; a "⋯" badge after a folded line's
text; **View ▸ Fold** with ⌥⌘[ / ⌥⌘] (Sublime's own bindings), Fold/Unfold All, and Fold
Level 1–4. `foldAtCaret` walks *outward* from the caret line, so folding with the cursor in a
function body folds that function rather than doing nothing. A fold hiding the caret is
opened automatically (`revealCaretIfFolded`) — a caret you can't see is worse than a fold
that reopened — and replacing the document clears folds, since they describe the old text.

Verified beyond unit tests by a new `MTEXT_SMOKE_TEST` step asserting that folding shrinks
the document view and unfolding restores it exactly. Worth noting how that check first
behaved: written against a 6-line document it could never fail, because `updateFrameSize`'s
`max(viewport, content)` floor dominated — it needs content taller than the viewport, which
is now commented in the test.

Known gaps: folding is not persisted in the session (T84), so folds are lost on relaunch.
Regions are recomputed on demand rather than cached, so `Fold All` on a very large file is
O(n·depth) — fine interactively, but it is the obvious thing to memoise if it ever bites.
No fold-by-syntax-scope (`region.foldable` in `.sublime-syntax` is unread), no persistent
fold markers in the minimap (T93 doesn't exist yet), and folding is per-view rather than
shared between two panes showing the same file. 21 tests in `FoldingTests`.

## Phase 8 — Extensibility & polish

| # | Task | Size |
|---|---|---|
| T100 | JavaScriptCore plugin host: command registration, event listeners, view/edit API | L |
| T101 | Spell check via NSSpellChecker on scope-filtered regions (strings/comments/text) | M |
| T102 | Diff gutter vs disk (incremental diff), revert-hunk command | M |
| T103 | Phantoms/annotations: inline attachment layout in EditorView | L |
| T104 | Vi mode (modal command layer over command registry) | L |
| T105 | App icon, DMG packaging script (hdiutil), notarization docs (optional/offline OK) | S |

## Cross-cutting (continuous)

- Unit tests for every MTextCore type (`make test`, no XCTest); fuzz PieceTree vs reference implementation
- Performance CI script: launch time, 100MB open, keystroke latency harness
- Instruments profiling pass at each phase gate (Time Profiler + Allocations)
