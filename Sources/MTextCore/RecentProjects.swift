import Foundation

/// The "Open Recent" list: folders opened with Open Folder… and `.sublime-project` files
/// opened with Switch Project.
///
/// Pure list arithmetic, deliberately with no storage of its own — the UI layer owns
/// persistence (`UserDefaults`). That keeps the ordering, de-duplication and capping rules
/// testable without a defaults database, which is where the actual bugs in a most-recently-used
/// list live: an entry silently duplicating because the same folder came back with a trailing
/// slash, or the list growing without bound.
public enum RecentProjects {

    /// Ten is what macOS apps conventionally show before "Clear Menu".
    public static let limit = 10

    /// `url` moved to the front, with any previous entry for the same location removed.
    ///
    /// Identity is the standardized `.path`, for the same reason `Project` uses it: a folder
    /// picked from an `NSOpenPanel` and the same folder arriving from a drag can differ by a
    /// trailing slash, and comparing URLs would list it twice.
    public static func adding(_ url: URL, to existing: [URL], limit: Int = limit) -> [URL] {
        let key = path(url)
        return Array(([url] + existing.filter { path($0) != key }).prefix(max(0, limit)))
    }

    public static func removing(_ url: URL, from existing: [URL]) -> [URL] {
        let key = path(url)
        return existing.filter { path($0) != key }
    }

    /// Drops entries that no longer exist. A recent list is a set of promises about the file
    /// system, and offering a folder that was moved or deleted just produces an error sheet.
    public static func pruning(_ list: [URL],
                               exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) })
        -> [URL] {
        list.filter(exists)
    }

    /// What to show in the menu. Bare folder names collide constantly (`src`, `docs`), so an
    /// entry whose name is ambiguous within the list carries its parent directory too.
    public static func menuTitles(for list: [URL]) -> [String] {
        var counts: [String: Int] = [:]
        for url in list { counts[url.lastPathComponent, default: 0] += 1 }
        return list.map { url in
            let name = url.lastPathComponent
            guard counts[name, default: 0] > 1 else { return name }
            let parent = url.deletingLastPathComponent().lastPathComponent
            return parent.isEmpty ? name : "\(name) — \(parent)"
        }
    }

    private static func path(_ url: URL) -> String { url.standardizedFileURL.path }
}
