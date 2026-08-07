import AppKit
import MTextCore

/// Help ▸ Install Shell Command — puts `mtext` on your PATH without a terminal.
///
/// The script is shipped inside the bundle (`Contents/Resources/mtext`) rather than fetched
/// from a source checkout, so a downloaded m_text can install it. On the way out, the copy
/// gets `DEFAULT_APP` rewritten to **this** bundle's path, so the command opens the copy of
/// m_text you installed it from rather than guessing — while the bundle-id launch inside the
/// script still finds the app if you move it later.
///
/// Installs to `~/.local/bin`, never `/usr/local/bin`: the latter is unwritable on a managed
/// (MDM) Mac, which is exactly where "just run make install-cli" fell over with
/// *Permission denied* and no sudo to reach for.
public enum ShellCommandInstaller {

    public static let installDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/bin")
    public static var installedURL: URL { installDirectory.appendingPathComponent("mtext") }

    public static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: installedURL.path)
    }

    public enum InstallError: LocalizedError {
        case scriptMissingFromBundle
        case notReadable(String)

        public var errorDescription: String? {
            switch self {
            case .scriptMissingFromBundle:
                return "This copy of m_text has no bundled `mtext` script to install."
            case .notReadable(let why):
                return why
            }
        }
    }

    /// Writes the command and reports whether the PATH still needs fixing.
    @discardableResult
    public static func install() throws -> (url: URL, needsPathEntry: Bool) {
        guard let source = Bundle.main.url(forResource: "mtext", withExtension: nil),
              var script = try? String(contentsOf: source, encoding: .utf8)
        else { throw InstallError.scriptMissingFromBundle }

        // Point the installed copy at this bundle. Quoted with the path escaped, because an
        // app living under a directory with a space or a quote in its name would otherwise
        // produce a script that does not parse.
        let bundlePath = Bundle.main.bundleURL.standardizedFileURL.path
        let escaped = bundlePath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        script = script.replacingOccurrences(of: "\nDEFAULT_APP=\"\"\n",
                                             with: "\nDEFAULT_APP=\"\(escaped)\"\n")

        try FileManager.default.createDirectory(at: installDirectory,
                                                withIntermediateDirectories: true)
        // Replace rather than write over: overwriting a running script in place is how you
        // get a half-written file executed.
        if FileManager.default.fileExists(atPath: installedURL.path) {
            try FileManager.default.removeItem(at: installedURL)
        }
        try script.write(to: installedURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: installedURL.path)

        return (installedURL, !isOnPath(installDirectory.path))
    }

    public static func uninstall() throws {
        if FileManager.default.fileExists(atPath: installedURL.path) {
            try FileManager.default.removeItem(at: installedURL)
        }
    }

    /// Whether a directory is on the PATH a *login shell* would have — not this process's.
    ///
    /// An app launched from Finder inherits a minimal PATH that says nothing about what the
    /// user's terminal will see, so asking `ProcessInfo` would report "not on PATH" for
    /// people whose profile puts it there, and send them to edit a file that already has the
    /// line. The user's own shell is asked instead.
    static func isOnPath(_ directory: String) -> Bool {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lic", "printf %s \"$PATH\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let path = String(data: data, encoding: .utf8) ?? ""
            return path.split(separator: ":").contains { $0 == directory }
        } catch {
            // Could not ask: fall back to this process's PATH rather than claiming either way.
            return (ProcessInfo.processInfo.environment["PATH"] ?? "")
                .split(separator: ":").contains { $0 == directory }
        }
    }

    /// The line to add, in the syntax of the user's shell.
    public static var pathLine: String {
        let shell = (ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        if shell.hasSuffix("/fish") { return "fish_add_path \(installDirectory.path)" }
        return "export PATH=\"\(installDirectory.path):$PATH\""
    }

    /// The profile file the user's shell actually reads. bash on macOS is started as a
    /// *login* shell by Terminal, which reads `.bash_profile` and never `.bashrc`.
    public static var profilePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let shell = (ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        if shell.hasSuffix("/fish") { return home.appendingPathComponent(".config/fish/config.fish").path }
        if shell.hasSuffix("/bash") {
            let profile = home.appendingPathComponent(".bash_profile").path
            return FileManager.default.fileExists(atPath: profile)
                ? profile : home.appendingPathComponent(".profile").path
        }
        if shell.hasSuffix("/zsh") { return home.appendingPathComponent(".zshrc").path }
        return home.appendingPathComponent(".profile").path
    }

    private static let beginMarker = "# >>> m_text >>>"
    private static let endMarker = "# <<< m_text <<<"

    /// Adds the PATH line to the shell profile, inside markers so re-running replaces the
    /// block instead of stacking another copy and uninstalling can take it out again.
    public static func addToProfile() throws {
        let path = profilePath
        var contents = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        contents = removingBlock(from: contents)
        if !contents.isEmpty && !contents.hasSuffix("\n") { contents += "\n" }
        contents += "\(beginMarker)\n\(pathLine)\n\(endMarker)\n"
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
    }

    public static func removeFromProfile() throws {
        let path = profilePath
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        try removingBlock(from: contents).write(toFile: path, atomically: true, encoding: .utf8)
    }

    static func removingBlock(from contents: String) -> String {
        var result: [String] = []
        var skipping = false
        for line in contents.components(separatedBy: "\n") {
            if line == beginMarker { skipping = true; continue }
            if line == endMarker { skipping = false; continue }
            if !skipping { result.append(line) }
        }
        return result.joined(separator: "\n")
    }
}
