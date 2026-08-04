import Foundation

/// A parsed `.sublime-build` (T95).
///
/// **Nothing here runs anything.** This file only parses the description and expands its
/// variables; execution lives in `BuildRunner` (MTextUI) and happens solely on an explicit
/// Build command. Opening a file, loading a project, or switching syntax never triggers a
/// build — a build system is a *description* until the user asks for it, and keeping the
/// parse and the process launch in separate layers is what makes that easy to see.
public struct BuildSystem: Equatable {

    /// Display name — the file's own name, or a variant's `"name"`.
    public let name: String
    /// `"cmd"`: argv, run directly with no shell.
    public let cmd: [String]
    /// `"shell_cmd"`: a single command line, run through `/bin/sh -c`. Sublime supports
    /// both; `cmd` wins when a file gives both, matching Sublime.
    public let shellCmd: String?
    public let workingDir: String?
    /// `"file_regex"`: matches an error line, capturing file, line, column and message in
    /// that order.
    public let fileRegex: String?
    /// `"selector"`: scope this build system applies to, e.g. `source.python`.
    public let selector: String?
    /// Extra environment, from `"env"`.
    public let env: [String: String]
    /// `"variants"`: alternate commands (Run, Test…) sharing the parent's other settings.
    public let variants: [BuildSystem]

    public init(name: String, cmd: [String] = [], shellCmd: String? = nil,
                workingDir: String? = nil, fileRegex: String? = nil, selector: String? = nil,
                env: [String: String] = [:], variants: [BuildSystem] = []) {
        self.name = name
        self.cmd = cmd
        self.shellCmd = shellCmd
        self.workingDir = workingDir
        self.fileRegex = fileRegex
        self.selector = selector
        self.env = env
        self.variants = variants
    }

    /// True when there is actually something to run.
    public var isRunnable: Bool { !cmd.isEmpty || !(shellCmd ?? "").isEmpty }
}

/// The `$file`, `$folder`… substitutions a build command is written in terms of.
public struct BuildVariables {
    public var filePath: String
    public var projectPath: String
    public var folder: String
    public var packages: String

    public init(filePath: String = "", projectPath: String = "", folder: String = "",
                packages: String = "") {
        self.filePath = filePath
        self.projectPath = projectPath
        self.folder = folder
        self.packages = packages
    }

    /// Sublime's variable names. An unknown `$name` is left **as written** rather than
    /// replaced with an empty string: silently turning `$unknown/build.sh` into `/build.sh`
    /// would run something the user never asked for, where leaving it intact fails loudly.
    public func value(for name: String) -> String? {
        let url = URL(fileURLWithPath: filePath)
        switch name {
        case "file": return filePath
        case "file_path": return filePath.isEmpty ? "" : url.deletingLastPathComponent().path
        case "file_name": return url.lastPathComponent
        case "file_base_name": return url.deletingPathExtension().lastPathComponent
        case "file_extension": return url.pathExtension
        case "folder": return folder
        case "project": return projectPath
        case "project_path":
            return projectPath.isEmpty ? "" : URL(fileURLWithPath: projectPath).deletingLastPathComponent().path
        case "packages": return packages
        default: return nil
        }
    }

    /// Replaces `$name` and `${name}` throughout. `\$` escapes a literal dollar.
    public func expand(_ text: String) -> String {
        var result = ""
        var characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count, characters[index + 1] == "$" {
                result.append("$")
                index += 2
                continue
            }
            guard character == "$", index + 1 < characters.count else {
                result.append(character)
                index += 1
                continue
            }

            let braced = characters[index + 1] == "{"
            var cursor = index + (braced ? 2 : 1)
            var name = ""
            while cursor < characters.count,
                  characters[cursor].isLetter || characters[cursor].isNumber || characters[cursor] == "_" {
                name.append(characters[cursor])
                cursor += 1
            }
            if braced {
                guard cursor < characters.count, characters[cursor] == "}" else {
                    result.append(character)   // unbalanced: literal text
                    index += 1
                    continue
                }
                cursor += 1
            }
            guard !name.isEmpty, let value = value(for: name) else {
                result.append(character)       // unknown: leave it visible
                index += 1
                continue
            }
            result += value
            index = cursor
        }
        return result
    }

    public func expand(_ arguments: [String]) -> [String] {
        arguments.map(expand)
    }
}

/// Reads `.sublime-build` files: a JSON object, `//` comments tolerated like every other
/// JSON-ish format here.
public enum BuildSystemParser {

    public enum ParseError: Error, Equatable { case notAnObject, nothingToRun }

    public static func parse(data: Data, name: String) throws -> BuildSystem {
        guard let text = String(data: data, encoding: .utf8) else { throw ParseError.notAnObject }
        let stripped = Data(KeymapParser.stripLineComments(text).utf8)
        let json = try JSONSerialization.jsonObject(with: stripped)
        guard let object = json as? [String: Any] else { throw ParseError.notAnObject }

        let system = build(from: object, name: name, inheriting: nil)
        // A build system that can't run anything is a configuration error worth reporting at
        // load time rather than silently offering a menu item that does nothing.
        guard system.isRunnable || !system.variants.isEmpty else { throw ParseError.nothingToRun }
        return system
    }

    /// Variants inherit everything they don't override — in real `.sublime-build` files a
    /// variant usually specifies only `name` and `cmd`.
    private static func build(from object: [String: Any], name: String,
                              inheriting parent: BuildSystem?) -> BuildSystem {
        let cmd = (object["cmd"] as? [String]) ?? parent?.cmd ?? []
        let shellCmd = (object["shell_cmd"] as? String) ?? parent?.shellCmd
        let workingDir = (object["working_dir"] as? String) ?? parent?.workingDir
        let fileRegex = (object["file_regex"] as? String) ?? parent?.fileRegex
        let selector = (object["selector"] as? String) ?? parent?.selector
        var env = parent?.env ?? [:]
        if let raw = object["env"] as? [String: Any] {
            for (key, value) in raw { env[key] = String(describing: value) }
        }

        var system = BuildSystem(name: (object["name"] as? String) ?? name,
                                 cmd: cmd, shellCmd: shellCmd, workingDir: workingDir,
                                 fileRegex: fileRegex, selector: selector, env: env)
        guard parent == nil, let rawVariants = object["variants"] as? [[String: Any]] else {
            return system
        }
        let variants = rawVariants.compactMap { variant -> BuildSystem? in
            let child = build(from: variant, name: variant["name"] as? String ?? name,
                              inheriting: system)
            return child.isRunnable ? child : nil
        }
        system = BuildSystem(name: system.name, cmd: system.cmd, shellCmd: system.shellCmd,
                             workingDir: system.workingDir, fileRegex: system.fileRegex,
                             selector: system.selector, env: system.env, variants: variants)
        return system
    }
}

/// One error or warning pulled out of build output by `file_regex`.
public struct BuildDiagnostic: Equatable {
    public let file: String
    public let line: Int
    public let column: Int
    public let message: String
    /// Which output line it came from, so the panel can highlight it.
    public let outputLine: Int

    public init(file: String, line: Int, column: Int, message: String, outputLine: Int) {
        self.file = file
        self.line = line
        self.column = column
        self.message = message
        self.outputLine = outputLine
    }
}

/// Applies a build system's `file_regex` to its output.
public enum BuildOutputParser {

    /// Sublime's convention: capture groups are file, line, column, message **in that
    /// order**, and every group after the first is optional. A regex that doesn't compile
    /// yields no diagnostics rather than throwing — the build output is still worth showing.
    public static func diagnostics(in output: String, fileRegex: String?,
                                   workingDirectory: String) -> [BuildDiagnostic] {
        guard let fileRegex, !fileRegex.isEmpty,
              let regex = try? NSRegularExpression(pattern: fileRegex)
        else { return [] }

        var results: [BuildDiagnostic] = []
        for (index, line) in output.components(separatedBy: "\n").enumerated() {
            let range = NSRange(line.startIndex ..< line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: range), match.numberOfRanges > 1
            else { continue }

            func group(_ number: Int) -> String? {
                guard number < match.numberOfRanges,
                      let range = Range(match.range(at: number), in: line)
                else { return nil }
                return String(line[range])
            }
            guard let file = group(1), !file.isEmpty else { continue }

            // Relative paths in compiler output are relative to where the build ran.
            let resolved = file.hasPrefix("/")
                ? file
                : URL(fileURLWithPath: workingDirectory).appendingPathComponent(file).path

            results.append(BuildDiagnostic(
                file: resolved,
                // 1-based in output, 0-based internally — the same convention Goto Anything's
                // `:line` uses.
                line: max(0, (group(2).flatMap(Int.init) ?? 1) - 1),
                column: max(0, (group(3).flatMap(Int.init) ?? 1) - 1),
                message: group(4)?.trimmingCharacters(in: .whitespaces) ?? line.trimmingCharacters(in: .whitespaces),
                outputLine: index
            ))
        }
        return results
    }
}
