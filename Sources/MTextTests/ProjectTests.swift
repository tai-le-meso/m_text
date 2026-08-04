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
    ])

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
