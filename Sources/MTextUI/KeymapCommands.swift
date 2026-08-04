import AppKit

/// Maps a `.sublime-keymap` `"command"` string to the selector it should invoke,
/// dispatched the same way the Command Palette dispatches a menu item (via
/// `NSApp.sendAction`) — see `MainWindowController.dispatchKeymapCommand(_:args:)`.
///
/// Kept as its own table, separate from `CommandRegistry` (which maps human-readable
/// *menu titles* to their menu items for the Command Palette): Sublime's command names
/// are a distinct, stable, snake_case vocabulary that predates and doesn't track this
/// app's menu wording, so the two mappings would drift apart immediately if merged.
///
/// A binding whose command isn't in this table (or, for `show_overlay`, whose `args`
/// don't match a case below) is silently ignored — not every hypothetical Sublime
/// command has an equivalent here.
public enum KeymapCommands {

    public static func selector(forCommand name: String, args: [String: Any]?) -> Selector? {
        // Real Sublime overloads a single command, `show_overlay`, for all three of
        // Goto Anything / Goto Symbol in Project / Command Palette, distinguished only
        // by `args["overlay"]` — special-cased here since it's central enough to
        // imported keymaps to be worth the extra branch, unlike every other command
        // below, none of which vary their behavior by argument.
        if name == "show_overlay" {
            switch args?["overlay"] as? String {
            case "command_palette": return #selector(MainWindowController.showCommandPalette(_:))
            case "goto_symbol_in_project": return #selector(MainWindowController.showGotoSymbolInProject(_:))
            default: return #selector(MainWindowController.showGotoAnything(_:)) // "goto", or unspecified
            }
        }
        return table[name]
    }

    private static let table: [String: Selector] = [
        "new_tab": #selector(MainWindowController.newTab(_:)),
        "close_tab": #selector(MainWindowController.closeActiveTab(_:)),
        "save": #selector(MainWindowController.saveDocument(_:)),
        "save_as": #selector(MainWindowController.saveDocumentAs(_:)),
        "prompt_open_file": #selector(MainWindowController.openDocument(_:)),
        "show_command_palette": #selector(MainWindowController.showCommandPalette(_:)),
        "goto_definition": #selector(MainWindowController.gotoDefinition(_:)),
        "jump_back": #selector(MainWindowController.jumpToPreviousLocation(_:)),
        "jump_forward": #selector(MainWindowController.jumpToNextLocation(_:)),

        "undo": #selector(EditorView.undo(_:)),
        "redo": #selector(EditorView.redo(_:)),
        "cut": #selector(EditorView.cut(_:)),
        "copy": #selector(EditorView.copy(_:)),
        "paste": #selector(EditorView.paste(_:)),

        "indent": #selector(EditorView.indentSelection(_:)),
        "unindent": #selector(EditorView.outdentSelection(_:)),
        "swap_line_up": #selector(EditorView.moveLineUp(_:)),
        "swap_line_down": #selector(EditorView.moveLineDown(_:)),
        "duplicate_line": #selector(EditorView.duplicateLine(_:)),
        "delete_line": #selector(EditorView.deleteLine(_:)),
        "join_lines": #selector(EditorView.joinLines(_:)),
        "toggle_comment": #selector(EditorView.toggleComment(_:)),

        "select_all": #selector(EditorView.selectAll(_:)),
        "expand_selection_to_line": #selector(EditorView.expandSelectionToLine(_:)),
        "expand_selection_to_word": #selector(EditorView.expandSelectionToWord(_:)),
        "find_under_expand": #selector(EditorView.selectNextOccurrence(_:)),
        "find_all_under": #selector(EditorView.selectAllOccurrences(_:)),
        "split_selection_into_lines": #selector(EditorView.splitSelectionIntoLines(_:)),
        "single_selection": #selector(EditorView.collapseToSingleCaret(_:)),

        "find": #selector(EditorView.performFind(_:)),
        "replace": #selector(EditorView.performFindAndReplace(_:)),
        "find_next": #selector(EditorView.findNextMatch(_:)),
        "find_prev": #selector(EditorView.findPreviousMatch(_:)),

        "toggle_sidebar": #selector(MainWindowController.toggleSidebar(_:)),
        "toggle_line_numbers": #selector(EditorView.toggleGutter(_:)),
        "toggle_invisibles": #selector(EditorView.toggleInvisibles(_:)),
        "uppercase": #selector(EditorView.uppercaseSelection(_:)),
        "lowercase": #selector(EditorView.lowercaseSelection(_:)),
        "title_case": #selector(EditorView.titlecaseSelection(_:)),
        "swap_case": #selector(EditorView.swapCaseSelection(_:)),
        "reverse_lines": #selector(EditorView.reverseLines(_:)),
        "sort_lines": #selector(EditorView.sortLines(_:)),
        "unique_lines": #selector(EditorView.uniqueLines(_:)),
    ]
}
