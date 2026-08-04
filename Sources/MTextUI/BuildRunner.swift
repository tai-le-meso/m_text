import AppKit
import MTextCore

/// Runs a build system's command and streams its output (T95).
///
/// **This is the only place in the app that executes anything**, and it does so only when
/// called — which is only from the Build command. Nothing about opening a file, loading a
/// project, switching syntax, or restoring a session reaches here. Keeping execution in one
/// small type, separate from the parsing in `BuildSystem`, is what makes that checkable at a
/// glance rather than a claim.
///
/// The command run is echoed into the output before it starts, so what executed is always
/// visible rather than inferred from a config file the user may not have written.
public final class BuildRunner {

    public private(set) var isRunning = false

    /// Streamed output, appended as it arrives.
    public var onOutput: ((String) -> Void)?
    /// Fired once with the exit status. `nil` status means the process was cancelled.
    public var onFinish: ((Int32?) -> Void)?

    private var process: Process?
    private let queue = DispatchQueue(label: "m_text.build")

    public init() {}

    /// Launches `system` with `variables` expanded. Returns the command line actually run,
    /// or nil when there was nothing runnable.
    @discardableResult
    public func run(_ system: BuildSystem, variables: BuildVariables) -> String? {
        cancel()

        let workingDirectory = resolvedWorkingDirectory(system, variables: variables)
        let process = Process()
        let description: String

        if !system.cmd.isEmpty {
            let argv = variables.expand(system.cmd)
            guard let first = argv.first, !first.isEmpty else { return nil }
            // `/usr/bin/env` resolves the tool on PATH without going through a shell, so a
            // `cmd` array stays argv — no quoting, no word splitting, no shell injection
            // from a filename with a space in it.
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = argv
            description = argv.joined(separator: " ")
        } else if let shell = system.shellCmd, !shell.isEmpty {
            // `shell_cmd` is by definition a shell line — the user wrote pipes and
            // redirections into it deliberately, which is the whole reason the key exists.
            let expanded = variables.expand(shell)
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", expanded]
            description = expanded
        } else {
            return nil
        }

        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        if !system.env.isEmpty {
            var environment = ProcessInfo.processInfo.environment
            for (key, value) in system.env { environment[key] = variables.expand(value) }
            process.environment = environment
        }

        // stdout and stderr into one pipe: compilers split diagnostics across both, and
        // interleaving them is what makes `file_regex` see everything.
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.onOutput?(text) }
        }

        process.terminationHandler = { [weak self] finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRunning = false
                self.process = nil
                self.onFinish?(finished.terminationReason == .uncaughtSignal ? nil : finished.terminationStatus)
            }
        }

        do {
            try process.run()
        } catch {
            onOutput?("Could not run: \(error.localizedDescription)\n")
            onFinish?(nil)
            return nil
        }
        self.process = process
        isRunning = true
        return description
    }

    /// Stops a running build. Safe to call when nothing is running.
    public func cancel() {
        guard let process, process.isRunning else { return }
        process.terminate()
        self.process = nil
        isRunning = false
    }

    /// Where the command runs. Falls back through the build system's own `working_dir`, the
    /// project folder, then the file's directory — a build with no working directory at all
    /// would otherwise inherit the app's, which is wherever it happened to be launched from.
    private func resolvedWorkingDirectory(_ system: BuildSystem, variables: BuildVariables) -> String {
        if let dir = system.workingDir.map({ variables.expand($0) }), !dir.isEmpty,
           FileManager.default.fileExists(atPath: dir) {
            return dir
        }
        if !variables.folder.isEmpty { return variables.folder }
        if !variables.filePath.isEmpty {
            return URL(fileURLWithPath: variables.filePath).deletingLastPathComponent().path
        }
        return FileManager.default.currentDirectoryPath
    }
}

/// Finds the `.sublime-build` files available to a window.
public enum BuildSystemStore {

    /// Build systems from the user's Packages folder plus a `Build` folder beside it,
    /// matching how snippets and grammars are found.
    public static func available(directories: [URL]) -> [BuildSystem] {
        var found: [BuildSystem] = []
        for directory in directories {
            let urls = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                     includingPropertiesForKeys: nil)) ?? []
            for url in urls where url.pathExtension.lowercased() == "sublime-build" {
                // One malformed file must not hide the rest — same rule as every other
                // loader here.
                guard let data = try? Data(contentsOf: url),
                      let system = try? BuildSystemParser.parse(
                          data: data, name: url.deletingPathExtension().lastPathComponent)
                else { continue }
                found.append(system)
            }
        }
        return found
    }

    public static var defaultDirectories: [URL] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let root = support.appendingPathComponent("m_text", isDirectory: true)
        return [
            root.appendingPathComponent("Packages", isDirectory: true),
            root.appendingPathComponent("Build", isDirectory: true),
        ]
    }

    /// The build systems that apply in `scope`, most specific first. A system with no
    /// `selector` applies anywhere.
    public static func matching(scope: String?, in systems: [BuildSystem]) -> [BuildSystem] {
        systems
            .compactMap { system -> (BuildSystem, Int)? in
                guard let selector = system.selector else { return (system, 0) }
                guard let scope,
                      let score = ScopeSelector(selector).score(against: ScopeStack([scope])),
                      score > 0
                else { return nil }
                return (system, score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }
}
