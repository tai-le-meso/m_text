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
| Any pane/divider/sizing weirdness after adding a split | `NSSplitView` never lays out a newly added subview | [P1](#p1) |
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
