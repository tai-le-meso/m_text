# Changelog

Release notes live here, not in the workflow. `release.yml` extracts the section matching the
tag it is building and puts it in the GitHub release, so the notes are reviewed in a pull
request like everything else and cannot drift from what shipped.

**Add a section before tagging.** A tag with no matching section still releases — the notes
just fall back to the auto-generated commit list.

## 1.0.1

### Open several folders in one window

Folder handling now works the way Sublime Text's does:

- **Open Folder…** takes more than one folder into a single window.
- **Project ▸ Add Folder to Project…** adds folders to the window you are already in.
- **Remove Folder from Project** on a sidebar root takes that folder out of the window and
  leaves the directory on disk alone. Removing the last one closes the project.
- A folder nested inside a folder you already have open is allowed, matching Sublime — useful
  for keeping a deep subdirectory one click away.
- **Every folder is restored on relaunch.** Only the first one used to be, so the rest of a
  multi-folder window vanished when you quit.

### Fixed: the sidebar never appeared

Opening a folder looked like it did nothing at all. The folder tree was being built correctly,
but the sidebar was left at zero width, so the column was never on screen. It now gets a real
width when shown, remembers the width you drag it to, and collapses properly when hidden.

This affected every version before 1.0.1, not just multi-folder windows.

## 1.0.0

First release. A native macOS text editor in pure Swift and AppKit — no Electron, no web view,
no third-party dependencies.

Phases 1–7 complete:

- Multi-caret editing, TextMate grammars, Goto Anything and the command palette
- Split panes, tabs, sessions and hot exit
- Find and replace across a project, build systems, minimap, word wrap, code folding
- Spell check, diff gutter, inline annotations
- The m_text brand identity with a three-state light/dark appearance
