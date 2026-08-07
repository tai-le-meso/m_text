import AppKit
import MTextCore

/// Persistence and the File ▸ Open Recent menu for folders and `.sublime-project` files.
///
/// Deliberately not `NSDocumentController`'s recent-documents list: that is tied to
/// `NSDocument`, which this app does not use, and its auto-populated menu would list
/// individual *files* opened in tabs — which is not what "recent" means for an editor whose
/// unit of work is a folder.
///
/// The list arithmetic lives in `RecentProjects` (Core, unit tested); this holds the
/// `UserDefaults` key and the menu wiring.
public final class RecentProjectsMenu: NSObject, NSMenuDelegate {

    public static let shared = RecentProjectsMenu()

    private static let defaultsKey = "MTextRecentProjects"

    /// Set by the app delegate: how to open a chosen entry. A folder and a project file are
    /// opened differently, and this class should not have to know which is which.
    public var onOpen: ((URL) -> Void)?

    public var urls: [URL] {
        (UserDefaults.standard.array(forKey: RecentProjectsMenu.defaultsKey) as? [String] ?? [])
            .map { URL(fileURLWithPath: $0) }
    }

    public func note(_ url: URL) {
        let updated = RecentProjects.adding(url, to: urls)
        UserDefaults.standard.set(updated.map { $0.path }, forKey: RecentProjectsMenu.defaultsKey)
    }

    public func clear() {
        UserDefaults.standard.removeObject(forKey: RecentProjectsMenu.defaultsKey)
    }

    // MARK: - Menu

    /// Rebuilt as the menu opens rather than kept in step from the other end: entries can
    /// disappear from disk between launches, and a menu that only refreshes on change would
    /// keep offering them.
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let live = RecentProjects.pruning(urls)
        if live.count != urls.count {
            UserDefaults.standard.set(live.map { $0.path }, forKey: RecentProjectsMenu.defaultsKey)
        }

        guard !live.isEmpty else {
            let empty = NSMenuItem(title: "No Recent Folders", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        for (title, url) in zip(RecentProjects.menuTitles(for: live), live) {
            let item = NSMenuItem(title: title, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear Menu", action: #selector(clearMenu(_:)), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }

    @objc private func openRecent(_ sender: Any?) {
        guard let url = (sender as? NSMenuItem)?.representedObject as? URL else { return }
        onOpen?(url)
    }

    @objc private func clearMenu(_ sender: Any?) { clear() }

    // MARK: - Smoke-test hooks

    public func smokeTestTitles() -> [String] {
        let menu = NSMenu()
        menuNeedsUpdate(menu)
        return menu.items.map(\.title)
    }
}
