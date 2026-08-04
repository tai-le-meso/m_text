import Foundation

/// Owns the on-disk half of the settings stack — the user file and any per-syntax files
/// — and reports when either changes on disk.
///
/// The other two layers are supplied by callers rather than read here, because neither
/// lives in this directory: project settings come out of the open `.sublime-project`
/// (`Project.settings`), and the view layer is whatever the current window has toggled by
/// menu command. `SettingsStore` is deliberately ignorant of both; it hands out the file
/// layers and `SettingsResolver` stacks them.
///
/// Follows `FileIndex`/`HighlightService`'s plain-class-plus-serial-queue idiom rather
/// than introducing an `actor`, matching the rest of MTextCore.
public final class SettingsStore {

    /// `~/Library/Application Support/m_text/User`
    public let userDirectory: URL

    /// Called on the main queue after a settings file changes on disk. Callers re-resolve
    /// and re-apply; the store does not know what a "view" is.
    public var onChange: (() -> Void)?

    private let queue = DispatchQueue(label: "m_text.settings")
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedDescriptor: CInt = -1

    /// Cached parsed layers, keyed by file name (`"Preferences"`, `"Swift"`, …). Rebuilt
    /// wholesale on any change — settings files are small and change at human speed, so
    /// there's nothing to gain from tracking which one moved.
    private var layers: [String: SettingsLayer] = [:]

    public static let userFileName = "Preferences.sublime-settings"
    public static let fileExtension = "sublime-settings"

    public init(userDirectory: URL? = nil) {
        if let userDirectory {
            self.userDirectory = userDirectory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.userDirectory = support
                .appendingPathComponent("m_text", isDirectory: true)
                .appendingPathComponent("User", isDirectory: true)
        }
        reload()
    }

    deinit {
        watcher?.cancel()
    }

    // MARK: - Paths

    public var userFileURL: URL {
        userDirectory.appendingPathComponent(SettingsStore.userFileName)
    }

    /// Where a syntax's own overrides live — `User/Swift.sublime-settings`, named after
    /// the syntax exactly as Sublime does it.
    public func syntaxFileURL(for syntaxName: String) -> URL {
        userDirectory.appendingPathComponent("\(syntaxName).\(SettingsStore.fileExtension)")
    }

    /// The read-only defaults pane, materialised on disk so it can be opened in a tab
    /// like any other file. Rewritten on every call so it always matches this build.
    public func writeDefaultFile() throws -> URL {
        try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        let url = userDirectory.appendingPathComponent("Default.\(SettingsStore.fileExtension)")
        try Data(SettingsResolver.defaultFileText.utf8).write(to: url, options: .atomic)
        return url
    }

    /// Creates the user file with a short stub if it doesn't exist yet, so "Preferences:
    /// Settings" always has something real to open in the editable pane.
    @discardableResult
    public func ensureUserFileExists() throws -> URL {
        let url = userFileURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return url }
        try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        let stub = """
        // m_text user settings. These override the defaults shown in the other pane.
        {
        }

        """
        try Data(stub.utf8).write(to: url, options: .atomic)
        return url
    }

    // MARK: - Layers

    /// Parsed user layer, or an empty one when the file is absent or unreadable.
    public var userLayer: SettingsLayer {
        queue.sync { layers["Preferences"] ?? SettingsLayer(name: "User", values: [:]) }
    }

    /// Parsed layer for one syntax, or empty when that syntax has no file.
    public func syntaxLayer(for syntaxName: String?) -> SettingsLayer {
        guard let syntaxName else { return .empty }
        return queue.sync { layers[syntaxName] ?? SettingsLayer(name: "Syntax: \(syntaxName)", values: [:]) }
    }

    /// The full stack for one editor, in precedence order (lowest first).
    /// `project` and `view` are passed in because the store cannot know them.
    public func stack(syntaxName: String?,
                      project: SettingsLayer = .empty,
                      view: SettingsLayer = .empty) -> [SettingsLayer] {
        [SettingsResolver.defaultLayer, userLayer, syntaxLayer(for: syntaxName), project, view]
    }

    public func settings(syntaxName: String?,
                         project: SettingsLayer = .empty,
                         view: SettingsLayer = .empty) -> EditorSettings {
        SettingsResolver.resolve(stack(syntaxName: syntaxName, project: project, view: view))
    }

    // MARK: - Loading

    /// Re-reads every `.sublime-settings` file in the user directory. A file that fails
    /// to parse is *dropped rather than fatal* and the previous good copy is not kept:
    /// silently continuing to apply superseded values while the user stares at the text
    /// they just typed would be worse than falling back to the layer below.
    public func reload() {
        let found = Self.loadLayers(in: userDirectory)
        queue.sync { layers = found }
    }

    private static func loadLayers(in directory: URL) -> [String: SettingsLayer] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var result: [String: SettingsLayer] = [:]
        for name in names where name.hasSuffix(".\(fileExtension)") {
            let key = String(name.dropLast(fileExtension.count + 1))
            // Never a layer: it's the generated read-only copy of the defaults, which are
            // already the bottom of every stack. Loading it as the "Default" *user* file
            // would apply every default a second time at higher precedence, overriding
            // the user's own settings with the very values they're overriding.
            guard key != "Default" else { continue }
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let layer = try? SettingsParser.parse(data: data, name: key)
            else { continue }
            result[key] = layer
        }
        return result
    }

    // MARK: - Live reload (T86)

    /// Watches the *directory* rather than the individual files: settings files are
    /// commonly saved by writing a temporary file and renaming it over the original
    /// (this app's own atomic save does exactly that), which replaces the inode and
    /// leaves a per-file watch pointing at something no longer on disk. A directory watch
    /// also catches a syntax file being created for the first time.
    public func startWatching() {
        guard watcher == nil else { return }
        try? FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)

        let descriptor = open(userDirectory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .extend],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.reload()
            DispatchQueue.main.async { self.onChange?() }
        }
        // The descriptor is owned by the source, so it is closed here and only here —
        // the same ownership rule `FileIndex` and `Sidebar` follow.
        source.setCancelHandler { [weak self] in
            close(descriptor)
            if self?.watchedDescriptor == descriptor { self?.watchedDescriptor = -1 }
        }
        watchedDescriptor = descriptor
        watcher = source
        source.resume()
    }

    public func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }
}
