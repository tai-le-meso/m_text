# m_text — Native macOS Sublime Text Clone

Pure Swift + AppKit. No Xcode, no SwiftUI, no third-party dependencies. Built entirely with Swift Package Manager from the command line. Offline by default (the
only network request is an opt-in update check), all state stored locally.

---

## 1. Sublime Text 4 — Feature Inventory

What we are cloning, grouped by subsystem.

### 1.1 Text engine
- Instant open of huge files (100MB+), all edits O(log n)
- Multiple selections / multi-cursor (the defining feature)
- Column (rectangular) selection
- Unlimited undo/redo with selection restoration, persisted across restarts
- Encodings (UTF-8/16, Latin-1, auto-detect), line endings (LF/CRLF/CR)
- Atomic save, "hot exit" (unsaved changes survive quit without prompting)

### 1.2 Rendering / editor UI
- GPU-accelerated custom-drawn editor surface
- Syntax highlighting (Sublime `.sublime-syntax` / TextMate grammars)
- Minimap with viewport indicator
- Line numbers, gutter (folding arrows, git/diff markers, bookmarks)
- Code folding (indentation + syntax based)
- Word wrap, indent guides, whitespace rendering, rulers
- Color schemes (`.sublime-color-scheme` / `.tmTheme`), adaptive UI theme
- Smooth scrolling, per-pixel scroll, zoom (font size per view)

### 1.3 Navigation
- Goto Anything (`⌘P`): fuzzy file search; `@` symbol, `:` line, `#` fuzzy-in-file
- Goto Definition / Reference (index-based, no language server needed)
- Goto Symbol in Project (`⌘⇧R`) via background symbol index
- Jump back/forward navigation history

### 1.4 Editing intelligence
- Autocomplete: buffer words + syntax-aware symbol index + snippets
- Snippets with tab stops, fields, mirrored placeholders (`.sublime-snippet`)
- Auto-pairing brackets/quotes, smart indent, comment toggling
- Bracket matching + highlight
- Transform commands: case, sort/unique/reverse lines, join, transpose
- `⌘D` expand-to-next-match, `⌥F3`/`⌃⌘G` select-all-matches, split selection into lines

### 1.5 Find / Replace
- In-buffer incremental find, regex (with capture-group replace), whole word, case
- Find in Files across project, streamed results in a results buffer, context lines
- Preserve case replace, in-selection scope

### 1.6 Windows / project model
- Tabs, multiple windows, split panes (rows/columns/grid), sheets
- Side bar file tree with file operations
- Projects (`.sublime-project`) + workspaces (`.sublime-workspace`): folders, per-project settings, excluded patterns
- Full session persistence: windows, tabs, cursors, scroll positions, unsaved buffers

### 1.7 Command system
- Everything is a named command with JSON args
- Command Palette (`⌘⇧P`) — fuzzy, shows keybinding
- Keymaps: JSON, contextual bindings (`.sublime-keymap`), user overrides
- Macros (record/replay), repeatable commands

### 1.8 Settings
- Layered JSON settings: default → platform → user → syntax-specific → project → view
- Live reload on settings file change; settings edited as plain text files (fits "offline, local files" requirement perfectly)

### 1.9 Extensibility (Sublime uses embedded Python)
- Plugin API: commands, event listeners, view/window/region APIs
- Build systems (`.sublime-build`): run tool, capture output, error navigation (F4)

### 1.10 Misc
- Spell check, HTML popups/phantoms (inline annotations), incremental diff against disk with revert-hunk, vintage (vi) mode

---

## 2. Architecture

### 2.1 Constraints → decisions

| Constraint | Decision |
|---|---|
| No Xcode | SwiftPM executable target + `Makefile` assembles `m_text.app` bundle; ad-hoc codesign. Tests avoid XCTest (it ships inside Xcode.app) — `MTextTestKit` is an in-repo harness run as a plain executable |
| No SwiftUI | AppKit shell (NSWindow/NSMenu/NSScrollView) + fully custom `NSView` editor drawn with CoreText/CoreGraphics (CALayer-backed; optional Metal later) |
| Best performance | Rope/piece-table buffer, incremental highlighter, line-layout cache, background indexing on `DispatchQueue`/actors, zero Objective-C dynamism in hot paths |
| Offline + local | No network code at all. State in `~/Library/Application Support/m_text/` as plain JSON; settings/keymaps/themes are user-editable text files |

### 2.2 Module layout (SwiftPM targets)

```
m_text/
├── Package.swift
├── Makefile                  # build/run/bundle/sign/test, no Xcode
├── Sources/
│   ├── MTextCore/            # platform-free: buffer, undo, selection model,
│   │   │                     #   syntax engine, indexers, settings, commands
│   │   ├── Buffer/           #   PieceTree, LineIndex, Encoding, UndoStack
│   │   ├── Syntax/           #   grammar loader, Oniguruma-free regex engine,
│   │   │                     #   incremental highlight state cache
│   │   ├── Index/            #   file index (Goto Anything), symbol index
│   │   ├── Commands/         #   Command protocol, registry, macro recorder
│   │   └── Settings/         #   layered JSON-with-comments settings
│   ├── MTextUI/              # AppKit: windows, tabs, panes, sidebar,
│   │   │                     #   EditorView (CoreText), minimap, palettes
│   │   └── Editor/           #   EditorView, LayoutCache, GutterView,
│   │                         #   NSTextInputClient (IME), cursor/selection draw
│   ├── m_text/               # thin executable: NSApplication bootstrap, menu
│   ├── MTextTestKit/         # assertion harness + runner (no XCTest)
│   └── MTextTests/           # test executable: unit, fuzz, perf budgets
├── Resources/
│   ├── Info.plist
│   ├── DefaultSettings/      # default keymap, settings, theme
│   └── Syntaxes/             # bundled grammars (JSON, Swift, MD, …)
```

`MTextCore` has **zero AppKit imports** → testable headlessly on any machine, and the hot logic stays free of UI coupling.

### 2.3 Key technical designs

**Text storage — piece tree** (VS Code-style piece table over a red-black tree):
original buffer + append-only add buffer; edits are node splits. O(log n) insert/delete/lookup, cheap snapshots for async workers (highlighter, search) — this is what makes 100MB files and 1000 cursors feasible. Line starts cached per node for O(log n) line↔offset mapping.

**Rendering pipeline:**
`Buffer → visible line range → LayoutCache (CTLine per line, invalidated by edit/width change) → draw(_:) into CALayer`. Only visible lines are ever shaped. Highlight spans applied as attributes before shaping. Cursor blink on its own layer, no full redraws. Target: <2ms frame at 120Hz for typical screens.

**Multi-cursor model:**
`Selection = [Region(anchor, head)]`, sorted, auto-merged on overlap. Every edit command maps over regions back-to-front so offsets stay valid. Undo records region set before/after.

**Syntax highlighting:**
Load `.sublime-syntax` (YAML, context/push/pop stack machine). Incremental: cache the context-stack at each line start; an edit re-highlights from the first line whose entry state changed, stopping when states re-converge. Runs on a background actor against a buffer snapshot; results applied by generation stamp (stale results dropped). Regex via NSRegularExpression first; custom DFA engine later if profiling demands.

**Command system as spine:**
Every user action = `Command` struct dispatched through a registry (name + JSON args). Keymap, menus, Command Palette, and macros are all just producers of commands. This gives contextual keybindings, macro record/replay, and a future plugin API for free.

**Indexing:**
Background actor walks project folders (respecting excludes), builds (a) filename index for Goto Anything fuzzy match, (b) symbol index from syntax-definition symbol scopes. FSEvents for invalidation. Persisted per-project in Application Support.

**Fuzzy matcher:** single shared scorer (Sublime-style: consecutive-run, word-boundary, camelCase bonuses; gap penalties) used by Goto Anything, palette, and autocomplete.

**Hot exit / sessions:** unsaved buffer contents + undo stacks + window/tab/cursor layout serialized to Application Support on change (debounced) and on quit. Restore on launch. No dialogs on quit — exactly Sublime's behavior.

**Extensibility (replacing Python):** phase 8 embeds JavaScriptCore (in the OS, offline, no dependency) exposing the command/event/view API. Build systems don't need it — they're JSON + `Process`.

### 2.4 Performance budget

| Operation | Target |
|---|---|
| Cold launch → window visible | < 150 ms |
| Open 100 MB file | < 1 s to first paint (lazy line index) |
| Keystroke → paint | < 8 ms (single cursor), < 16 ms (100 cursors) |
| Goto Anything over 100k files | < 50 ms per keystroke |
| Find-in-files, 1 GB project | streaming results, first hit < 200 ms |

---

## 3. Phased roadmap

Each phase yields a usable app. Estimates assume one experienced developer.

| Phase | Deliverable | Contents | Est. |
|---|---|---|---|
| **0** | Runnable shell *(scaffolded in this repo)* | SwiftPM + Makefile → `m_text.app`; window, menu, custom CoreText EditorView, gap-buffer typing, open/save | 1 wk |
| **1** | Real text engine | Piece tree, line index, encodings, undo/redo, atomic save, `NSTextInputClient` IME, large-file lazy load | 3 wk |
| **2** | Editor feel | Multi-cursor, `⌘D`, column select, bracket auto-pair, smart indent, line transforms, word wrap, line numbers/gutter | 3 wk |
| **3** | Syntax + themes | `.sublime-syntax` engine, incremental background highlight, `.sublime-color-scheme`, bundled grammars | 4 wk |
| **4** | Find | In-buffer find/replace bar (regex, incremental), find-in-files with streamed results buffer | 2 wk |
| **5** | Navigation | File/symbol indexer, Goto Anything (`@ : #`), command palette, fuzzy scorer, jump history | 3 wk |
| **6** | Workspace | Tabs, split panes, sidebar tree, projects, full session persistence + hot exit | 3 wk |
| **7** | Intelligence | Autocomplete, snippets w/ tab stops, folding, minimap, macros, build systems | 4 wk |
| **8** | Extensibility & polish | JavaScriptCore plugin API, spell check, diff gutter + revert hunk, vi mode, phantoms | 4+ wk |

**MVP = phases 0–6 (~15 weeks):** covers ≈90% of daily Sublime usage.

Full task-level breakdown with dependencies: see **TASKS.md**.

---

## 4. Build & run (no Xcode)

Requires only Command Line Tools (`xcode-select --install`).

```sh
make              # release build → build/m_text.app
make run          # build + open
make debug        # debug binary, runs in terminal (stdout logging)
make test         # run the suite (add FILTER=Name for a subset)
make test-release # optimised build, includes performance budgets
make clean
```

The Makefile compiles via `swift build`, assembles the `.app` bundle (binary + Info.plist + Resources), and ad-hoc signs with `codesign -s -`.

---

## 5. Risks

| Risk | Mitigation |
|---|---|
| IME/dead-key correctness in custom view | Implement full `NSTextInputClient` early (phase 1); test Vietnamese/Japanese/dead-key input explicitly |
| `.sublime-syntax` regex dialect (Oniguruma) differences | Start with NSRegularExpression + compatibility shims for common constructs (`\h`, possessive quantifiers); document unsupported grammars |
| Minimap cost on huge files | Render downsampled from highlight spans, not re-shaped text; throttle to scroll events |
| Scope creep (Sublime is 15 years of work) | Phase gates; every phase ships a usable editor |
