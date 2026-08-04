import Foundation
import MTextCore
import MTextTestKit

enum BuildSystemTests {

    static let suite = TestSuite("BuildSystem", [
        ("parses cmd, working_dir and file_regex", testParse),
        ("parses shell_cmd", testParseShellCmd),
        ("variants inherit what they do not override", testVariantsInherit),
        ("a variant with no cmd inherits the parent's", testVariantInheritsCmd),
        ("rejects a build system that runs nothing", testRejectsUnrunnable),
        ("rejects a top-level array", testRejectsArray),
        ("tolerates // comments", testComments),

        ("expands $file and its derivatives", testExpandFile),
        ("expands ${braced} form", testExpandBraced),
        ("leaves an unknown variable as written", testUnknownVariable),
        ("honours a backslash-escaped dollar", testEscapedDollar),
        ("expands across an argument list", testExpandArguments),

        ("pulls diagnostics out of output via file_regex", testDiagnostics),
        ("resolves a relative path against the working directory", testRelativePaths),
        ("defaults line and column when the regex omits them", testOptionalGroups),
        ("returns nothing for a regex that does not compile", testBadRegex),
        ("returns nothing when no file_regex is set", testNoRegex),
    ])

    // MARK: - Parsing

    private static let sample = """
    {
        "cmd": ["make", "$file_base_name"],
        "working_dir": "$file_path",
        "file_regex": "^(.+):([0-9]+):([0-9]+): (.+)$",
        "selector": "source.c",
        "variants": [
            {"name": "Run", "cmd": ["./$file_base_name"]},
            {"name": "Clean"}
        ]
    }
    """

    static func testParse() {
        guard let system = try? BuildSystemParser.parse(data: Data(sample.utf8), name: "C") else {
            expectTrue(false, "a well-formed build system should parse")
            return
        }
        expectEqual(system.cmd, ["make", "$file_base_name"], "unexpanded until run time")
        expectEqual(system.workingDir, "$file_path")
        expectEqual(system.selector, "source.c")
        expectTrue(system.isRunnable)
    }

    static func testParseShellCmd() {
        let json = #"{"shell_cmd": "swift build 2>&1"}"#
        let system = try? BuildSystemParser.parse(data: Data(json.utf8), name: "s")
        expectEqual(system?.shellCmd, "swift build 2>&1")
        expectEqual(system?.isRunnable, true)
    }

    /// Real `.sublime-build` variants usually specify only `name` and `cmd`, and expect the
    /// parent's `file_regex`, `working_dir` and `selector` to carry over.
    static func testVariantsInherit() {
        guard let system = try? BuildSystemParser.parse(data: Data(sample.utf8), name: "C"),
              let run = system.variants.first else {
            expectTrue(false, "variant should parse")
            return
        }
        expectEqual(run.name, "Run")
        expectEqual(run.cmd, ["./$file_base_name"])
        expectEqual(run.fileRegex, system.fileRegex, "inherited")
        expectEqual(run.workingDir, system.workingDir, "inherited")
    }

    /// "Clean" declares no `cmd`, so it inherits the parent's and stays runnable — only a
    /// variant that ends up with nothing at all is dropped.
    static func testVariantInheritsCmd() {
        let system = try? BuildSystemParser.parse(data: Data(sample.utf8), name: "C")
        expectEqual(system?.variants.count, 2)
        expectEqual(system?.variants.last?.cmd, ["make", "$file_base_name"],
                    "a variant with no cmd inherits the parent's")
    }

    static func testRejectsUnrunnable() {
        expectThrows { _ = try BuildSystemParser.parse(data: Data(#"{"selector": "source.c"}"#.utf8), name: "x") }
    }

    static func testRejectsArray() {
        expectThrows { _ = try BuildSystemParser.parse(data: Data("[]".utf8), name: "x") }
    }

    static func testComments() {
        let json = """
        // build for C
        {"cmd": ["make"]}
        """
        expectEqual((try? BuildSystemParser.parse(data: Data(json.utf8), name: "x"))?.cmd, ["make"])
    }

    // MARK: - Variables

    private static var variables: BuildVariables {
        BuildVariables(filePath: "/work/src/main.swift",
                       projectPath: "/work/app.sublime-project",
                       folder: "/work",
                       packages: "/pkgs")
    }

    static func testExpandFile() {
        let v = variables
        expectEqual(v.expand("$file"), "/work/src/main.swift")
        expectEqual(v.expand("$file_path"), "/work/src")
        expectEqual(v.expand("$file_name"), "main.swift")
        expectEqual(v.expand("$file_base_name"), "main")
        expectEqual(v.expand("$file_extension"), "swift")
        expectEqual(v.expand("$folder"), "/work")
        expectEqual(v.expand("$project_path"), "/work")
        expectEqual(v.expand("$packages"), "/pkgs")
    }

    static func testExpandBraced() {
        expectEqual(variables.expand("${file_base_name}.o"), "main.o",
                    "braces are what let a variable abut following text")
    }

    /// Silently turning `$unknown/build.sh` into `/build.sh` would run something the user
    /// never asked for; leaving it intact fails loudly instead.
    static func testUnknownVariable() {
        expectEqual(variables.expand("$nope/build.sh"), "$nope/build.sh")
        expectEqual(variables.expand("${nope}"), "${nope}")
    }

    static func testEscapedDollar() {
        expectEqual(variables.expand(#"\$file"#), "$file")
    }

    static func testExpandArguments() {
        expectEqual(variables.expand(["cc", "-o", "$file_base_name", "$file"]),
                    ["cc", "-o", "main", "/work/src/main.swift"])
    }

    // MARK: - Output parsing

    private static let regex = "^(.+):([0-9]+):([0-9]+): (.+)$"

    static func testDiagnostics() {
        let output = """
        building…
        /work/src/main.swift:12:5: error: cannot find 'foo' in scope
        done
        """
        let found = BuildOutputParser.diagnostics(in: output, fileRegex: regex, workingDirectory: "/work")
        expectEqual(found.count, 1)
        expectEqual(found.first?.file, "/work/src/main.swift")
        expectEqual(found.first?.line, 11, "1-based in output, 0-based internally")
        expectEqual(found.first?.column, 4)
        expectEqual(found.first?.message, "error: cannot find 'foo' in scope")
        expectEqual(found.first?.outputLine, 1)
    }

    /// Compilers print paths relative to where they ran, so the working directory is what
    /// makes them openable.
    static func testRelativePaths() {
        let output = "src/main.swift:3:1: warning: unused"
        let found = BuildOutputParser.diagnostics(in: output, fileRegex: regex, workingDirectory: "/work")
        expectEqual(found.first?.file, "/work/src/main.swift")
    }

    static func testOptionalGroups() {
        let output = "src/main.swift: something went wrong"
        let found = BuildOutputParser.diagnostics(in: output,
                                                  fileRegex: "^(.+?): (.+)$",
                                                  workingDirectory: "/work")
        expectEqual(found.count, 1)
        expectEqual(found.first?.line, 0, "defaults to the first line")
        expectEqual(found.first?.column, 0)
    }

    /// A broken regex must not cost the user their build output.
    static func testBadRegex() {
        let found = BuildOutputParser.diagnostics(in: "a:1:1: b", fileRegex: "([unclosed",
                                                  workingDirectory: "/work")
        expectTrue(found.isEmpty)
    }

    static func testNoRegex() {
        expectTrue(BuildOutputParser.diagnostics(in: "a:1:1: b", fileRegex: nil,
                                                 workingDirectory: "/work").isEmpty)
    }
}
