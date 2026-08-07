# m_text — Knowledge Base

**Read this first when something breaks.** `HANDOFF.md` says where the project stands;
this file says how to fix things that have broken before, and what has already been ruled
out so it doesn't get re-investigated from scratch.

Everything here was paid for the hard way. Each entry is symptom-first, because that is how
you will arrive: something looks wrong on screen and you don't yet know why.

---

## Symptom index

| What you see | Most likely cause | Section |
|---|---|---|
| Editor **and** tab bar go blank when ⌘F or ⌘P opens; status line still updates | An overlay resized the whole pane area | [S1](#s1) |
| ⌘F appears to do nothing after "Split View Right" | Zero-width pane; the bar mounted into it | [S2](#s2) |
| Find bar is on one side but searches/highlights the other; match count belongs to neither | `focusedPaneIndex` out of step with real focus | [S3](#s3) |
| ⌘F always opens on the same side regardless of which pane you're in | ⌘F trusted the stored focus index, not the editor that received it | [S3](#s3) |
| Text sits in a thin strip at the top; clicking below it does nothing | Document view frame collapsed to content size | [S4](#s4) |
| A palette/panel opens and looks right but typing never reaches it | Borderless window: `canBecomeKey` is false unless overridden | [S7](#s7) |
| Typing does nothing at all, every file, but menus/clicks/scroll still work | Delivery or focus, not handling — the smoke test **cannot** see this | [playbook 6](#playbook-6) |
| Window blank — editor, gutter **and** tab bar — but title and status line update | A zero-width sibling's unclipped layer painting over the pane | [S6](#s6) |
| Drawing looks correct in every trace but nothing appears | Dump the **layer** tree, not the view tree | [S6](#s6) |
| "Can't edit or do anything" — window fine, not crashed, but typing barely registers; only in big files | A full-buffer scan running on every keystroke | [S5](#s5) |
| App dies instantly on Settings (⌘,) — SIGTRAP, no error | A dispatch source handler running on the queue its work `sync`s onto | [S8](#s8) |
| Any pane/divider/sizing weirdness after adding a split | `NSSplitView` never lays out a newly added subview | [P1](#p1) |
| Open Folder… appears to do nothing — no sidebar, no tree | Sidebar unhidden but left at zero width | [P1](#p1) |
| A "fix" that changes focus appears to do nothing at all | `dismissFind()` steals first responder back | [P2](#p2) |
| Build fails right after moving a type or adding a `public` API | See [compile bug classes](#compile-bug-classes) | — |

---

## Diagnosis playbook

Use these **before** forming a theory. Five hypotheses died in S1 because they were
reasoned rather than measured.

### 1. Ask behavioural questions first — they're free and they cut the most

The two questions that finally cracked S1, after days of tree dumps:

- *Does Escape / undoing the trigger restore it?*
- *Does a different trigger (⌘P vs ⌘F) reproduce it?*

Between them they eliminated more of the search space than every dump combined, because
they isolate **what the two states have in common** rather than describing one state in
detail.

### 2. Drive the app programmatically instead of guessing

```bash
MTEXT_SMOKE_TEST=1 make debug      # asserted UI checks, exits non-zero on failure
```

`runSmokeTestIfRequested()` in `Sources/m_text/main.swift` drives the real window
controller through split → focus → find and asserts what broke before. **Extend it whenever
a UI bug escapes** — that is the entire point of it.

To investigate something new, add a temporary env-gated hook in the same place. Two traps:

- **`print` to a pipe is block-buffered.** A `timeout`-killed run loses everything. Call
  `setvbuf(stdout, nil, _IONBF, 0)` first.
- **Press keys the way the menu does**, i.e. `NSApp.sendAction(#selector(...), to:
  <firstResponder editor>, from: nil)` — *not* by calling the window controller's method.
  Those are different code paths; the controller's versions are only fallbacks used while
  the find field holds focus. Testing the wrong one is why S3 passed a green smoke test
  while still broken in the app.
- `NSApp.sendAction(..., to: nil, ...)` returns `false` in a terminal-launched app — there
  is no key window for the chain to search. That is a harness artifact, not a bug.

### 3. Dump view *and* layer trees

```bash
MTEXT_LAYOUT_DEBUG=1 make debug
```

`Sources/MTextUI/LayoutDiagnostics.swift` — `dump` (view tree), `dumpLayerTree` (CALayer
tree, which shows layers AppKit inserts that belong to no view), `trace` (one-liners).
**Deliberately no call sites**; add one where you need it and remove it after.

A clean view-tree dump proves less than it looks like: in S1 everything read correct in
*both* the working and broken states.

### 4. Suspect the session before the code

A restored session pins window/pane/focus state, so a bad state survives relaunches and
looks like a code bug.

```bash
python3 -c "import json,os;d=json.load(open(os.path.expanduser('~/Library/Application Support/m_text/Session/Session.json')));print([(w.get('focusedPaneIndex'),len(w.get('panes',[]))) for w in d['windows']])"
```

Deleting `~/Library/Application Support/m_text/Session/` resets it. This mattered in S2 and
S3: a window saved with an empty pane focused starts *every* launch focused there.

### 5. There is no automated UI coverage

`MTextTests` links **only `MTextCore`**, so nothing in `make test` can see a window. Every
severe bug in this project's history has lived in that gap. Proper `MTextUI` tests would
mean adding it to the test target and bootstrapping `NSApplication`, which would make
`make test` require a window server — the reason it hasn't been done. Until then the smoke
test is the safety net.

---

<a id="playbook-7"></a>
### 7. Do not trust `cacheDisplay` snapshots of this window

Reading pixels back is the obvious way to answer "did anything actually render", and
`bitmapImageRepForCachingDisplay` + `cacheDisplay` **does not answer it reliably here**.
Measured on the same build, minutes apart: an all-white bitmap, then one with 124k ink
pixels, then one fully transparent, then — per view, with `display()` forced first — one
entirely black. The tree is layer-backed, and layer contents are not dependably composited
into a cached-display bitmap.

It works *within* the `MTEXT_SMOKE_TEST` path (`smokeTestRenderedInkPixels` reliably shows
24.5k ink for an empty buffer versus 40.8k with text), so it is fine as a *relative*
assertion inside one run. It is not fine as evidence about what a user sees.

Two wrong conclusions were published from it before this was noticed: "every tab container
is HIDDEN" (the visible one was past a `head -40` cut) and "the window renders blank" (the
snapshot was simply empty). **If the question is what is on screen, ask for a real
screenshot** — ⌘⇧4 — rather than a snapshot the app takes of itself. `screencapture -l`
needs Screen Recording permission, which a terminal-launched process typically lacks.

Corollary: when an instrument disagrees with a user's report, suspect the instrument, and
re-measure before drawing any conclusion from it.

---

<a id="playbook-6"></a>
### 6. "Typing does nothing" — trace delivery, don't test handling

**The smoke test cannot reproduce this class of bug**, and it is important to know why: a
process launched from a terminal is never frontmost, so macOS refuses its window key status
(`isKeyWindow == false`, verified) and **never routes real key events to it**. The harness
therefore injects `NSEvent`s directly. That proves the editor *handles* keys; it says
nothing about whether the OS *delivers* them. "I type and nothing appears" lives exactly in
that gap, so a green smoke run does not clear it.

Use **`MTEXT_INPUT_DEBUG=1 make debug`** (`InputDiagnostics.swift`) and type in the window.
It logs, per keystroke: whether the app received the event at all (an app-level monitor,
ahead of the responder chain), whether the app is active and the window key, who holds first
responder, whether `EditorView.keyDown` was reached, whether the keymap swallowed it, and
whether `insertText` moved `document.generation`. **Whichever line stops appearing is the
layer that broke** — no event at all means delivery/focus, an event with no `keyDown` means
something upstream ate it, a `keyDown` with no `insertText` means the keymap or a command
handler, and an `insertText` that doesn't move the generation means the edit itself.

Ask the user for that log rather than theorising: it is how the ⌘F blank-pane bug was
finally cracked (S1), and the questions that cut hardest were behavioural, not technical.

---

## Solved issues

<a id="s1"></a>
### S1 — Editor and tab bar render blank when Find or a palette opens

**Symptom.** Press ⌘F (or open ⌘P / Goto Symbol) and the whole pane region — text *and* tab
bar — goes blank. Window chrome, find bar and status line render fine. The status line
stays live and correct (match counts update as you type), so document and search state are
healthy. No clicking or scrolling recovers it. Escape restores it.

**Root cause.** `FindBar` was a sibling of the entire pane split view at the window bottom,
so showing it resized **the whole pane area** — both panes, both tab bars, both editors.

**Fix.** Mount the find bar *inside* the focused pane, between the tab bar and the editor
(`Pane.findBarHost` + `MainWindowController.mountFindBar(in:)`). Showing it now resizes only
that pane's editor container — the smallest thing that has to change — and it matches where
Sublime and TextEdit put it.

**Ruled out with evidence — do NOT re-investigate.** Several of these fit *every* symptom
and were still wrong:

1. **Auto Layout ambiguity** — `hasAmbiguousLayout` false throughout, root included. (The
   only `AMBIGUOUS` hits are inside AppKit's own `NSTextView` internals in the find field.)
2. **Layer-backing / `wantsLayer`** — toggling it on `EditorView`/`TabBar`, and adding it at
   the window root, changed nothing.
3. **View geometry** — correct in both working and broken states.
4. **Drawing** — `draw(_:)` ran with the correct dirty rect and full line range *while blank*.
5. **`NSVisualEffectView` backdrop** behind each scroll view — removed via
   `drawsBackground = false`; still blank.
6. **Layer tree / `ContentLayer`** — clean and correctly sized in both states. See [P3](#p3):
   `ContentLayer` is normal and was misread, costing a wasted round.
7. **Layer size / memory** — a 5966×865 layer composited fine; 5966×825 did not.

**What actually pointed at the answer.** ⌘P reproduced it identically (a `Palette` is a
separate `NSPanel` that never resizes the editor, killing every resize-based theory), and
Escape restored it. Everything measurable at view and layer level was correct in both
states — which is exactly why five geometry/compositing hypotheses all failed.

<a id="s2"></a>
### S2 — ⌘F does nothing after "Split View Right"

**Symptom.** Reported as "loss action of Command F". ⌘F fires and nothing appears.

**Root cause A (pre-existing).** A classic `NSSplitView` **does not redistribute space when
a subview is added** — see [P1](#p1). The new pane kept its zero-sized frame at the right
edge, so every split produced a pane that was present, *focused*, and invisible. It survived
into the session file, so relaunching restored the broken state.

**Root cause B (introduced by S1's fix).** Because the find bar is now pane-local, it
inherits its pane's geometry. With a zero-width pane focused, ⌘F worked perfectly and mounted
the bar at the correct height and **zero width** — indistinguishable from nothing happening.

**Fix.** In `splitViewRight`: `adjustSubviews()` **plus** an explicit
`setPosition(_:ofDividerAt:)`. Matching `adjustSubviews()` in `removePane`. And
`constrainMaxCoordinate` now reserves 200pt for the trailing pane, so the divider can't be
*dragged* flush right to recreate it.

> Anything else moved into `Pane` inherits the same exposure to a broken pane.

<a id="s3"></a>
### S3 — Find bar sits in one pane while searching the other

**Symptom.** Bar is on the right, but typing searches and highlights the left document; the
match count (`1970 of 2600`) belongs to neither visible pane. Or: ⌘F *always* opens on the
same side no matter which pane you are working in.

**Root cause A.** `EditorView`'s mouse handler calls `window?.makeFirstResponder(self)`
directly, bypassing `MainWindowController.activate(_:)` — the only place that maintained
`focusedPaneIndex`. Clicking into the other pane moved keyboard focus but left the
controller believing the old pane was focused. Everything reading `focusedPane` then
described a pane the user had left: the status line, the find bar's target editor, and where
⌘F mounts.

**Root cause B.** Every `FindBarDelegate` method operates on `editor` (the *focused* pane's
active editor) while the bar stayed mounted wherever it was opened. Those diverge the moment
focus moves.

**Root cause C.** Even after A and B, ⌘F still opened on the wrong side, and the smoke test
passed throughout — the *model of the flow* was wrong, not the code under test.

**Fix.**
- `EditorView.onDidBecomeFirstResponder` → `focusedPaneDidChange(to:)` keeps
  `focusedPaneIndex` honest (idempotent, so `activate(_:)` doesn't recurse).
- `moveFindBarToFocusedPaneIfNeeded()` remounts the bar, called from `activate(_:)`,
  `focusedPaneDidChange(to:)` and `removePane`.
- **The one that actually fixed it:** `onFindRequested` now carries the editor that
  *received* ⌘F. The menu dispatches down the responder chain to the focused editor, so that
  editor is the ground truth for "which side am I searching". The controller syncs
  `focusedPaneIndex` to that editor's pane before mounting — correct by construction rather
  than by trusting focus tracking, and it repairs a stale index as a side effect.

**Lesson.** When two fixes don't resolve it and the test keeps passing, stop adding fixes:
**remove the assumption the bug depends on.**

<a id="s4"></a>
### S4 — Text confined to a thin strip; clicking below it does nothing

**Symptom.** Only a few lines' worth of editor responds; the rest of the viewport is inert
background. Looks completely normal on a short document.

**Root cause.** `updateFrameSize()` sets `max(viewport, content)`, but its first call comes
from `viewDidMoveToWindow`, *before* Auto Layout has resolved the scroll view's size — so
`enclosingScrollView?.contentSize` is zero and the frame collapses to pure content size
(e.g. 5966×**56** in an 825pt viewport). Nothing recomputed it on viewport resize, so it
stayed that way forever.

**Fix.** Observe `frameDidChangeNotification` on the clip view — **resizing is a different
notification from the scrolling** the existing observer watched — and call `updateFrameSize()`
from it, plus one immediate call to catch the size the clip view already has
(`EditorView.configureScrollView` / `clipFrameChanged`).

---

<a id="s5"></a>
### S5 — Editor unresponsive while typing in a large file

**Symptom.** Reported as "can't edit or create or take any actions for text". The window
looks normal and the app is not crashed or hung — every *keystroke* just takes long enough
that the editor feels dead. Small files are fine, so it looks intermittent.

**Root cause.** Two full-buffer scans ran on the keystroke path, both inside autocomplete
(T90), and both invisible to the existing tests:

- `BufferWordIndex.words(in:)` cached its scan against `TextDocument.generation`. That is
  the right key for `LayoutCache` and `HighlightService`, which are consulted while
  *drawing* — but this is consulted while *typing*, and `generation` bumps on every
  keypress, so the cache missed **every single time**. Its own doc comment claimed "a run
  of keystrokes reuses one scan"; the code never did that.
- `completionSymbols()` re-ran `SymbolExtractor.extractSymbols` over the whole document per
  keystroke, directly beneath a comment warning that walking the document from a keypress
  "is exactly the kind of thing that makes typing stutter".

Measured in a 20k-line file (the existing scan cap, so this is the bounded worst case):
**79 ms/key release, 154 ms/key debug** — ~85 ms of it symbols, the rest word scanning.

**Fix.** Neither scan runs during an edit. `words(in:)` serves the last completed scan and
never rescans itself; symbols are cached the same way. Both refresh on a 0.4 s idle timer
scheduled from `didEdit` and pushed back by each further edit, so a burst of typing costs
nothing and the rescan lands in the pause after it. `didReplaceDocument()` clears both
explicitly — they no longer self-invalidate on `generation`, so opening a new file would
otherwise offer the old file's words. Result: **5.4 ms/key release, 3 ms debug.**

**Why nothing caught it.** `PerformanceTests` *did* cover this area — but its "cached
lookup" loop re-queried 20 times **without editing in between**, so the cache trivially hit
and the real pattern (edit → query → edit → query) was never exercised. The lesson
generalises: a cache test that doesn't reproduce the caller's actual call *sequence* proves
nothing. Both the unit test and the smoke check were re-verified to fail against the
unfixed code (1.8 s vs one 0.09 s scan; 160 ms/key).

**If it recurs.** `MTEXT_SMOKE_TEST=1 make debug` now asserts a per-keystroke budget in a
20k-line buffer. To find *which* work returned, time the stages of `EditorView.didEdit` and
`insertText` — a temporary `lap()`-style print around each call is what located both of
these, and it took one run each. The remaining per-keystroke cost is the minimap (~5 ms
release), which redraws in full; that is the next thing to look at if this budget starts
being tight.

---

<a id="s6"></a>
### S6 — Whole window renders blank: editor, gutter and tab bar, while the status line works

**Symptom.** The window opens and is completely empty — no text, no gutter, no tab bar —
but the title bar and the status line (`Line 1, Column 60 · 1 lines`) update correctly.
Typing changes nothing on screen. Reported as "can't create new tabs and can't enter any
text — no display or interaction at all".

**It is not an input bug.** `MTEXT_INPUT_DEBUG=1` showed the entire keyboard path healthy:
events delivered, window key, first responder the editor, `keyDown` reached, `insertText`
run, and `document.generation` moving on every keystroke. ⌘T created tabs too. The model was
always correct; only the screen was wrong.

**Root cause — `CALayer` does not clip its sublayers unless told to.** T93's minimap is
collapsed to zero width by a width constraint when it is off, rather than removed. A
zero-width *view* still has a backing layer, and AppKit's backing store kept a full-size
`ContentLayer` for it. Unclipped, that layer was composited at an offset covering the entire
pane **and 32pt above it — exactly the tab bar**:

```
Minimap      (1263, 0,   0, 727)  has-contents ZERO-SIZE   <- the view, correctly collapsed
  ContentLayer (-1263, -32, 1263, 759) has-contents        <- painted over the whole pane
```

**Fix.** `layer?.masksToBounds = true` in `Minimap.init` — that is the real fix. The view is
also now `isHidden` when disabled rather than merely zero-width, since a zero-width view
still draws.

**Why it took so long, and what to do differently.** Every view-level signal was healthy and
stayed healthy throughout: frames correct, exactly one tab container visible and correctly
sized, `draw(_:)` running with the right dirty rects, the cached line text matching the
document, `#FFFFFF` glyphs on `#1E1E1E`, `wantsLayer` with opacity 1 and nothing hidden — and
the editor's own rasterised layer contained 56 distinct colours, i.e. real antialiased text.
**The editor was drawing perfectly and something else was painting over it.** No amount of
inspecting views could show that; only the *layer* tree could, and dumping it found the fault
immediately.

So: **when drawing looks correct but nothing appears, dump the layer tree, not the view
tree** (`MTEXT_RENDER_DUMP=1`). And when a sibling view is involved, suspect an unclipped
layer before suspecting the view that looks blank.

**Regression check.** `smokeTestLayerEscapingItsView()` fails if any of this project's own
views has an unclipped sublayer with contents outside its bounds. Verified to fail against
the unfixed code with the exact frames above. It is scoped to non-`NS` classes deliberately:
AppKit's own controls legitimately overflow (a label's content layer carries ascenders).

**What found it.** Bisecting with the user as the oracle — pre-T28 build vs T28 vs T93 —
because no local instrument could reproduce a blank screen. Three builds, two rounds, exact
commit. That was worth far more than any further code reading.

---

<a id="s7"></a>
### S7 — Command Palette (and Goto Anything) open but never search

**Symptom.** ⌘⇧P / ⌘P show the palette, correctly positioned and populated with every
command, and typing does nothing: the field stays empty and the list never filters.

**Root cause.** `Palette` built its window as a plain `NSPanel` with a `.borderless` style
mask. **`NSWindow.canBecomeKey` is false for a window with no title bar**, and a borderless
`NSPanel` inherits that unchanged — measured `canBecomeKey == false`. A non-key window is
never sent key events, so the keystrokes went to whatever was key instead.

What makes this hard to spot: everything else looks healthy. The panel orders front, draws,
positions itself, lists 117 commands — and `panel.makeFirstResponder(searchField)` *succeeds*,
so the field genuinely reports focus. Focus within a window that cannot become key still
receives nothing.

**Fix.** A `PalettePanel: NSPanel` subclass overriding `canBecomeKey` to `true` (and
`canBecomeMain` to `false`, so the document window keeps its active title bar). One override;
both ⌘P and ⌘⇧P share the single `Palette` instance.

**Not to be confused with `CompletionPopup`**, which is also a borderless panel and must
*stay* unable to take focus — it uses `.nonactivatingPanel` deliberately so the editor keeps
looking and behaving focused while the list is up. Autocomplete keys are handled in
`EditorView.doCommand`, not by the popup.

**Present since the initial commit.** It survived because nothing tested typing into anything
but an editor. The smoke test now asserts `canBecomeKey`, that the field takes focus, that a
real key event reaches it, and that the list actually narrows (117 → 3 for "appear").

---

<a id="s8"></a>
### S8 — Opening Settings kills the app instantly

**Symptom.** ⌘, or m_text ▸ Settings… and the app vanishes. The crash report says
`EXC_BREAKPOINT (SIGTRAP)` with `__DISPATCH_WAIT_FOR_QUEUE__` at the top of the faulting
thread — not a nil unwrap, not a range error. Present in every release up to 1.0.3.

**Root cause — a deadlock, not a crash.** `SettingsStore` watches its directory with a
`DispatchSource` created as `queue: queue`, the *same* serial queue `reload()` blocks on:

```swift
source = DispatchSource.makeFileSystemObjectSource(..., queue: queue)   // handler runs ON queue
source.setEventHandler { self.reload() }                                 // reload does queue.sync
```

`queue.sync` from a block already executing on `queue` is a deadlock, and libdispatch detects
it and traps — which is why it looks like an instant crash rather than a hang.

Opening Settings is what fires it: the command *writes the generated defaults file into the
very directory being watched*, so the handler runs, calls `reload()`, and dies.

**Fix.** Give the source its own queue (`watchQueue`). `reload()` then stays safe to call
from anywhere, including the main thread.

**Corroboration worth knowing about.** Each crash left an orphaned
`Default.sublime-settings.sb-XXXXXX` temp file in the user settings directory — an atomic
write killed mid-rename. Four of them had accumulated, one per crash, with timestamps
matching the crash reports. **That debris was noticed twice earlier in the project and
written off as "a settings write failed at some point"** — it was this, and the file dates
would have led straight here.

**Regression test.** `SettingsTests.testWatchDoesNotDeadlock` writes into a watched temp
directory and waits for `onChange` with a timeout, pumping the run loop because the callback
is delivered on main. Verified against the unfixed code: the whole test binary dies with
`Trace/BPT trap: 5`, the same signal as the user's report.

**The general rule.** A `DispatchSource`'s handler queue and any queue that handler `sync`s
onto must be different. Grep for `queue:` at source creation and check it against every
`.sync` reachable from the handler.

---

## AppKit pitfalls

<a id="p1"></a>
### P1 — Classic `NSSplitView` does not lay out a newly added arranged subview

It keeps its zero-sized frame at the trailing edge. `adjustSubviews()` alone **won't** rescue
it either: it distributes *proportionally*, and a zero-width subview's share of the
proportion is zero.

```swift
splitView.addSubview(pane.view)
splitView.adjustSubviews()
splitView.setPosition(splitView.bounds.width / 2, ofDividerAt: 0)   // required
```

Also implement `constrainMaxCoordinate` to reserve a minimum for the *trailing* subview, or
the divider can be dragged flush to the edge and reproduce it by hand. This is not a compile
error — it silently produces a focused, invisible pane.

<a id="p2"></a>

**The same bug bit the sidebar, and hid a whole feature.** `setProject` and `toggleSidebar`
both set `sidebar.isHidden = false` and called `adjustSubviews()`. The sidebar starts hidden
at zero width, `adjustSubviews()` redistributes *proportionally*, and zero stays zero — so
"Open Folder…" populated the outline view correctly and **nothing appeared on screen**. It
looked like the command did nothing. Showing it needs an explicit
`setPosition(width, ofDividerAt: 0)`.

**Hiding it is not the mirror image.** `setPosition(0, ofDividerAt: 0)` does *not* hide it
here: the delegate's `constrainMinCoordinate` clamps the position up to the 160pt minimum,
and giving a split view a position also un-collapses the subview — so hiding left a 160pt
strip. Hide with `isHidden` + `adjustSubviews()` (which collapses to zero correctly) and set
a position only when showing.

**What let it survive**: the smoke check counted sidebar *rows*, which is happily non-zero
while the column is zero-width and invisible. Assert the on-screen width, not just the model.
Same lesson as S6 — geometry that reads correct is not the same as pixels on screen.
### P2 — `dismissFind()` steals first responder

`EditorView.dismissFind()` ends with `window?.makeFirstResponder(self)`. That is right for
Escape ("close find, put me back in the text") and **wrong** anywhere focus is being moved
deliberately: it snaps focus back and silently undoes the change, making a correct-looking
fix behave as a total no-op.

Use `clearSearchHighlights()` — the focus-neutral sibling — when clearing a pane the find
bar is leaving. **Keep the two distinct; do not "simplify" one into the other.**

<a id="p3"></a>
### P3 — A delegate-less `ContentLayer` sublayer is normal

It is simply where AppKit stores a view's drawn contents, and it appears under ordinary
labels and text fields too. It is **not** responsive-scrolling tiling and not evidence of
anything wrong. Misreading it cost a wasted round on
`isCompatibleWithResponsiveScrolling` in S1.

### P4 — `NSClipView` no longer redraws revealed area on resize

`copiesOnScroll` has been a no-op since macOS 11, so a viewport resize leaves the newly
revealed strip unpainted until something else happens to invalidate it. `EditorView`
compensates in `clipBoundsChanged`/`clipFrameChanged`.

### P5 — Don't force `displayIfNeeded()` mid-resize on a layer-backed view

Three such calls were added during S1 on a theory that was then disproven; they never fixed
anything, and forcing display outside the normal CoreAnimation cycle is itself a plausible
way to strand a backing store. Removed.

### P6 — Invalidate `visibleRect`, not full bounds, on a large document view

`needsDisplay = true` on a 5966pt-wide editor invalidates thousands of points nobody can
see. Prefer `setNeedsDisplay(visibleRect)`.

---

<a id="compile-bug-classes"></a>
## Compile-time bug classes

Each of these has bitten more than once.

1. **Missing explicit `public init`.** A `public struct`'s memberwise init is only
   *internal*, so `MTextTests`/`MTextUI` can't see it. Burned `FileIndex.Entry`,
   `FuzzyMatcher.Match`, nearly `Session*`. Same for `public static func`.
2. **`private` is file-scoped, not type-scoped.** Moving a type into its own file breaks
   `private` access from what used to be the same file (this is why `Tab` is `internal`).
3. **Implicitly-unwrapped-optional tuple inference.** `let x = (tab: activeTab, ...)` where
   `activeTab: Tab!` infers `Tab?`, not `Tab`. Annotate the binding explicitly.
4. **macOS symlinks.** `/tmp`, `/var`, `/etc` are symlinks to `/private/...`. Use
   `.resolvingSymlinksInPath()`, **not** `.standardizedFileURL` (which only collapses
   `.`/`..`), whenever comparing paths. Broke `FileIndexTests`, recurred in `Sidebar.reveal`.
5. **`@objc` requires NSObject inheritance** — selector-based `NotificationCenter`
   observation needs the class to inherit `NSObject` (caught in `SessionManager`).
6. **Grep build output for `warning:` too, not just `error:`.** A `swift build | grep error`
   habit hides warnings completely — a `var` that should be `let` sat in `BuildSystem.swift`
   for a whole task before the user spotted it. `swift build 2>&1 | grep -E "warning:|error:"`,
   and note that an incremental build only re-reports diagnostics for files it recompiles, so
   clear `.build/debug` (or `-c release`) when you want the true count.
7. **SourceKit lags behind `swift build`.** Editor diagnostics showing "cannot find type X in
   scope" for a type you just added are usually stale index, not a real error. Trust
   `swift build`.

---

## Working practices that paid off

- **Behavioural questions before state dumps.** See the playbook — this is the single
  highest-yield habit in this file.
- **Beware theories that explain everything.** Every failed S1 hypothesis accounted for every
  symptom then known. A theory earns confidence by predicting something *not yet observed*,
  not by fitting what already is.
- **A test that has never failed is not evidence.** Verify each new smoke-test assertion
  actually fails against the un-fixed code before keeping it. Every assertion currently in
  the smoke test was checked this way.
- **When fixes stack up and the test still passes, the model is wrong.** Remove the
  assumption rather than adding a third fix (S3, cause C).
- **Delete disproven fixes, and correct their comments.** Leaving them makes the next reader
  believe a dead theory. Several comments in this codebase had to be rewritten for exactly
  this reason.
- **Use subagents for code review before handing anything over to build.** Every review round
  found real bugs (an fd leak in `Sidebar.watchDirectory`, the symlink regression, a session
  data-loss bug).
- **`make debug`, never `make run`, when you need logs** — `make run` detaches via `open` and
  swallows output.
- **Explanatory comments here are load-bearing.** They record *why* a non-obvious choice was
  made (scope cuts, AppKit workarounds, bug history). Match that style rather than stripping
  it.
