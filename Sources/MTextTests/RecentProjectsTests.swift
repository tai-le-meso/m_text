import Foundation
import MTextCore
import MTextTestKit

enum RecentProjectsTests {

    static let suite = TestSuite("RecentProjects", [
        ("a new entry goes to the front", testAddingToFront),
        ("re-opening moves an entry rather than duplicating it", testAddingExisting),
        ("a trailing slash is the same location", testPathNormalisation),
        ("the list is capped", testLimit),
        ("removing drops just that entry", testRemoving),
        ("pruning drops entries that no longer exist", testPruning),
        ("ambiguous names are disambiguated by their parent", testMenuTitles),
    ])

    private static func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    static func testAddingToFront() {
        let list = RecentProjects.adding(url("/tmp/b"), to: [url("/tmp/a")])
        expectEqual(list.map(\.lastPathComponent), ["b", "a"])
    }

    /// The bug this prevents: opening the same folder twice leaving two identical rows and
    /// pushing something useful off the end of the list.
    static func testAddingExisting() {
        let list = RecentProjects.adding(url("/tmp/a"), to: [url("/tmp/a"), url("/tmp/b")])
        expectEqual(list.map(\.lastPathComponent), ["a", "b"], "moved, not duplicated")
        expectEqual(list.count, 2)
    }

    static func testPathNormalisation() {
        let list = RecentProjects.adding(url("/tmp/a/"), to: [url("/tmp/a")])
        expectEqual(list.count, 1, "a trailing slash is not a different folder")
        expectEqual(RecentProjects.removing(url("/tmp/a/"), from: [url("/tmp/a")]).count, 0)
    }

    static func testLimit() {
        var list: [URL] = []
        for index in 0 ..< 15 { list = RecentProjects.adding(url("/tmp/\(index)"), to: list, limit: 10) }
        expectEqual(list.count, 10, "capped")
        expectEqual(list.first?.lastPathComponent, "14", "newest first")
        expectEqual(list.last?.lastPathComponent, "5", "oldest dropped")
    }

    static func testRemoving() {
        let list = RecentProjects.removing(url("/tmp/a"), from: [url("/tmp/a"), url("/tmp/b")])
        expectEqual(list.map(\.lastPathComponent), ["b"])
    }

    static func testPruning() {
        let list = [url("/tmp/gone"), url("/tmp/here")]
        let pruned = RecentProjects.pruning(list) { $0.lastPathComponent == "here" }
        expectEqual(pruned.map(\.lastPathComponent), ["here"])
    }

    /// `src` and `src` tell you nothing; `src — projectA` does.
    static func testMenuTitles() {
        let titles = RecentProjects.menuTitles(for: [
            url("/work/projectA/src"), url("/work/projectB/src"), url("/work/notes"),
        ])
        expectEqual(titles, ["src — projectA", "src — projectB", "notes"])
    }
}
