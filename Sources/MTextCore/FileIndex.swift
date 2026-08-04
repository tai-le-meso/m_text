import Darwin
import Foundation

/// Background file index for Goto Anything (T72): walks one or more root folders,
/// applies exclude patterns, and republishes the resulting file list — following
/// `HighlightService`'s plain-class-plus-private-serial-queue idiom rather than a
/// Swift `actor` (there is no `actor` anywhere else in this codebase; this keeps the
/// one concurrency style already established rather than introducing a second one).
///
/// Ownership rules, matching `HighlightService`'s:
/// - `roots`, `excludedNames`, and `generation` are touched **only** on the main
///   thread — mutating `excludedNames` mid-walk is safe because `rewalk()` copies it
///   into the async closure by value before dispatching.
/// - `watchers` and `pendingRewalk` are touched **only** on `queue`.
/// - every walk carries the generation it started from, so a slower, older walk can
///   never overwrite a newer one's results.
///
/// There is no real "project" concept yet (Phase 6, unbuilt) — callers derive scan
/// roots themselves, typically from currently open documents' containing folders.
///
/// Invalidation opens one `DispatchSourceFileSystemObject` per walked directory,
/// watching for `.write` (the event a directory's own descriptor reports when an entry
/// is added, removed, or renamed directly inside it) — this is the real thing, not a
/// periodic re-scan, but it costs one open file descriptor per watched directory, so
/// `maximumWatchedDirectories` caps how many are opened; directories beyond the cap are
/// still indexed on every `refresh()`, they just don't trigger an automatic one.
public final class FileIndex {

    public struct Entry: Equatable {
        public let url: URL
        /// Path relative to its scan root (prefixed with the root's folder name when
        /// there's more than one root), for a palette to show as a subtitle.
        public let displayPath: String

        public init(url: URL, displayPath: String) {
            self.url = url
            self.displayPath = displayPath
        }
    }

    /// Called on the main thread whenever a (re-)walk finishes — from `setRoots`,
    /// `refresh`, or an automatic rewalk triggered by a filesystem change.
    public var onUpdate: (([Entry]) -> Void)?

    /// Directory *names* (not paths) that are skipped entirely and never walked into.
    public var excludedNames: Set<String>

    public static let defaultExcludedNames: Set<String> = [
        ".git", ".svn", ".hg", ".build", "build", "DerivedData", "node_modules",
        "Pods", ".Trash", ".cache", "dist", "out", "Packages",
    ]

    /// Stops opening new live watchers past this many directories. A known, documented
    /// scaling limit, not a correctness bug: walking still covers everything every time
    /// `refresh()` runs, only automatic re-scan-on-change stops beyond the cap.
    public static let maximumWatchedDirectories = 4_000
    /// Safety valve for pathological trees (e.g. accidentally pointing this at $HOME).
    public static let maximumFiles = 200_000

    private let queue = DispatchQueue(label: "io.mesoneer.mtext.fileindex", qos: .utility)

    // Main-thread-only.
    private var roots: [URL] = []
    private var generation: UInt64 = 0

    // `queue`-only.
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var pendingRewalk: DispatchWorkItem?

    public init(excludedNames: Set<String> = FileIndex.defaultExcludedNames) {
        self.excludedNames = excludedNames
    }

    // MARK: - Main-thread API

    /// Replaces the scan roots and walks them immediately in the background.
    public func setRoots(_ newRoots: [URL]) {
        roots = newRoots
        rewalk()
    }

    /// Re-walks the current roots from scratch. Cheap to call defensively (e.g. right
    /// before showing Goto Anything) even though live watching also triggers this.
    public func refresh() {
        rewalk()
    }

    private func rewalk() {
        generation &+= 1
        let stamp = generation
        let currentRoots = roots
        let excluded = excludedNames
        queue.async { [weak self] in
            self?.performWalk(roots: currentRoots, excludedNames: excluded, generation: stamp)
        }
    }

    // MARK: - Background walk (queue only)

    private func performWalk(roots: [URL], excludedNames: Set<String>, generation stamp: UInt64) {
        for watcher in watchers { watcher.cancel() }
        watchers.removeAll()
        pendingRewalk = nil

        let result = FileIndex.walk(roots: roots, excludedNames: excludedNames, maximumFiles: FileIndex.maximumFiles)

        var newWatchers: [DispatchSourceFileSystemObject] = []
        var watchersRemaining = FileIndex.maximumWatchedDirectories
        for directory in result.directories {
            guard watchersRemaining > 0 else { break }
            if let watcher = makeWatcher(for: directory) {
                newWatchers.append(watcher)
                watchersRemaining -= 1
            }
        }
        watchers = newWatchers

        DispatchQueue.main.async { [weak self] in
            guard let self, stamp == self.generation else { return }
            self.onUpdate?(result.entries)
        }
    }

    /// The pure, synchronous part of indexing: no queues, no watchers, no instance
    /// state — just "walk these roots, skip these names, stop past this many files".
    /// Public (and stateless) so it can be unit-tested directly against real temp
    /// directories without touching any of the background-queue/
    /// `DispatchSourceFileSystemObject` plumbing, which isn't separately unit-tested
    /// (same tier as the AppKit code: reviewed carefully by hand instead).
    public struct WalkResult {
        public let entries: [Entry]
        /// Every directory visited (including excluded-from-listing but not
        /// excluded-by-name ones) — the instance method turns these into watchers.
        public let directories: [URL]
    }

    public static func walk(roots: [URL], excludedNames: Set<String>, maximumFiles: Int) -> WalkResult {
        let fileManager = FileManager.default
        var entries: [Entry] = []
        var directories: [URL] = []
        var filesRemaining = maximumFiles
        let multipleRoots = roots.count > 1

        for root in roots {
            guard filesRemaining > 0 else { break }
            let prefix = multipleRoots ? root.lastPathComponent + "/" : ""
            var stack: [URL] = [root]

            while let directory = stack.popLast() {
                guard filesRemaining > 0 else { break }
                directories.append(directory)

                guard let contents = try? fileManager.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [])
                else { continue }

                for url in contents {
                    if excludedNames.contains(url.lastPathComponent) { continue }

                    var isDirectory: ObjCBool = false
                    guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }

                    if isDirectory.boolValue {
                        stack.append(url)
                    } else {
                        entries.append(Entry(url: url, displayPath: prefix + relativePath(of: url, root: root)))
                        filesRemaining -= 1
                        if filesRemaining <= 0 { break }
                    }
                }
            }
        }
        return WalkResult(entries: entries, directories: directories)
    }

    /// Resolves symlinks on both sides before comparing — on macOS, `/tmp`, `/var`,
    /// and `/etc` are themselves symlinks to `/private/...`, and `FileManager` APIs are
    /// inconsistent about which form they hand back (e.g. `temporaryDirectory` gives
    /// the unresolved `/var/...` form, but `contentsOfDirectory` can return children
    /// already resolved to `/private/var/...`). Comparing the raw strings without
    /// resolving both would silently fail the prefix check and fall back to returning
    /// the whole absolute path instead of a clean relative one.
    public static func relativePath(of url: URL, root: URL) -> String {
        let full = url.resolvingSymlinksInPath().path
        let base = root.resolvingSymlinksInPath().path
        guard full.hasPrefix(base) else { return full }
        var relative = String(full.dropFirst(base.count))
        if relative.hasPrefix("/") { relative.removeFirst() }
        return relative
    }

    // MARK: - Live watching (queue only)

    private func makeWatcher(for directory: URL) -> DispatchSourceFileSystemObject? {
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: .write,
                                                               queue: queue)
        source.setEventHandler { [weak self] in
            self?.scheduleDebouncedRewalk()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        return source
    }

    /// Filesystem events arrive in bursts (a git checkout touches many entries at
    /// once), so this coalesces them into a single rewalk ~0.4s after the last one.
    private func scheduleDebouncedRewalk() {
        pendingRewalk?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.rewalkTriggeredByWatcher()
        }
        pendingRewalk = work
        queue.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// The debounced trigger fires on `queue`, but `rewalk()` needs `roots`/
    /// `excludedNames`/`generation`, which are main-thread-only — hop over once to
    /// read them and kick off a normal rewalk exactly like `refresh()` would.
    private func rewalkTriggeredByWatcher() {
        DispatchQueue.main.async { [weak self] in
            self?.rewalk()
        }
    }
}
