import Foundation

/// One root folder in a project — mirrors the subset of Sublime's own
/// `.sublime-project` folder object this app understands.
public struct ProjectFolder: Equatable {
    public let url: URL
    /// Display name override (Sublime's `"name"` key); falls back to the folder's own
    /// last path component when absent.
    public let name: String?
    /// Directory/file *names* to exclude while walking this folder — the same shape
    /// `FileIndex.excludedNames` already understands. Sublime's own
    /// `folder_exclude_patterns`/`file_exclude_patterns` support full glob syntax
    /// (`*.pyc`); only plain, pattern-free names are honoured here — anything
    /// containing `*`, `?`, or `[` is dropped by `ProjectParser` rather than being
    /// silently mismatched against the wrong thing. A documented gap, not a bug:
    /// `FileIndex` has no glob matcher today.
    public let excludedNames: Set<String>

    public var displayName: String { name ?? url.lastPathComponent }

    public init(url: URL, name: String? = nil, excludedNames: Set<String> = []) {
        self.url = url
        self.name = name
        self.excludedNames = excludedNames
    }
}

/// A loaded `.sublime-project` file, or an ad hoc single-folder project synthesized by
/// "Open Folder…" (`Project.adHoc(folder:)`) when no project file exists at all.
public struct Project: Equatable {
    /// `nil` for an ad hoc project — there's no file on disk to point at.
    public let fileURL: URL?
    public let folders: [ProjectFolder]
    /// The project's `"settings"` object (T86), sitting between the syntax and view
    /// layers. Empty for an ad hoc project and for a project file that omits the key.
    public let settings: SettingsLayer

    public init(fileURL: URL?, folders: [ProjectFolder], settings: SettingsLayer = .empty) {
        self.fileURL = fileURL
        self.folders = folders
        self.settings = settings
    }

    public static func adHoc(folder url: URL) -> Project {
        Project(fileURL: nil, folders: [ProjectFolder(url: url)])
    }

    /// Every excluded name across every folder — for callers like `FileIndex` that
    /// don't distinguish which root a name came from.
    public var allExcludedNames: Set<String> {
        folders.reduce(into: Set<String>()) { $0.formUnion($1.excludedNames) }
    }
}

/// Parses `.sublime-project` files: a JSON object with a `"folders"` array (each with
/// `"path"`, optional `"name"`, `"follow_symlinks"`, `"folder_exclude_patterns"`,
/// `"file_exclude_patterns"`) and an optional `"settings"` object.
///
/// The `"settings"` object became a real settings layer in T86 (`Project.settings`).
///
/// Two deliberate simplifications remain:
/// - `"build_systems"` and every other Sublime project key is read past but not
///   modeled — this app has no build-system runner yet (T95).
/// - `"follow_symlinks"` is not modeled either: `FileIndex`'s walk doesn't accept a
///   per-root symlink policy, so every folder is walked the same way regardless of this
///   flag. Another documented gap, not a silent behavior change.
public enum ProjectParser {

    public enum ParseError: Error { case notUTF8, notAnObject, noFolders }

    /// `path` entries are resolved relative to `projectFileURL`'s own directory,
    /// matching real Sublime project files (a `.sublime-project` is typically checked in
    /// next to the code it describes, with folder paths like `"."` or `"../other-repo"`).
    public static func parse(data: Data, projectFileURL: URL) throws -> Project {
        guard let text = String(data: data, encoding: .utf8) else { throw ParseError.notUTF8 }
        // Real `.sublime-project` files, like `.sublime-keymap` files, commonly include
        // `//` comments despite not being strict JSON — reusing the same stripper keeps
        // this consistent rather than writing a second copy of the same scan.
        let stripped = Data(KeymapParser.stripLineComments(text).utf8)
        let json = try JSONSerialization.jsonObject(with: stripped)
        guard let object = json as? [String: Any] else { throw ParseError.notAnObject }
        guard let rawFolders = object["folders"] as? [[String: Any]], !rawFolders.isEmpty
        else { throw ParseError.noFolders }

        let base = projectFileURL.deletingLastPathComponent()
        let folders = rawFolders.compactMap { folder -> ProjectFolder? in
            guard let path = folder["path"] as? String else { return nil }
            let url = URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
            return ProjectFolder(url: url,
                                 name: folder["name"] as? String,
                                 excludedNames: excludedNames(from: folder))
        }
        guard !folders.isEmpty else { throw ParseError.noFolders }

        // The `"settings"` object is now modelled (T86) — it used to be read past. Values
        // this build has no setting for are dropped by `SettingValue`, same as anywhere
        // else, so a project file shared with real Sublime still contributes whatever it
        // has in common rather than being rejected outright.
        var settings = SettingsLayer.empty
        if let raw = object["settings"] as? [String: Any] {
            var values: [String: SettingValue] = [:]
            for (key, value) in raw {
                if let converted = SettingValue(json: value) { values[key] = converted }
            }
            settings = SettingsLayer(name: "Project", values: values)
        }
        return Project(fileURL: projectFileURL, folders: folders, settings: settings)
    }

    private static func excludedNames(from folder: [String: Any]) -> Set<String> {
        var result: Set<String> = []
        for key in ["folder_exclude_patterns", "file_exclude_patterns"] {
            guard let patterns = folder[key] as? [String] else { continue }
            for pattern in patterns where !pattern.contains(where: { "*?[".contains($0) }) {
                result.insert(pattern)
            }
        }
        return result
    }
}
