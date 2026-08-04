import Foundation

// MARK: - Session model (T84 — Session persistence, T85 — Hot exit)
//
// A snapshot of every open window at quit time — panes, tabs, carets, scroll
// positions, project — plus, for any tab with unsaved changes, the name of a
// "hot exit" buffer file holding its full text, so quitting never has to prompt
// and relaunching restores everything exactly as it was.
//
// Pure Foundation and fully `Codable`, so the whole model round-trips through
// JSON and is unit-testable without AppKit (`SessionTests`). The UI-facing
// capture/restore glue lives in `MainWindowController` (MTextUI); this file only
// defines what gets stored and where.
//
// Every struct declares an explicit `public init` — the auto-generated memberwise
// initializer is `internal`, invisible to `MTextTests`/`MTextUI`. The same bug
// class has broken cross-module builds three times this project already
// (`FileIndex.Entry`, `FuzzyMatcher.Match`, `KeymapParser.stripLineComments`).

/// One tab: which file it showed (if any), where any unsaved content was stashed,
/// and enough view state (caret, scroll, hand-picked syntax) to put things back.
public struct SessionTab: Codable, Equatable {
    /// Path of the document's file on disk, if it has one.
    public var filePath: String?
    /// Name of the hot-exit buffer file (inside the session directory) holding this
    /// tab's unsaved text — set only when the tab was dirty at capture time. An
    /// untitled-but-clean tab has neither `filePath` nor `bufferFile` and restores
    /// as a blank tab.
    public var bufferFile: String?
    public var caretLine: Int
    public var caretColumn: Int
    public var scrollX: Double
    public var scrollY: Double
    /// Set only when the user picked a syntax by hand — auto-detection re-runs on
    /// restore otherwise, which also keeps this correct if grammars changed between
    /// runs (an import, a deleted package).
    public var syntaxScope: String?
    /// `TextEncodingKind.rawValue` / `LineEnding.rawValue`, captured for dirty tabs
    /// so a restored buffer still saves back in the convention the file on disk
    /// uses. Buffer files themselves are always UTF-8 + LF; these record what the
    /// *document* should claim to be.
    public var encodingRaw: String?
    public var lineEndingRaw: String?

    public init(filePath: String? = nil,
                bufferFile: String? = nil,
                caretLine: Int = 0,
                caretColumn: Int = 0,
                scrollX: Double = 0,
                scrollY: Double = 0,
                syntaxScope: String? = nil,
                encodingRaw: String? = nil,
                lineEndingRaw: String? = nil) {
        self.filePath = filePath
        self.bufferFile = bufferFile
        self.caretLine = caretLine
        self.caretColumn = caretColumn
        self.scrollX = scrollX
        self.scrollY = scrollY
        self.syntaxScope = syntaxScope
        self.encodingRaw = encodingRaw
        self.lineEndingRaw = lineEndingRaw
    }
}

/// One pane (T81 allows up to two side by side): its tabs, and which was active.
public struct SessionPane: Codable, Equatable {
    public var tabs: [SessionTab]
    public var activeIndex: Int

    public init(tabs: [SessionTab] = [], activeIndex: Int = 0) {
        self.tabs = tabs
        self.activeIndex = activeIndex
    }
}

/// One window: frame, project, sidebar visibility, panes.
public struct SessionWindow: Codable, Equatable {
    /// `[x, y, width, height]` in screen coordinates; nil falls back to the default
    /// frame. An array rather than four fields purely to keep the JSON compact.
    public var frame: [Double]?
    /// Path of the `.sublime-project` file, when a real project was open.
    public var projectFilePath: String?
    /// The folder of an ad hoc (Open Folder…) project, which has no file on disk.
    /// Mutually exclusive with `projectFilePath`.
    public var adHocFolderPath: String?
    public var sidebarVisible: Bool
    public var focusedPaneIndex: Int
    public var panes: [SessionPane]

    public init(frame: [Double]? = nil,
                projectFilePath: String? = nil,
                adHocFolderPath: String? = nil,
                sidebarVisible: Bool = false,
                focusedPaneIndex: Int = 0,
                panes: [SessionPane] = []) {
        self.frame = frame
        self.projectFilePath = projectFilePath
        self.adHocFolderPath = adHocFolderPath
        self.sidebarVisible = sidebarVisible
        self.focusedPaneIndex = focusedPaneIndex
        self.panes = panes
    }
}

/// The whole session: every window, in front-to-back order at capture time.
public struct SessionState: Codable, Equatable {
    /// Bumped if the format ever changes incompatibly; `SessionStore.load` treats an
    /// unknown version as "no session" rather than guessing.
    public var version: Int
    public var windows: [SessionWindow]

    public static let currentVersion = 1

    public init(version: Int = SessionState.currentVersion, windows: [SessionWindow] = []) {
        self.version = version
        self.windows = windows
    }
}

// MARK: - Store

/// Reads and writes the session file and its hot-exit buffer files, all inside
/// `~/Library/Application Support/m_text/Session/`. Follows `PackageManager`'s
/// injectable-directory pattern so tests point it at a temp folder.
public final class SessionStore {

    public let directory: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.directory = support
                .appendingPathComponent("m_text", isDirectory: true)
                .appendingPathComponent("Session", isDirectory: true)
        }
    }

    public var sessionFileURL: URL { directory.appendingPathComponent("Session.json") }

    /// nil on a missing, unreadable, corrupt, or future-versioned file — a broken
    /// session must never be able to stop the app from launching, so this API cannot
    /// throw; the caller just starts fresh.
    public func load() -> SessionState? {
        guard let data = try? Data(contentsOf: sessionFileURL),
              let state = try? JSONDecoder().decode(SessionState.self, from: data),
              state.version <= SessionState.currentVersion
        else { return nil }
        return state
    }

    public func save(_ state: SessionState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        // Sorted keys keep consecutive saves byte-identical for identical state —
        // handy for tests and for eyeballing diffs of the file itself.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: sessionFileURL, options: .atomic)
    }

    // MARK: Hot-exit buffers

    /// Writes one dirty tab's full text and returns the file name to record in its
    /// `SessionTab.bufferFile`. `index` just has to be unique within one save pass;
    /// `SessionManager` hands out 0, 1, 2, ... across all windows.
    public func writeBuffer(_ text: String, index: Int) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "Buffer-\(index).txt"
        try Data(text.utf8).write(to: directory.appendingPathComponent(name), options: .atomic)
        return name
    }

    /// nil for a missing file — and for any name that isn't one `writeBuffer` could
    /// have produced: the name comes from the JSON on disk, which someone could have
    /// edited, and must not be usable as a path-traversal escape out of the session
    /// directory (`"../../../etc/passwd"`).
    public func readBuffer(named name: String) -> String? {
        guard name.hasPrefix("Buffer-"), !name.contains("/"), !name.contains("..") else { return nil }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Deletes every buffer file not named in `keep` — run after each save so
    /// buffers from tabs that have since been saved or closed don't pile up forever.
    public func pruneBuffers(keeping keep: Set<String>) {
        guard let children = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                          includingPropertiesForKeys: nil)
        else { return }
        for child in children
        where child.lastPathComponent.hasPrefix("Buffer-") && !keep.contains(child.lastPathComponent) {
            try? FileManager.default.removeItem(at: child)
        }
    }
}
