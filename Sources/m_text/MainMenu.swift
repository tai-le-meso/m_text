import AppKit
import MTextCore
import MTextUI

/// Builds the main menu programmatically (no nib). Items with nil targets resolve
/// through the responder chain — editing actions land on EditorView, file actions
/// on MainWindowController.
func makeMainMenu() -> NSMenu {
    let main = NSMenu()
    main.addItem(submenu(appMenu(), title: "m_text"))
    main.addItem(submenu(fileMenu(), title: "File"))
    main.addItem(submenu(projectMenu(), title: "Project"))
    main.addItem(submenu(editMenu(), title: "Edit"))
    main.addItem(submenu(selectionMenu(), title: "Selection"))
    main.addItem(submenu(findMenu(), title: "Find"))
    main.addItem(submenu(gotoMenu(), title: "Goto"))
    main.addItem(submenu(viewMenu(), title: "View"))
    main.addItem(submenu(buildMenu(), title: "Build"))
    main.addItem(submenu(syntaxMenu(), title: "Syntax"))
    let window = windowMenu()
    NSApplication.shared.windowsMenu = window
    main.addItem(submenu(window, title: "Window"))
    return main
}

// MARK: - Menus

private func appMenu() -> NSMenu {
    let menu = NSMenu()
    menu.addItem(withTitle: "About m_text",
                 action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                 keyEquivalent: "")
    menu.addItem(.separator())
    // T86. Titled "Settings…" to match current macOS (System Settings, and Apple's own
    // apps since Ventura) rather than Sublime's "Preferences"; ⌘, is the platform
    // standard either way. The Command Palette lists it as written here.
    menu.addItem(withTitle: "Settings…",
                 action: #selector(MainWindowController.openPreferences(_:)),
                 keyEquivalent: ",")
    menu.addItem(.separator())
    menu.addItem(withTitle: "Hide m_text", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit m_text", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    return menu
}

private func fileMenu() -> NSMenu {
    let menu = NSMenu(title: "File")
    menu.addItem(withTitle: "New Tab", action: #selector(MainWindowController.newTab(_:)), keyEquivalent: "t")
    menu.addItem(withTitle: "New Window", action: #selector(AppDelegate.newWindow(_:)), keyEquivalent: "n")
    menu.addItem(withTitle: "Open…", action: #selector(MainWindowController.openDocument(_:)), keyEquivalent: "o")
    menu.addItem(.separator())
    menu.addItem(withTitle: "Save", action: #selector(MainWindowController.saveDocument(_:)), keyEquivalent: "s")
    menu.addItem(item("Save As…", #selector(MainWindowController.saveDocumentAs(_:)), "s", [.command, .shift]))
    menu.addItem(.separator())
    // ⌘W closes the active *tab* (closing the window's last tab closes the window
    // itself — see `MainWindowController.closeActiveTab`); ⌘⇧W is the direct escape
    // hatch to close the whole window regardless of how many tabs it has open.
    menu.addItem(withTitle: "Close Tab", action: #selector(MainWindowController.closeActiveTab(_:)), keyEquivalent: "w")
    menu.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]))

    // Hidden alternate: see the equivalent comment in `findMenu` — plain Control+T is
    // unbound system-wide, so without this it would silently do nothing rather than
    // opening a tab, for anyone used to Ctrl+T from other editors and browsers.
    menu.addItem(hidden("New Tab (Ctrl)", #selector(MainWindowController.newTab(_:)), "t", [.control]))
    return menu
}

private func projectMenu() -> NSMenu {
    let menu = NSMenu(title: "Project")
    menu.addItem(withTitle: "Open Folder…",
                 action: #selector(MainWindowController.openFolder(_:)), keyEquivalent: "")
    menu.addItem(withTitle: "Switch Project…",
                 action: #selector(MainWindowController.switchProject(_:)), keyEquivalent: "")
    menu.addItem(withTitle: "Close Project",
                 action: #selector(MainWindowController.closeProject(_:)), keyEquivalent: "")
    return menu
}

private func editMenu() -> NSMenu {
    let menu = NSMenu(title: "Edit")
    menu.addItem(withTitle: "Undo", action: #selector(EditorView.undo(_:)), keyEquivalent: "z")
    menu.addItem(item("Redo", #selector(EditorView.redo(_:)), "z", [.command, .shift]))
    menu.addItem(.separator())
    menu.addItem(withTitle: "Cut", action: #selector(EditorView.cut(_:)), keyEquivalent: "x")
    menu.addItem(withTitle: "Copy", action: #selector(EditorView.copy(_:)), keyEquivalent: "c")
    menu.addItem(withTitle: "Paste", action: #selector(EditorView.paste(_:)), keyEquivalent: "v")
    menu.addItem(.separator())

    let line = NSMenu(title: "Line")
    line.addItem(item("Indent", #selector(EditorView.indentSelection(_:)), "]", [.command]))
    line.addItem(item("Unindent", #selector(EditorView.outdentSelection(_:)), "[", [.command]))
    line.addItem(.separator())
    line.addItem(item("Swap Line Up", #selector(EditorView.moveLineUp(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command, .control]))
    line.addItem(item("Swap Line Down", #selector(EditorView.moveLineDown(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command, .control]))
    line.addItem(item("Duplicate Line", #selector(EditorView.duplicateLine(_:)), "d", [.command, .shift]))
    line.addItem(item("Delete Line", #selector(EditorView.deleteLine(_:)), "k", [.command, .control]))
    line.addItem(item("Join Lines", #selector(EditorView.joinLines(_:)), "j", [.command]))
    menu.addItem(submenu(line, title: "Line"))

    let sort = NSMenu(title: "Sort")
    sort.addItem(withTitle: "Sort Lines", action: #selector(EditorView.sortLines(_:)), keyEquivalent: "")
    sort.addItem(withTitle: "Sort Lines (Case Insensitive)",
                 action: #selector(EditorView.sortLinesCaseInsensitive(_:)), keyEquivalent: "")
    sort.addItem(withTitle: "Reverse Lines", action: #selector(EditorView.reverseLines(_:)), keyEquivalent: "")
    sort.addItem(withTitle: "Unique Lines", action: #selector(EditorView.uniqueLines(_:)), keyEquivalent: "")
    menu.addItem(submenu(sort, title: "Sort"))

    let convert = NSMenu(title: "Convert Case")
    convert.addItem(item("Upper Case", #selector(EditorView.uppercaseSelection(_:)), "u", [.command, .shift]))
    convert.addItem(item("Lower Case", #selector(EditorView.lowercaseSelection(_:)), "u", [.command, .control]))
    convert.addItem(withTitle: "Title Case", action: #selector(EditorView.titlecaseSelection(_:)), keyEquivalent: "")
    convert.addItem(withTitle: "Swap Case", action: #selector(EditorView.swapCaseSelection(_:)), keyEquivalent: "")
    menu.addItem(submenu(convert, title: "Convert Case"))

    menu.addItem(.separator())
    menu.addItem(item("Toggle Comment", #selector(EditorView.toggleComment(_:)), "/", [.command]))
    menu.addItem(.separator())
    // T90. ⌃Space is Sublime's binding and forces the list open regardless of the
    // `auto_complete` setting or how few characters have been typed. Worth knowing: macOS
    // may already use ⌃Space to switch input sources, in which case the system wins and
    // this item is still reachable from the menu and the Command Palette.
    menu.addItem(item("Complete", #selector(EditorView.showCompletions(_:)), " ", [.control]))
    // T91. No key equivalent: snippets are normally reached by typing a tab trigger and
    // pressing Tab; this is the discovery path for the ones you haven't memorised, and it
    // shows up in the Command Palette like every other menu item.
    menu.addItem(withTitle: "Insert Snippet…",
                 action: #selector(MainWindowController.insertSnippet(_:)),
                 keyEquivalent: "")
    menu.addItem(.separator())

    // T94. ⌃⌘Q / ⌃⌘P are Sublime's own macro bindings. Record is one toggle rather than
    // separate start/stop items — "am I recording?" is the only state to convey, and the
    // menu title says which it is via `validateMenuItem`.
    let macro = NSMenu(title: "Macro")
    macro.addItem(item("Record Macro", #selector(EditorView.toggleMacroRecording(_:)), "q", [.command, .control]))
    macro.addItem(item("Playback Macro", #selector(EditorView.playbackMacro(_:)), "p", [.command, .control]))
    macro.addItem(.separator())
    macro.addItem(withTitle: "Save Macro…",
                  action: #selector(MainWindowController.saveMacro(_:)), keyEquivalent: "")
    macro.addItem(withTitle: "Open Macro…",
                  action: #selector(MainWindowController.openMacro(_:)), keyEquivalent: "")
    menu.addItem(submenu(macro, title: "Macro"))
    return menu
}

private func selectionMenu() -> NSMenu {
    let menu = NSMenu(title: "Selection")
    menu.addItem(withTitle: "Select All", action: #selector(EditorView.selectAll(_:)), keyEquivalent: "a")
    menu.addItem(item("Expand Selection to Line", #selector(EditorView.expandSelectionToLine(_:)), "l", [.command]))
    menu.addItem(item("Expand Selection to Word", #selector(EditorView.expandSelectionToWord(_:)), "w", [.command, .control]))
    menu.addItem(.separator())
    menu.addItem(item("Expand Selection to Next Match", #selector(EditorView.selectNextOccurrence(_:)), "d", [.command]))
    menu.addItem(item("Find All Under Selection", #selector(EditorView.selectAllOccurrences(_:)), "g", [.command, .control]))
    menu.addItem(item("Split into Lines", #selector(EditorView.splitSelectionIntoLines(_:)), "l", [.command, .shift]))
    menu.addItem(.separator())
    menu.addItem(item("Add Cursor Above", #selector(EditorView.addCaretAbove(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.control, .shift]))
    menu.addItem(item("Add Cursor Below", #selector(EditorView.addCaretBelow(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.control, .shift]))
    menu.addItem(withTitle: "Single Selection",
                 action: #selector(EditorView.collapseToSingleCaret(_:)), keyEquivalent: "\u{1B}")
    return menu
}

private func findMenu() -> NSMenu {
    let menu = NSMenu(title: "Find")
    menu.addItem(withTitle: "Find…", action: #selector(EditorView.performFind(_:)), keyEquivalent: "f")
    menu.addItem(item("Find and Replace…", #selector(EditorView.performFindAndReplace(_:)),
                      "f", [.command, .option]))
    menu.addItem(.separator())
    menu.addItem(withTitle: "Find Next",
                 action: #selector(EditorView.findNextMatch(_:)), keyEquivalent: "g")
    menu.addItem(item("Find Previous", #selector(EditorView.findPreviousMatch(_:)),
                      "g", [.command, .shift]))
    menu.addItem(withTitle: "Use Selection for Find",
                 action: #selector(EditorView.useSelectionForFind(_:)), keyEquivalent: "e")
    menu.addItem(.separator())
    menu.addItem(item("Find in Files…", #selector(MainWindowController.findInFiles(_:)),
                      "f", [.command, .shift]))
    // T65. Deliberately a longer chord than Find in Files: this one writes to files that
    // aren't open. It previews into a tab and asks before writing anything.
    menu.addItem(item("Replace in Files…", #selector(MainWindowController.replaceInFiles(_:)),
                      "f", [.command, .shift, .option]))
    menu.addItem(withTitle: "Find All",
                 action: #selector(EditorView.selectAllMatches(_:)), keyEquivalent: "")

    // Hidden alternates: plain Control+F/G is the system's default text-navigation
    // binding (moveForward:/moveDown:), not Find, so it silently does nothing in
    // EditorView's doCommand(by:) unless explicitly bound here too. Added for muscle
    // memory from Windows/Linux editors and browsers; hidden so the menu still shows
    // ⌘F/⌘G as the canonical shortcut, but both key equivalents fire the same action.
    menu.addItem(hidden("Find… (Ctrl)", #selector(EditorView.performFind(_:)), "f", [.control]))
    menu.addItem(hidden("Find Next (Ctrl)", #selector(EditorView.findNextMatch(_:)), "g", [.control]))
    menu.addItem(hidden("Find Previous (Ctrl)", #selector(EditorView.findPreviousMatch(_:)),
                        "g", [.control, .shift]))
    return menu
}

private func gotoMenu() -> NSMenu {
    let menu = NSMenu(title: "Goto")
    menu.addItem(withTitle: "Goto Anything…",
                 action: #selector(MainWindowController.showGotoAnything(_:)), keyEquivalent: "p")
    menu.addItem(item("Goto Symbol in Project…",
                      #selector(MainWindowController.showGotoSymbolInProject(_:)), "r", [.command, .shift]))
    menu.addItem(item("Goto Definition", #selector(MainWindowController.gotoDefinition(_:)),
                      String(UnicodeScalar(NSF12FunctionKey)!), []))
    menu.addItem(.separator())
    menu.addItem(item("Back", #selector(MainWindowController.jumpToPreviousLocation(_:)), "-", [.control]))
    menu.addItem(item("Forward", #selector(MainWindowController.jumpToNextLocation(_:)), "-", [.control, .shift]))
    return menu
}

/// T95. Its own top-level menu, like Sublime's — build commands are not View or Edit
/// actions, and F4/⇧F4 for error navigation are the platform convention.
private func buildMenu() -> NSMenu {
    let menu = NSMenu(title: "Build")
    menu.addItem(withTitle: "Build", action: #selector(MainWindowController.build(_:)), keyEquivalent: "b")
    menu.addItem(item("Build With…", #selector(MainWindowController.chooseBuildSystem(_:)), "b", [.command, .shift]))
    menu.addItem(item("Cancel Build", #selector(MainWindowController.cancelBuild(_:)), "c", [.command, .control]))
    menu.addItem(.separator())
    menu.addItem(item("Next Error", #selector(MainWindowController.nextBuildError(_:)),
                      String(UnicodeScalar(NSF4FunctionKey)!), []))
    menu.addItem(item("Previous Error", #selector(MainWindowController.previousBuildError(_:)),
                      String(UnicodeScalar(NSF4FunctionKey)!), [.shift]))
    menu.addItem(.separator())
    menu.addItem(withTitle: "Toggle Build Output",
                 action: #selector(MainWindowController.toggleBuildPanel(_:)), keyEquivalent: "")
    return menu
}

private func viewMenu() -> NSMenu {
    let menu = NSMenu(title: "View")
    menu.addItem(item("Command Palette…", #selector(MainWindowController.showCommandPalette(_:)),
                      "p", [.command, .shift]))
    menu.addItem(.separator())
    // No keyEquivalent here: the real shortcut is the ⌘K ⌘B *chord* bound in
    // DefaultKeymap.swift — a two-key sequence, which a plain NSMenuItem keyEquivalent
    // can't express at all (only a single keystroke-with-modifiers).
    menu.addItem(withTitle: "Toggle Sidebar", action: #selector(MainWindowController.toggleSidebar(_:)),
                 keyEquivalent: "")
    menu.addItem(withTitle: "Split View Right",
                 action: #selector(MainWindowController.splitViewRight(_:)), keyEquivalent: "")
    menu.addItem(withTitle: "Close Pane",
                 action: #selector(MainWindowController.closeCurrentPane(_:)), keyEquivalent: "")
    menu.addItem(.separator())
    // T92. ⌥⌘[ / ⌥⌘] are Sublime's own fold shortcuts. Fold Level uses `tag` for the
    // depth so one action serves all four items.
    let fold = NSMenu(title: "Fold")
    fold.addItem(item("Fold", #selector(EditorView.foldAtCaret(_:)), "[", [.command, .option]))
    fold.addItem(item("Unfold", #selector(EditorView.unfoldAtCaret(_:)), "]", [.command, .option]))
    fold.addItem(.separator())
    fold.addItem(item("Fold All", #selector(EditorView.foldAll(_:)), "[", [.command, .option, .shift]))
    fold.addItem(item("Unfold All", #selector(EditorView.unfoldAll(_:)), "]", [.command, .option, .shift]))
    fold.addItem(.separator())
    for level in 1 ... 4 {
        let levelItem = NSMenuItem(title: "Fold Level \(level)",
                                   action: #selector(EditorView.foldLevel(_:)), keyEquivalent: "")
        levelItem.tag = level
        fold.addItem(levelItem)
    }
    menu.addItem(submenu(fold, title: "Fold"))
    menu.addItem(.separator())
    menu.addItem(withTitle: "Show Line Numbers", action: #selector(EditorView.toggleGutter(_:)), keyEquivalent: "")
    menu.addItem(withTitle: "Show Invisibles", action: #selector(EditorView.toggleInvisibles(_:)), keyEquivalent: "")
    // T28. ⌥⌘W is Sublime's binding for Word Wrap.
    menu.addItem(item("Word Wrap", #selector(EditorView.toggleWordWrap(_:)), "w", [.command, .option]))
    // T93. No key equivalent — Sublime doesn't bind one either; it lives in the menu and
    // therefore the Command Palette.
    menu.addItem(withTitle: "Minimap", action: #selector(EditorView.toggleMinimap(_:)), keyEquivalent: "")
    menu.addItem(.separator())
    menu.addItem(withTitle: "Increase Font Size",
                 action: #selector(EditorView.increaseFontSize(_:)), keyEquivalent: "+")
    menu.addItem(withTitle: "Decrease Font Size",
                 action: #selector(EditorView.decreaseFontSize(_:)), keyEquivalent: "-")
    menu.addItem(withTitle: "Reset Font Size",
                 action: #selector(EditorView.resetFontSize(_:)), keyEquivalent: "0")
    return menu
}

/// Populated on demand by SyntaxMenuController, so a grammar imported mid-session shows
/// up without a restart. Also carries the import commands.
private func syntaxMenu() -> NSMenu {
    let menu = NSMenu(title: "Syntax")
    menu.delegate = SyntaxMenuController.shared
    // Seeded so the menu has a sensible width before it is first opened.
    menu.addItem(withTitle: "Import Syntax…", action: nil, keyEquivalent: "")
    return menu
}

private func windowMenu() -> NSMenu {
    let menu = NSMenu(title: "Window")
    menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
    menu.addItem(.separator())
    menu.addItem(item("Show Next Tab", #selector(MainWindowController.selectNextTab(_:)),
                      "]", [.command, .shift]))
    menu.addItem(item("Show Previous Tab", #selector(MainWindowController.selectPreviousTab(_:)),
                      "[", [.command, .shift]))

    // Hidden ⌘1–⌘9 jump-to-tab shortcuts (9 = last tab, the browser convention this is
    // borrowed from). Not shown directly since a visible item can't relabel itself per
    // window as tabs open and close; `selectTabByTag` reads which one fired from `tag`.
    for tag in 1 ... 9 {
        let key = String(tag)
        let menuItem = item("Tab \(tag)", #selector(MainWindowController.selectTabByTag(_:)), key, [.command])
        menuItem.tag = tag
        menuItem.isHidden = true
        menu.addItem(menuItem)
    }
    return menu
}

// MARK: - Helpers

private func item(_ title: String,
                  _ action: Selector,
                  _ key: String,
                  _ modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
    let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
    menuItem.keyEquivalentModifierMask = modifiers
    return menuItem
}

/// A menu item that never appears but still fires its key equivalent — AppKit
/// dispatches hidden items' shortcuts normally, it just excludes them from display.
private func hidden(_ title: String,
                    _ action: Selector,
                    _ key: String,
                    _ modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
    let menuItem = item(title, action, key, modifiers)
    menuItem.isHidden = true
    return menuItem
}

private func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
    let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    menuItem.submenu = menu
    return menuItem
}
