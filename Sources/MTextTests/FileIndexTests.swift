import Foundation
import MTextCore
import MTextTestKit

/// Exercises `FileIndex.walk(...)`, the pure synchronous half of the file index — the
/// background-queue/live-watcher half isn't separately unit-tested here, same tier as
/// the AppKit code (reviewed carefully by hand instead of by an automated test).
enum FileIndexTests {

    static let suite = TestSuite("FileIndex", [
        ("walk finds all files with correct relative paths", testWalkFindsFiles),
        ("walk skips excluded directory names", testWalkSkipsExcludedNames),
        ("walk stops at the file cap", testWalkRespectsFileCap),
        ("walk prefixes multiple roots with their folder name", testWalkMultipleRoots),
    ])

    private static func makeTempDirectory() -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("m_text_FileIndexTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func write(_ text: String, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func testWalkFindsFiles() {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        write("a", to: root.appendingPathComponent("a.txt"))
        write("b", to: root.appendingPathComponent("sub/b.txt"))
        write("c", to: root.appendingPathComponent("sub/deeper/c.txt"))

        let result = FileIndex.walk(roots: [root], excludedNames: [], maximumFiles: 1000)
        let paths = Set(result.entries.map { $0.displayPath })
        expectEqual(paths, ["a.txt", "sub/b.txt", "sub/deeper/c.txt"])
    }

    static func testWalkSkipsExcludedNames() {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        write("keep", to: root.appendingPathComponent("keep.txt"))
        write("ignored", to: root.appendingPathComponent(".git/HEAD"))
        write("ignored", to: root.appendingPathComponent("node_modules/pkg/index.js"))

        let result = FileIndex.walk(roots: [root],
                                    excludedNames: FileIndex.defaultExcludedNames,
                                    maximumFiles: 1000)
        let paths = Set(result.entries.map { $0.displayPath })
        expectEqual(paths, ["keep.txt"])
    }

    static func testWalkRespectsFileCap() {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        for i in 0 ..< 20 {
            write("\(i)", to: root.appendingPathComponent("file\(i).txt"))
        }

        // All 20 files sit directly in `root` (a single directory), so the cap is hit
        // deterministically at exactly 5 regardless of listing order.
        let result = FileIndex.walk(roots: [root], excludedNames: [], maximumFiles: 5)
        expectEqual(result.entries.count, 5)
    }

    static func testWalkMultipleRoots() {
        let parent = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }

        let rootA = parent.appendingPathComponent("projectA")
        let rootB = parent.appendingPathComponent("projectB")
        write("a", to: rootA.appendingPathComponent("main.swift"))
        write("b", to: rootB.appendingPathComponent("main.go"))

        let result = FileIndex.walk(roots: [rootA, rootB], excludedNames: [], maximumFiles: 1000)
        let paths = Set(result.entries.map { $0.displayPath })
        expectEqual(paths, ["projectA/main.swift", "projectB/main.go"])
    }
}
