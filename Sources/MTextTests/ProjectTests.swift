import Foundation
import MTextCore
import MTextTestKit

enum ProjectTests {

    static let suite = TestSuite("Project", [
        ("resolves folder paths relative to the project file's directory", testRelativePaths),
        ("falls back to the folder's own name when \"name\" is absent", testDisplayNameFallback),
        ("collects plain exclude names but skips glob patterns", testExcludePatterns),
        ("throws when \"folders\" is missing", testThrowsWithoutFolders),
        ("throws when every folder entry is missing \"path\"", testThrowsWhenNoUsableFolders),
        ("strips comments the same way keymap files do", testStripsComments),
        ("adHoc synthesizes a single-folder project with no file", testAdHoc),
        ("adHoc takes several folders, in order", testAdHocMultipleFolders),
        ("adding a folder appends it", testAddingFolder),
        ("adding a folder already open changes nothing", testAddingDuplicate),
        ("a folder nested in an existing root is allowed", testAddingNestedFolder),
        ("removing a folder drops just that one", testRemovingFolder),
        ("adding and removing tolerate trailing slashes", testPathNormalisation),
        ("adding keeps a project file and its settings", testAddingPreservesIdentity),
    ])

    private static func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    static func testAdHocMultipleFolders() {
        let project = Project.adHoc(folders: [url("/tmp/a"), url("/tmp/b"), url("/tmp/c")])
        expectNil(project.fileURL)
        expectEqual(project.folders.map(\.displayName), ["a", "b", "c"], "order is preserved")
    }

    static func testAddingFolder() {
        let project = Project.adHoc(folder: url("/tmp/a")).adding(folder: url("/tmp/b"))
        expectEqual(project.folders.map(\.displayName), ["a", "b"])
        expectTrue(project.contains(folder: url("/tmp/b")))
    }

    /// Re-adding must not duplicate the row *or* replace the existing entry: a folder that
    /// came from a project file carries a display name and excludes that a bare re-add
    /// would otherwise wipe.
    static func testAddingDuplicate() {
        let named = ProjectFolder(url: url("/tmp/a"), name: "Alpha", excludedNames: ["node_modules"])
        let project = Project(fileURL: nil, folders: [named]).adding(folder: url("/tmp/a"))
        expectEqual(project.folders.count, 1)
        expectEqual(project.folders[0].displayName, "Alpha", "the existing entry survives")
        expectEqual(project.folders[0].excludedNames, ["node_modules"])
    }

    /// Deliberate, and matching Sublime: people add a deep subdirectory to keep it one
    /// click away, even though its parent is already a root.
    static func testAddingNestedFolder() {
        let project = Project.adHoc(folder: url("/tmp/proj")).adding(folder: url("/tmp/proj/src"))
        expectEqual(project.folders.count, 2, "a nested folder is a root in its own right")
    }

    static func testRemovingFolder() {
        let project = Project.adHoc(folders: [url("/tmp/a"), url("/tmp/b")])
            .removing(folder: url("/tmp/a"))
        expectEqual(project.folders.map(\.displayName), ["b"])
        expectFalse(project.contains(folder: url("/tmp/a")))
    }

    /// A root added from a picker and removed from a sidebar row can differ by a trailing
    /// slash; matching on the raw URL would leave a row nothing could remove.
    static func testPathNormalisation() {
        let project = Project.adHoc(folder: url("/tmp/a/"))
        expectTrue(project.contains(folder: url("/tmp/a")))
        expectEqual(project.removing(folder: url("/tmp/a")).folders.count, 0)
        expectEqual(project.adding(folder: url("/tmp/a/")).folders.count, 1, "no duplicate")
    }

    static func testAddingPreservesIdentity() {
        let file = url("/tmp/thing.sublime-project")
        let settings = SettingsLayer(name: "Project", values: ["tab_size": .int(2)])
        let project = Project(fileURL: file, folders: [ProjectFolder(url: url("/tmp/a"))],
                              settings: settings)
            .adding(folder: url("/tmp/b"))
        expectEqual(project.fileURL, file, "still the same project file")
        expectEqual(project.settings.values["tab_size"], .int(2), "settings survive")
        expectEqual(project.folders.count, 2)
    }

    private static func makeTempDirectory() -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("m_text_ProjectTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func testRelativePaths() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectFile = root.appendingPathComponent("Widgets.sublime-project")

        let json = """
        {
            "folders": [
                { "path": "src", "name": "Source" },
                { "path": "." }
            ]
        }
        """
        let project = try ProjectParser.parse(data: Data(json.utf8), projectFileURL: projectFile)
        expectEqual(project.folders.count, 2)
        expectEqual(project.folders[0].url.standardizedFileURL,
                    root.appendingPathComponent("src").standardizedFileURL)
        expectEqual(project.folders[0].displayName, "Source")
        expectEqual(project.folders[1].url.standardizedFileURL, root.standardizedFileURL)
        expectEqual(project.fileURL, projectFile)
    }

    static func testDisplayNameFallback() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectFile = root.appendingPathComponent("Widgets.sublime-project")
        let json = "{ \"folders\": [ { \"path\": \"src\" } ] }"
        let project = try ProjectParser.parse(data: Data(json.utf8), projectFileURL: projectFile)
        expectEqual(project.folders[0].displayName, "src")
    }

    static func testExcludePatterns() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectFile = root.appendingPathComponent("Widgets.sublime-project")
        let json = """
        {
            "folders": [
                { "path": ".", "folder_exclude_patterns": ["build", "*.tmp"],
                  "file_exclude_patterns": [".DS_Store"] }
            ]
        }
        """
        let project = try ProjectParser.parse(data: Data(json.utf8), projectFileURL: projectFile)
        expectEqual(project.folders[0].excludedNames, ["build", ".DS_Store"])
        expectEqual(project.allExcludedNames, ["build", ".DS_Store"])
    }

    static func testThrowsWithoutFolders() {
        expectThrows {
            _ = try ProjectParser.parse(data: Data("{}".utf8),
                                        projectFileURL: URL(fileURLWithPath: "/tmp/x.sublime-project"))
        }
    }

    static func testThrowsWhenNoUsableFolders() {
        expectThrows {
            _ = try ProjectParser.parse(data: Data("{ \"folders\": [ { \"name\": \"no path here\" } ] }".utf8),
                                        projectFileURL: URL(fileURLWithPath: "/tmp/x.sublime-project"))
        }
    }

    static func testStripsComments() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectFile = root.appendingPathComponent("Widgets.sublime-project")
        let json = """
        {
            // a comment
            "folders": [ { "path": "." } ]
        }
        """
        let project = try ProjectParser.parse(data: Data(json.utf8), projectFileURL: projectFile)
        expectEqual(project.folders.count, 1)
    }

    static func testAdHoc() {
        let url = URL(fileURLWithPath: "/tmp/some-folder")
        let project = Project.adHoc(folder: url)
        expectNil(project.fileURL)
        expectEqual(project.folders.count, 1)
        expectEqual(project.folders[0].url, url)
    }
}
