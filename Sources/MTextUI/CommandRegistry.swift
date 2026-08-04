import AppKit

/// A single dispatchable command exposed to the Command Palette (T75) — one leaf item
/// read straight out of the app's own menu tree, so the palette can never drift out of
/// sync with what the menus actually offer: there is no second, hand-maintained list of
/// commands to keep in step as menus change.
///
/// Holds the actual `NSMenuItem`, not just its `action` selector — some action methods
/// (e.g. the Syntax menu's `setSyntaxFromMenu(_:)`, which reads `representedObject` off
/// the menu item it was sent) do `sender as? NSMenuItem` and expect the real item, target,
/// and `representedObject` to come along; a bare selector dispatched with an arbitrary
/// `sender` would silently no-op for those. Dispatching through the original item, exactly
/// as AppKit itself would if it were clicked, keeps every listed command working.
public struct PaletteCommand {
    public let title: String
    public let keyEquivalentDisplay: String
    public let menuItem: NSMenuItem
}

public enum CommandRegistry {

    /// Walks `menu` recursively, collecting every non-hidden leaf item that has both an
    /// action and a title as a flat, palette-ready command list. A leaf nested one level
    /// inside a submenu (e.g. "Indent" under Edit ▸ Line) is renamed to fold its parent's
    /// title in (`"Line: Indent"`, or `"Edit: Line: Indent"` if doubly nested), so it
    /// still reads unambiguously outside its menu's original context. This prefixing
    /// starts from the very first call (so ordinary top-level items also read
    /// "File: New Tab", "Edit: Undo", etc.) — deliberate, matching the "Category: Command"
    /// convention other editors' command palettes use, not just an accident of recursion.
    ///
    /// Deliberately does **not** consult `isEnabled`/`validateMenuItem` — every listed
    /// command is dispatchable from the palette regardless of whether the equivalent menu
    /// item would currently be greyed out. A documented simplification, not an oversight:
    /// the underlying action methods are ordinary NSResponder-style commands already
    /// written to no-op safely when invoked with nothing valid to act on (e.g. Redo with
    /// an empty redo stack), so an occasional no-op dispatch is harmless.
    public static func commands(from menu: NSMenu) -> [PaletteCommand] {
        collect(from: menu, prefix: nil)
    }

    private static func collect(from menu: NSMenu, prefix: String?) -> [PaletteCommand] {
        var result: [PaletteCommand] = []
        for menuItem in menu.items {
            if let submenu = menuItem.submenu {
                let nestedPrefix = prefix.map { "\($0): \(menuItem.title)" } ?? menuItem.title
                result.append(contentsOf: collect(from: submenu, prefix: nestedPrefix))
                continue
            }
            guard menuItem.action != nil, !menuItem.isHidden, !menuItem.title.isEmpty else { continue }
            let title = prefix.map { "\($0): \(menuItem.title)" } ?? menuItem.title
            result.append(PaletteCommand(title: title,
                                         keyEquivalentDisplay: displayKeyEquivalent(for: menuItem),
                                         menuItem: menuItem))
        }
        return result
    }

    private static func displayKeyEquivalent(for item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        var symbols = ""
        let mods = item.keyEquivalentModifierMask
        if mods.contains(.control) { symbols += "⌃" }
        if mods.contains(.option) { symbols += "⌥" }
        if mods.contains(.shift) { symbols += "⇧" }
        if mods.contains(.command) { symbols += "⌘" }
        symbols += displayKey(item.keyEquivalent)
        return symbols
    }

    /// `NSXXXFunctionKey` constants are handed to `NSMenuItem.keyEquivalent` as single
    /// Unicode scalars (see the existing arrow-key and F12 key equivalents elsewhere in
    /// the app) — compared here as `UInt32` against `scalar.value` so this works
    /// regardless of exactly which integer type AppKit declares the constants as.
    private static func displayKey(_ key: String) -> String {
        guard let scalar = key.unicodeScalars.first else { return key.uppercased() }
        let value = scalar.value
        switch value {
        case UInt32(NSUpArrowFunctionKey): return "↑"
        case UInt32(NSDownArrowFunctionKey): return "↓"
        case UInt32(NSLeftArrowFunctionKey): return "←"
        case UInt32(NSRightArrowFunctionKey): return "→"
        case UInt32(NSF1FunctionKey) ... UInt32(NSF35FunctionKey):
            return "F\(Int(value) - Int(NSF1FunctionKey) + 1)"
        default:
            switch key {
            case "\u{1B}": return "⎋"
            case "\r": return "↩"
            case "\t": return "⇥"
            default: return key.uppercased()
            }
        }
    }
}
