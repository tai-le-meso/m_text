# Changelog

Release notes live here, not in the workflow. `release.yml` extracts the section matching the
tag it is building and puts it in the GitHub release, so the notes are reviewed in a pull
request like everything else and cannot drift from what shipped.

**Add a section before tagging.** A tag with no matching section still releases — the notes
just fall back to the auto-generated commit list.

## 1.0.2

### Open folders like Sublime (phase 2)

- **Drag folders onto the window** — they join the project; dragged files open as tabs.
- **Finder ▸ Open With**, `open -a m_text <folder>`, and folders dropped on the Dock icon.
- **File ▸ Open Recent** — folders and project files, not individual documents.
- Opening a file that is already open now focuses that tab instead of opening a second one.

### The `mtext` shell command

`mtext .` opens the current folder, like `code .`. Install it from **Help ▸ Install “mtext”
Shell Command…** — no terminal, no admin rights. It goes to `~/.local/bin` (not
`/usr/local/bin`, which is unwritable on a managed Mac) and offers to add that directory to
your shell profile. The installed command points at the copy of m_text you installed it from,
and falls back to locating the app by bundle identifier if you move it.

### Project files are now `.mtext-project`

`.sublime-project` files still open — the format is identical — but nothing writes that
extension any more.

### Fixed

- `mtext .` opened the folder **twice** on a cold launch: macOS delivers the open request
  before the session has been restored, so the folder got a window of its own and the restore
  then added the session's. Requests that arrive early are now held until the restore is done.
- The `mtext` command only looked for m_text.app in `/Applications` and `~/Applications`, so
  keeping the app anywhere else broke it entirely.
- **Gatekeeper instructions were wrong for macOS 15 and later**, where right-click ▸ Open no
  longer works. Use System Settings ▸ Privacy & Security ▸ Open Anyway, or clear the
  quarantine attribute.

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
