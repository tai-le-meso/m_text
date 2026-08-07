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
| T28 | Word wrap layout (wrap at view width/ruler), wrapped-line cursor movement | L | ✅ (landed after T92, which built the row mapping it needed) |
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
| T63 | Find in Files: parallel file walker (excludes binaries/patterns), streaming matcher | L | ✅ engine only — no UI until T64 |
| T64 | Results buffer: grouped by file, context lines, double-click → jump, live append | M | ✅ |
| T65 | Replace in Files with preview + confirm | M | ✅ |

Search is line-oriented, so a regex cannot span a line break — a deliberate consequence
of keeping memory bounded on large files. `SearchQuery` is the single model behind ⌘D,
⌘E and the find bar, so options behave identically everywhere.

**T63 detail (delivered — engine only):** `Sources/MTextCore/FindInFiles.swift` sweeps a
folder tree and **streams** matches rather than collecting them: a sweep over a large tree
takes long enough that waiting for it to finish before showing anything would feel broken,
and T64's results buffer is meant to append live. Batches are emitted per *file* rather than
per match — a file with 500 hits would otherwise hop to the main queue 500 times.

Reuses `FileIndex.walk` rather than carrying a second directory traversal with its own
exclude handling: the two would drift, and Goto Anything's idea of what is in the project
should match Find in Files'. Matching reuses `SearchMatcher`, so regex, case and whole-word
behave identically to the find bar — there is no second search implementation to keep in
step.

**Binary detection is a NUL byte in the first 8 KB**, not an extension list: extension lists
miss unknown formats and wrongly exclude text files with odd names, whereas essentially no
text encoding this app reads contains an embedded NUL. A file that isn't valid UTF-8 falls
back to Latin-1 — the same fallback `TextEncoding` uses on load — rather than being silently
skipped, since skipping would hide real results. Oversized files are skipped *before* being
read, not after.

Both limits report themselves: `FindInFilesSummary` carries `hitMatchLimit` and
`wasCancelled` alongside the counts, so the UI can say *why* results stopped rather than
implying the tree was fully searched. The sweep takes an `emit` closure rather than posting
to the main queue directly, which is what makes the matching, skipping and limit rules
testable on the calling thread (`runSynchronously`).

Known gaps (T63): the walk is sequential rather than parallel across files. The walk is sequential rather than parallel across files (the perf test sweeps 400
files / 80k lines in ~0.2s, so concurrency has not been worth the complexity yet; the task
title says "parallel" and this is the deliberate departure). No include/exclude glob
patterns beyond `FileIndex`'s plain-name excludes, and no search-in-open-buffers-first. 14
tests plus a perf case.

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
| T83 | Project model: `.mtext-project` (and `.sublime-project`) folders + settings + excludes; Switch Project | M | ✅ |
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
| T93 | Minimap: downsampled render from highlight spans, viewport drag | M | ✅ |
| T94 | Macros: record command stream, replay, save/load | M | ✅ |
| T95 | Build systems: .sublime-build, run via Process, output panel, error regex + F4 navigation | M | ✅ |

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

**Both of this feature's document scans were later found running on every keystroke, and
were fixed** — see `KNOWLEDGE.md` S5, which is worth reading before touching this code.
`BufferWordIndex` originally cached against `TextDocument.generation` (the mechanism
`LayoutCache` and `HighlightService` use), but that counter bumps on every keypress, so the
cache missed every time; `completionSymbols()` re-extracted the file's symbols per keystroke
besides. Together they cost 79 ms per key in a 20k-line file — the editor visibly locking up
while typing. Now neither scans during an edit: `words(in:)` serves the last completed scan,
symbols are cached alongside it, and both refresh on a 0.4 s idle timer (`bufferWordRefreshDelay`)
scheduled from `didEdit` and pushed back by each further edit. `didReplaceDocument()` clears
both explicitly, since they no longer self-invalidate.

**Known gap from that change:** a word is not offered as a completion until ~0.4 s after it
is typed. In practice the list is the same one you would have got — the word being typed is
filtered at rank time anyway — but a deliberately fast type-then-complete of a brand-new
identifier can miss it.

`PerformanceTests` asserts the cold scan of a 100k-line buffer stays under 2s, that 20 cached
lookups beat one cold scan, that **20 keystrokes with edits in between** also beat one cold
scan (the case whose absence let the stall through — the old loop never edited, so its cache
always hit), and that one keystroke's ranking stays under 0.1s. The smoke test asserts a
per-keystroke budget in a real window on top of that.

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

**T28 detail (delivered):** deferred through Phase 2 because it needs the same
document-line ↔ screen-row split as folding; T92 built that, so this extends it rather than
adding a parallel one. Three pieces.

`WordWrapper` (`Sources/MTextCore/WordWrap.swift`) is the greedy, word-aware breaking
algorithm, measured in **character columns** rather than points. The editor already assumes a
monospaced font wherever it estimates width (`updateFrameSize` sizes the canvas as
`charWidth × longestLineLength`), so a column model is consistent with the rest of the layout
and — unlike a CoreText-measured one — is pure, fast and testable without a view. A
proportional `font_face` therefore wraps approximately: a documented consequence of an
assumption the canvas already made, not a new one. Two behaviours the tests caught in the
first implementation: a space that overflows now **hangs** past the edge instead of forcing a
break (without it `"aaa bbb ccc"` at width 7 broke after `"aaa "`, four columns short of a
fit, because the separating space tripped the overflow test before `"bbb"` was considered),
and a break landing exactly at the line's end is suppressed rather than adding an empty
trailing row. Tabs deliberately do not hang — a tab is real indentation.

`RowMap` (`Sources/MTextCore/RowMap.swift`) unifies folds and wrap. Folding *removes* rows and
wrapping *adds* them; with only folds the mapping was closed-form arithmetic, but once one
line can occupy several rows it needs a cumulative index. `starts` is precomputed **with folds
already applied**, so `firstRow` is O(1) and `location(ofRow:)` can binary-search it — the
first version derived each probe by summing hidden lines above it, making hit testing
O(hidden lines · log n), invisible in tests but pathological with one large region collapsed.
Rebuild cost drove the design and is measured rather than assumed (`PerformanceTests`): a full
rebuild only happens when wrap width, tab size or font changes, while an edit patches just the
lines it touched through `updateLines`.

The view routes everything through it. `VisibleLines` from T92 became `VisibleRows`, since
visible lines are non-contiguous (folding) *and* one line can span rows (wrapping). Drawing
reuses the cached per-line `CTLine`, shifted so the row's first column lands at the text
origin and clipped to the row, rather than shaping a `CTLine` per wrapped row — `LayoutCache`
is untouched and the same text isn't re-shaped once per row it occupies. Selections, search
matches and the current-line highlight are clipped to each row's column slice; the gutter
draws one number per line at its first row. Caret placement, hit testing and up/down movement
resolve through the wrapped row, so moving down a wrapped line steps through its rows. While
wrapping, the canvas width collapses to the viewport: there is nothing to scroll horizontally,
and it stops the wrap width and the canvas width chasing each other on every resize.

Settings `word_wrap` and `wrap_width` (0 = window width); **View ▸ Word Wrap** (⌥⌘W) writes a
*view* override so a settings reload can't silently undo it. Re-wraps on font change, document
replace, per-edit, and on viewport resize — the last guarded so a resize that leaves the column
count unchanged (most of them) doesn't rebuild the index.

Known gaps: continuation rows are **not** indented to match their line's leading whitespace
(Sublime's `indent_subsequent_lines`) — it needs the wrap width to shrink per row, which
changes the breaking arithmetic rather than just the drawing. Wrapping is per-view, not shared
between panes showing the same file, and is not persisted in the session. Home/End still move
to the line's edges rather than the row's. Proportional fonts wrap approximately, as above.
26 tests across `WordWrapTests` and `RowMapTests`, plus a perf case and three smoke-test
assertions.

**T93 detail (delivered):** `Sources/MTextUI/Minimap.swift` draws from **highlight spans**
rather than shaped text — at two points per row there is no glyph to read, so what makes the
strip legible is the colour and shape of the code, which the spans already describe and
`HighlightService` has already computed. Runs of non-whitespace become one filled rect each
rather than one per character; at 1pt per column that would be thousands of fills per repaint
for the same result. Lines whose spans haven't arrived yet fall back to a dimmed foreground
colour, so the strip is never blank while the background sweep catches up.

⚠️ **The minimap once rendered the entire window blank** — editor, gutter and tab bar — while
the title bar and status line kept updating. Collapsing the strip to zero width leaves a
zero-width *view* that still has a backing layer, and `CALayer` does not clip sublayers
unless told to, so AppKit's full-size `ContentLayer` for it was composited over the whole
pane and 32pt above it (exactly the tab bar). `Minimap.init` now sets
`layer?.masksToBounds = true`, and the view is hidden when disabled rather than merely
collapsed. Full post-mortem in `KNOWLEDGE.md` S6 — read it before changing how the strip is
shown or hidden.

It renders **rows via the editor's `RowMap`**, not document lines. A minimap that disagreed
with what folding and wrapping put on screen would be worse than none: dragging it would land
somewhere other than where it pointed. Wrapped lines therefore read as several rows and
folded blocks vanish from the strip exactly as they do from the editor.

Past a screenful the strip **compresses** rather than scrolls, so the whole file stays
represented — the property that makes it useful for orientation at all. Rows are sampled past
`maximumRowsDrawn` (several rows share a point line beyond that, so drawing them all is work
for pixels that overwrite each other) and culled to the dirty rect, so the viewport box moving
doesn't repaint the whole strip.

Click or drag **centres** the row rather than putting it at the top, which is what makes a
click read as "take me there". Scrolling over the strip scrolls the document.

Layout: the minimap and the editor's scroll view sit side by side in a per-tab container
(`Tab.container`), so the strip belongs to *its* document — switching tabs shows that tab's
overview, and hiding a tab hides both together. It collapses to zero width when off rather
than being removed, so only a constraint changes; turning it on re-runs `wrapWidthDidChange()`
because the editor's viewport just got narrower and wrapping has to re-measure. Setting
`minimap` (default off) plus **View ▸ Minimap**, written as a view override like the other
View toggles so a settings reload can't undo it.

Known gaps: no code-folding or diff markers in the strip; no hover preview; the strip is not
persisted per tab in the session; and because it compresses rather than scrolls, a very large
file's rows are not individually distinguishable — unavoidable at any fixed strip height, but
worth stating. No unit tests (it is AppKit drawing, consistent with the rest of MTextUI);
covered by four smoke-test assertions that it takes real width, gives it back exactly, and
collapses when off.

**T94 detail (delivered):** `Sources/MTextCore/Macro.swift` models a step as a command name
plus args, reusing `SettingValue` for the args rather than defining a parallel JSON value
type — macros and settings have the same problem (typed values out of untyped JSON, bools
distinguishable from `0`/`1`) and that code is already written and tested. `MacroParser`
reads and writes `.sublime-macro` (a JSON array), tolerating `//` comments like every other
JSON-ish format here and **skipping** an unusable step rather than failing the file, so a
macro from a newer build or from real Sublime replays whatever it has in common.

`MacroRecorder`'s one piece of real logic is **coalescing consecutive inserts**: typing
`hello` arrives as five `insertText` calls, and five steps would make the file unreadable and
replay five times slower for nothing. Any non-insert command breaks the run, so "type `foo`,
Home, type `bar`" stays three steps.

Recording taps the two places every editing action already funnels through — `insertText` and
`doCommand(by:)` — so nothing else in the editor knows it is being recorded. Commands are
stored as the **selector name** (`"moveToBeginningOfLine:"`) rather than translated into
Sublime's own command vocabulary: those names are a distinct snake_case language that only
partly overlaps `NSResponder`'s selectors, and hand-writing a mapping for every movement and
deletion command would be a large table that silently dropped whatever it missed. Replay
accepts **both** — a Sublime name resolves through the existing `KeymapCommands` table, and
anything else is read as a selector — so macros recorded here are portable within this app,
and Sublime-authored macros work to the extent their commands are in that table.

`isReplayingMacro` guards both hooks, which is what stops replay from re-recording itself and
doubling the macro on every run; the macro controls themselves are excluded from recording so
a macro can't end by stopping itself. Recorder and last macro are `static` — app-wide rather
than per view, because a macro recorded in one tab is expected to replay in another and two
tabs recording different macros at once has no meaning.

**Edit ▸ Macro**: Record (⌃⌘Q) and Playback (⌃⌘P), Sublime's own bindings, plus Save Macro…
and Open Macro…. Record is one toggle rather than two items — the menu title carries the
state via `validateMenuItem`, and Playback greys out with nothing recorded. Status
("Recording macro…", "Replayed 6 steps") goes to the window's status line, which
`refreshChrome` overwrites on the next caret move — fine, the message is transient.

Known gaps: replay is **not one undo step** — each edit undoes separately, which is the main
thing to fix if macros get heavy use. Only one macro is held at a time (no named macro
library, no binding a macro to a key). Mouse actions aren't recorded, only keyboard commands
and typed text. Menu- and palette-driven commands that don't go through `doCommand` (Fold,
Goto, the find bar) aren't captured either. 14 tests in `MacroTests` plus four smoke-test
assertions covering a live record→replay round trip, including that replay doesn't re-record
itself.

**T95 detail (delivered):** the first and only feature that executes an external process, so
it is split deliberately. `Sources/MTextCore/BuildSystem.swift` **only parses** — the
`.sublime-build` description, `$file`-style variable expansion, and `file_regex` output
matching — and `BuildRunner` (MTextUI) is the only type that launches anything. Execution is
reachable **solely from the Build command**: nothing about opening a file, loading a project,
switching syntax or restoring a session runs a build. Keeping the parse and the launch in
separate layers is what makes that checkable at a glance rather than a claim, and the command
actually run is echoed into the output panel so what executed is always visible rather than
inferred from a config file the user may not have written.

`cmd` (argv) runs through `/usr/bin/env` with **no shell**, so a path with a space in it can't
word-split or inject; `shell_cmd` goes through `/bin/sh -c` because pipes and redirections are
the entire reason that key exists. Variants inherit everything they don't override, matching
real files where a variant declares only `name` and `cmd`. An unknown `$variable` is left **as
written** rather than replaced with an empty string — silently turning `$unknown/build.sh`
into `/build.sh` would run something the user never asked for, where leaving it intact fails
loudly. stdout and stderr share one pipe, since compilers split diagnostics across both and
interleaving is what lets `file_regex` see everything.

`BuildPanel` is a read-only `NSTextView` at the bottom of the pane (`Pane.buildPanelHost`,
the same collapse-to-zero-height arrangement as the find bar), not another `EditorView` —
console output needs no document, undo stack or row map. `file_regex` captures file, line,
column and message in that order, Sublime's convention, with every group after the first
optional; relative paths resolve against the working directory, since that is what compilers
print them relative to. **F4 / ⇧F4** step through the errors and wrap. Output is parsed once
at exit rather than per chunk: output arrives in arbitrary pieces, and a partial line
mid-stream could match incorrectly or not at all.

Menu: its own top-level **Build** menu — Build (⌘B), Build With… (⇧⌘B, a palette over every
applicable system *and* its variants), Cancel Build, Next/Previous Error, Toggle Build Output.
⌘B repeats the last system rather than re-asking; with several candidates it asks rather than
guessing which command was meant.

**A bug the smoke test caught:** the echoed command line was itself being scanned by
`file_regex`, so every build reported a spurious first error pointing at its own command —
any real compiler invocation contains a path and numbers. The header is now stored separately
from the output: displayed, not parsed.

Known gaps: no incremental/streaming diagnostic parsing (all at exit), no build-system
selection persisted per project, `"selector"` filtering only (no `"syntax"` or per-variant
selectors), no environment inheritance controls beyond `"env"`, and output is plain text with
no clickable links — F4 is the navigation. Builds are per window, so two windows can build
simultaneously but one window runs one build at a time (a second Build cancels the first).
17 tests in `BuildSystemTests` plus six smoke-test assertions that install a fixture, run a
real process, and check the parsed diagnostic — then remove the fixture, so the check is
hermetic.

## Phase 8 — Extensibility & polish

| # | Task | Size | Status |
|---|---|---|---|
| T100 | JavaScriptCore plugin host: command registration, event listeners, view/edit API | L | |
| T101 | Spell check via NSSpellChecker on scope-filtered regions (strings/comments/text) | M | ✅ |
| T102 | Diff gutter vs disk (incremental diff), revert-hunk command | M | ✅ |
| T103 | Phantoms/annotations: inline attachment layout in EditorView | L | ✅ |
| T104 | Vi mode (modal command layer over command registry) | L | |
| T105 | App icon, DMG packaging script (hdiutil), notarization docs (optional/offline OK) | S | ✅ |


**T102 detail (delivered):** `Sources/MTextCore/LineDiff.swift` diffs the buffer against the
file as last loaded or saved. **Cost is the design constraint**, since this runs whenever the
gutter is drawn: common prefix and suffix are trimmed first, which reduces the usual case — a
few edits in a large file — to a handful of lines, and only what remains goes through the
quadratic LCS. That is capped at `maximumLCSLines` (2000, already four million cells); past
it the middle is reported as one modified hunk rather than spending O(n·m) on a diff nobody
reads line by line. On top of that, `EditorView.diffMarks` caches against
`TextDocument.generation` — the same staleness mechanism `BufferWordIndex` and `LayoutCache`
use — so the diff runs once per edit rather than on every repaint, including every caret blink.

The baseline is held **in memory**, not re-read from disk. Re-reading would hit the disk on
every draw *and* would answer a different question — "has the file changed underneath me"
(T19's external-change detection) rather than "what have I changed since I opened this". The
baseline moves on load and on save, since after a save the file on disk *is* the buffer.

A deletion has no line of its own to colour, so it marks the line that now follows it
(`.deletedAbove`, drawn as a wedge at the boundary) and clamps to the last line when the
deletion is at the end — otherwise it would fall off the document. `hunk(containing:)`
matches a deletion by the line it sits above for the same reason: its `newRange` is empty, so
without that a deleted hunk could never be reverted.

**Revert Hunk** goes through the normal `didEdit` path, so it is one ordinary undo step —
reverting a hunk you didn't mean to must be undoable like any other edit, not a special
irreversible action. It greys out when the caret isn't in a hunk.

Known gaps: the baseline is not persisted, so folds/marks reset on relaunch even for a file
with unsaved changes restored by hot exit; no VCS integration (this is diff-vs-disk, not
diff-vs-HEAD, which is what Sublime's own gutter does too); no next/previous-hunk navigation;
and no intra-line character diff — a changed line is marked whole. 15 tests in `LineDiffTests`
plus four smoke-test assertions covering open → edit → revert against a real file.

**T101 detail (delivered):** spell-checking a source file wholesale is useless — every
identifier and keyword becomes a "misspelling" and the squiggles turn into noise you learn to
ignore. `Sources/MTextCore/SpellCheckScopes.swift` restricts checking to `comment.*`,
`string.*` and `text.*` using the scope information the highlighter already produces, and is
pure so the filtering rules are testable without a spell checker, a view or a dictionary.
Adjacent checkable spans are merged, because a comment is often several spans (punctuation,
then content) and a word straddling the boundary would otherwise be reported misspelled.

**A design flaw the smoke test caught.** The first version followed
`EditorView.attributedLine`'s nil-vs-empty convention: nil spans meant "not highlighted yet",
so nothing was checked. That is right for code — no squiggles while the background sweep
catches up — but it meant spell check did **nothing at all** on a plain-text file that never
produces spans, which is the main thing anyone turns it on for. `checkableRanges` now takes
the document's `baseScope` and checks the whole line when *that* is prose, so `text.plain`
works immediately while `source.swift` still waits for real spans.

`NSSpellChecker` is a cross-process call, so results are cached per line against
`TextDocument.generation` — the same staleness mechanism the diff gutter and buffer-word index
use — and only lines actually on screen are ever checked. The `wrap: false` in the scan loop
matters: with wrapping it would loop back to the start of the string and never terminate. The
loop also stops once the checker walks past the region it was asked about, since it scans the
whole string rather than the slice — otherwise a misspelling in the code *after* a comment
would be reported.

Squiggles are drawn as a dotted underline rather than a sine wave (visually indistinguishable
at editor font sizes, one fill per dot instead of a bezier per word) and are clipped to each
wrapped row's columns, so a misspelling on a wrapped line underlines on the row it appears on.
**F6** toggles, **⌃F6** jumps to the next misspelling anywhere in the document (not just on
screen — the point is finding the one you can't see), and `spellingSuggestions()` exposes
corrections. Setting `spell_check`, off by default: most files in a code editor are not prose.

Known gaps: suggestions are computed but not yet wired to a context menu (no right-click
"Correct to…"), no per-language selection or user dictionary UI, no "ignore word in this
document", and the checker uses the system language rather than anything set per file. 10
tests in `SpellCheckScopesTests` plus three smoke-test assertions against the real
`NSSpellChecker` — using unambiguous nonsense words, since macOS's dictionary accepts some
plausible typos and the assertion would otherwise depend on the system dictionary.

**T105 detail (delivered):** `make icon`, `make dmg`, and `DISTRIBUTION.md`. All of it runs
offline with only the Command Line Tools.

The icon is **drawn in code** (`Tools/make-icon.swift`, CoreGraphics → `.iconset` →
`iconutil` → `.icns`) rather than checked in as binary art. This project has no design tools
and no network; a generated icon can be re-rendered at any size without anyone needing an
original artboard, and it keeps a blob nobody can diff out of the repository. The drawing
scales its proportions from the canvas size so the 16pt version stays legible rather than
being a shrunken 512. The Makefile rebuilds it whenever `Tools/make-icon.swift` changes.

`make dmg` stages the bundle with an `/Applications` symlink and calls `hdiutil` — part of
macOS, so nothing needs installing. Result is ~1.4 MB.

**Signing and notarisation are deliberately *not* wired into the build.** `make bundle`
ad-hoc signs, which is enough to run on the machine that built it and nothing more —
Gatekeeper will refuse an ad-hoc signed app on anyone else's Mac. Doing it properly needs a
Developer ID certificate and Apple's notary service, both of which require a paid Apple
Developer account *and* network access, and this project is offline by rule. `DISTRIBUTION.md`
documents the exact `codesign` / `notarytool` / `stapler` sequence, the app-specific-password
detail people trip over, and how to read a rejection — so the steps are there when someone
has the account, rather than a build target that fails for everyone who doesn't.

Known gaps: no version bumping (`CFBundleShortVersionString` is edited by hand in
`Info.plist`), no custom DMG background or window layout (plain drag-to-install), and no
Sparkle-style updater. Verified by building the DMG, mounting it, and confirming the layout
and bundled `.icns`.

**T103 detail (delivered):** phantoms **add rows**, exactly as folding removes them and
wrapping adds them, so they go through `RowMap` rather than being drawn as an overlay. That
is the whole distinction: an overlay sits on top of real text, whereas the point of an inline
annotation is that the lines below move down to make room. `RowMap` gained
`setPhantomRows(_:)`, `wrapRows(forLine:)` and `isPhantomRow(line:rowInLine:)`; phantom rows
come *after* a line's wrapped rows, so an annotation reads as sitting below its line, and a
folded line contributes none of its phantom rows — otherwise an annotation would float free
of the collapsed text it describes.

`PhantomSet` (`Sources/MTextCore/Phantom.swift`) keys phantoms by owner, so a rebuild replaces
its own annotations and leaves anything else alone, and `adjust(afterEditAt:linesDelta:)`
shifts them across edits, dropping any whose line was deleted — the same rule `FoldSet`
follows, for the same reason: an annotation whose line is gone has nothing left to annotate.
One row per phantom rather than measuring wrapped annotation text: a message needing more than
a line is better truncated than allowed to push code off screen, and it keeps the row
accounting exact without a second layout pass.

`VisibleRow` gained `phantomIndex`, and drawing paints a tinted band with a leading bar
(colour alone shouldn't carry the error/warning distinction, and the fills are faint so they
don't compete with the code).

**Wired to build diagnostics**, which is what makes this more than a framework: after a build,
each error appears under the line that caused it, in the file it belongs to, with
**Build ▸ Clear Inline Errors** to dismiss. Warnings are told from errors by the message text,
which is where compilers conventionally put it; anything ambiguous is treated as an error,
erring toward the more visible of the two.

Known gaps: single-row annotations only (no multi-line or rich phantoms, no buttons or links
in them as Sublime's HTML phantoms allow), no right-margin "annotation" style, and phantoms
aren't persisted in the session. 11 tests in `PhantomTests` plus two smoke-test assertions
that the canvas actually grows by a row and returns exactly.

## Cross-cutting (continuous)

- Unit tests for every MTextCore type (`make test`, no XCTest); fuzz PieceTree vs reference implementation
- Performance CI script: launch time, 100MB open, keystroke latency harness
- Instruments profiling pass at each phase gate (Time Profiler + Allocations)
