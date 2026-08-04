import AppKit
import MTextCore

/// File tree for the sidebar (T82): shows the open project's root folders, expanding
/// subdirectories lazily via `FileManager.contentsOfDirectory` as they're opened — unlike
/// `FileIndex` (an eager, full recursive walk for Goto Anything's flat file list), a tree
/// only ever needs to read what's actually expanded, so there's no equivalent up-front
/// cost or file cap here.
///
/// Hidden (zero width, via `isHidden`) until a project or ad hoc folder is open —
/// `MainWindowController.setProject(_:)` calls `setFolders(_:)` whenever that changes.
public final class Sidebar: NSView {

    /// A single row: a folder (expandable, lazily loads `children`) or a file (a leaf).
    /// A class, not a struct, so `NSOutlineView` can use identity (`===`) to track which
    /// row is expanded/selected across reloads — matching how Sublime's own sidebar (and
    /// this app's `FileIndex.Entry`) is keyed by path rather than by array index.
    final class Node {
        let url: URL
        let displayName: String
        let isDirectory: Bool
        weak var parent: Node?
        /// `nil` until first expanded — `children(of:)` loads and caches this on demand.
        var children: [Node]?

        init(url: URL, displayName: String, isDirectory: Bool, parent: Node?) {
            self.url = url
            self.displayName = displayName
            self.isDirectory = isDirectory
            self.parent = parent
        }
    }

    /// Fired when a file row is clicked — `MainWindowController` opens it.
    public var onOpenFile: ((URL) -> Void)?

    /// Caps live-watched directories the same way `FileIndex` caps its own watchers —
    /// beyond this, expanding a folder still works, it just won't auto-refresh when
    /// something changes on disk underneath it until it's collapsed and re-expanded.
    static let maximumWatchedDirectories = 500

    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private var roots: [Node] = []
    private var excludedNames: Set<String> = FileIndex.defaultExcludedNames
    private var watchers: [ObjectIdentifier: DispatchSourceFileSystemObject] = [:]
    /// The row a context-menu action applies to — set by `menuNeedsUpdate(_:)` right
    /// before the menu shows, read by the action methods it wires up.
    private var contextNode: Node?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.target = self
        outlineView.action = #selector(rowClicked)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.title = "Name"
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        for watcher in watchers.values { watcher.cancel() }
    }

    // MARK: - Content

    /// Replaces every root folder and collapses all live watchers — called whenever the
    /// open project changes (including to no project, via an empty array, which leaves
    /// the tree empty; `MainWindowController` hides the sidebar entirely in that case).
    public func setFolders(_ folders: [ProjectFolder]) {
        for watcher in watchers.values { watcher.cancel() }
        watchers.removeAll()
        excludedNames = folders.reduce(into: FileIndex.defaultExcludedNames) { $0.formUnion($1.excludedNames) }
        roots = folders.map {
            Node(url: $0.url, displayName: $0.displayName, isDirectory: true, parent: nil)
        }
        outlineView.reloadData()
        for root in roots { outlineView.expandItem(root) }
    }

    /// Selects and reveals `url` in the tree if it falls under one of the current root
    /// folders, expanding every ancestor along the way. Silently does nothing if `url`
    /// isn't under any open root, or if it can't be reached without loading a directory
    /// that hasn't been listed yet (this only walks nodes already materialized by a
    /// prior expansion) — reveal-on-demand rather than reveal-at-any-cost.
    public func reveal(_ url: URL) {
        // `.resolvingSymlinksInPath()`, not just `.standardizedFileURL` (which only
        // collapses `.`/`..`, it doesn't resolve symlinks) — on macOS, `/tmp`, `/var`,
        // and `/etc` are themselves symlinks to `/private/...`, and a root folder's `url`
        // (from an `NSOpenPanel` pick or a parsed `.sublime-project` file) and an opened
        // document's `fileURL` can come back in different forms of the same real path.
        // The exact mismatch that broke `FileIndexTests` earlier this session.
        let targetComponents = url.resolvingSymlinksInPath().pathComponents
        for root in roots {
            let rootComponents = root.url.resolvingSymlinksInPath().pathComponents
            guard targetComponents.count > rootComponents.count,
                  Array(targetComponents.prefix(rootComponents.count)) == rootComponents
            else { continue }

            var node = root
            for component in targetComponents[rootComponents.count...] {
                outlineView.expandItem(node)
                guard let match = children(of: node).first(where: { $0.url.lastPathComponent == component })
                else { return }
                node = match
            }
            let row = outlineView.row(forItem: node)
            guard row >= 0 else { return }
            outlineView.selectRowIndexes([row], byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
            return
        }
    }

    private func children(of node: Node) -> [Node] {
        if let cached = node.children { return cached }
        let loaded = Sidebar.loadChildren(of: node, excludedNames: excludedNames)
        node.children = loaded
        watchDirectory(node)
        return loaded
    }

    private static func loadChildren(of node: Node, excludedNames: Set<String>) -> [Node] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: node.url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        let children = entries
            .filter { !excludedNames.contains($0.lastPathComponent) }
            .map { url -> Node in
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                return Node(url: url, displayName: url.lastPathComponent, isDirectory: isDirectory, parent: node)
            }
        // Folders first, then files, each alphabetically — Sublime's own sidebar order.
        return children.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private func watchDirectory(_ node: Node) {
        // A watcher already covers this directory — critically, including after its own
        // event handler cleared `node.children` and this got called again via
        // `children(of:)` reloading. The existing `DispatchSourceFileSystemObject`
        // watches by file descriptor, not by content, so it's still perfectly valid;
        // without this guard, every FS change here would open and leak a second fd and a
        // second live source for the same directory, forever.
        guard watchers[ObjectIdentifier(node)] == nil else { return }
        guard watchers.count < Sidebar.maximumWatchedDirectories else { return }
        let descriptor = open(node.url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write,
                                                               queue: .main)
        source.setEventHandler { [weak self, weak node] in
            guard let self, let node else { return }
            node.children = nil
            self.outlineView.reloadItem(node, reloadChildren: true)
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watchers[ObjectIdentifier(node)] = source
    }

    // MARK: - Actions

    @objc private func rowClicked() {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? Node, !node.isDirectory else { return }
        onOpenFile?(node.url)
    }

    @objc private func newFile() {
        guard let folder = contextNode, folder.isDirectory, let window else { return }
        promptForName(message: "New file:", defaultValue: "untitled.txt", in: window) { [weak self] name in
            guard let self, let name else { return }
            let url = folder.url.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: url.path) else { return }
            FileManager.default.createFile(atPath: url.path, contents: Data())
            self.invalidateChildren(of: folder)
            self.onOpenFile?(url)
        }
    }

    @objc private func newFolder() {
        guard let folder = contextNode, folder.isDirectory, let window else { return }
        promptForName(message: "New folder:", defaultValue: "untitled folder", in: window) { [weak self] name in
            guard let self, let name else { return }
            let url = folder.url.appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            self.invalidateChildren(of: folder)
        }
    }

    /// Root folders (no `parent`) can't be renamed or deleted from here — only removed
    /// from the project (not yet exposed as its own command), since doing either would
    /// move or destroy the actual folder the project points at, out from under it.
    @objc private func rename() {
        guard let node = contextNode, let parent = node.parent, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Rename \"\(node.displayName)\""
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        textField.stringValue = node.displayName
        alert.accessoryView = textField
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let newName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty, newName != node.displayName else { return }
            let newURL = node.url.deletingLastPathComponent().appendingPathComponent(newName)
            do {
                try FileManager.default.moveItem(at: node.url, to: newURL)
                self.invalidateChildren(of: parent)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    @objc private func delete() {
        guard let node = contextNode, let parent = node.parent, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Move \"\(node.displayName)\" to Trash?"
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            do {
                try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
                self.invalidateChildren(of: parent)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    @objc private func revealInFinder() {
        guard let node = contextNode else { return }
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    private func invalidateChildren(of node: Node) {
        node.children = nil
        outlineView.reloadItem(node, reloadChildren: true)
    }

    private func promptForName(message: String, defaultValue: String, in window: NSWindow,
                               completion: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        textField.stringValue = defaultValue
        alert.accessoryView = textField
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { completion(nil); return }
            let name = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            completion(name.isEmpty ? nil : name)
        }
    }
}

// MARK: - NSOutlineViewDataSource

extension Sidebar: NSOutlineViewDataSource {

    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let node = item as? Node { return children(of: node).count }
        return roots.count
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? Node { return children(of: node)[index] }
        return roots[index]
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Node)?.isDirectory ?? false
    }
}

// MARK: - NSOutlineViewDelegate

extension Sidebar: NSOutlineViewDelegate {

    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?,
                            item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("SidebarCell")
        let cell: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingMiddle
            cell.addSubview(imageView)
            cell.addSubview(textField)
            cell.imageView = imageView
            cell.textField = textField
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = node.displayName
        // `NSWorkspace.icon(forFile:)` returns the correct Finder-style icon for either a
        // file or a directory from the same call — no separate folder-icon lookup needed.
        cell.imageView?.image = NSWorkspace.shared.icon(forFile: node.url.path)
        return cell
    }
}

// MARK: - NSMenuDelegate (contextual menu)

extension Sidebar: NSMenuDelegate {

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? Node else {
            contextNode = nil
            return
        }
        contextNode = node

        if node.isDirectory {
            menu.addItem(withTitle: "New File…", action: #selector(newFile), keyEquivalent: "")
            menu.addItem(withTitle: "New Folder…", action: #selector(newFolder), keyEquivalent: "")
            menu.addItem(.separator())
        }
        if node.parent != nil {
            menu.addItem(withTitle: "Rename…", action: #selector(rename), keyEquivalent: "")
            menu.addItem(withTitle: "Delete", action: #selector(delete), keyEquivalent: "")
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Reveal in Finder", action: #selector(revealInFinder), keyEquivalent: "")
        for item in menu.items { item.target = self }
    }
}
