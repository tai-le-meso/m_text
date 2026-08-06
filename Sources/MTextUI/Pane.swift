import AppKit

/// One open document within a window: its own editor and therefore its own document,
/// undo stack, selection and scroll position, plus the scroll view that hosts it.
///
/// Tabs are never torn down when they lose focus — only their scroll view is hidden —
/// so nothing about a background tab needs to be captured and restored by hand when the
/// user switches back to it; the `EditorView` itself already remembers everything.
///
/// `internal` rather than `private` (moved out of `MainWindowController.swift`, where it
/// used to be file-scoped-private, into this file, T81) — `Pane` needs to hold an array
/// of these, and Swift's `private` is file-scoped, not type-scoped, so a same-module,
/// different-file type can't see a `private` one. `internal` (the default, no modifier)
/// is exactly right: visible everywhere in `MTextUI`, not exposed outside it.
final class Tab {
    let editor: EditorView
    let scrollView: NSScrollView
    /// Wraps the scroll view *and* the minimap (T93). Showing or hiding a tab toggles this,
    /// not the scroll view, so the overview strip travels with its document.
    let container: NSView

    init(editor: EditorView, scrollView: NSScrollView, container: NSView) {
        self.editor = editor
        self.scrollView = scrollView
        self.container = container
    }

    var title: String { editor.document.fileURL?.lastPathComponent ?? "untitled" }
    var isDirty: Bool { editor.document.isDirty }
}

/// One independent group of tabs within a window (T81 — Split Panes): its own tab bar,
/// its own stack of editor scroll views, its own active tab. A window with no split has
/// exactly one `Pane`; "Split View" (View menu) adds a second, side by side.
///
/// Deliberately scoped to a single 2-pane split rather than an arbitrary N-column/row
/// grid: nearly every existing feature (Goto Anything, Jump History, Command Palette,
/// keymap dispatch) was written assuming one tab list per window, and reworking all of
/// that for an arbitrary grid at once, with no compiler on hand to catch mistakes, was a
/// scope/risk tradeoff made deliberately in favor of the smaller, safer change. Nothing
/// about `Pane` itself assumes a cap of two — `MainWindowController` is what currently
/// only ever creates at most one extra pane and only ever arranges two side by side.
final class Pane {

    /// Read-only from outside: every mutation goes through a method below, so
    /// `MainWindowController` can't get this array out of sync with `tabBar`'s own
    /// `items`/`scrollView.isHidden` state.
    private(set) var tabs: [Tab] = []
    /// Force-unwrapped: a `Pane` is never left without an active tab — the only way to
    /// empty `tabs` entirely is `removeTab(at:)`, and `MainWindowController` always
    /// either activates a replacement or tears the whole pane down in that same call,
    /// never leaving a tab-less `Pane` around to read this from.
    var activeTab: Tab!

    let tabBar = TabBar()
    private let tabBarScroll = NSScrollView()
    /// All tabs' scroll views are stacked on the same rect within this view; only the
    /// active one has `isHidden == false`.
    let editorContainer = NSView()

    /// Hosts the window's shared `FindBar` while this pane has focus, directly above the
    /// editor and below the tab bar — the placement Sublime and TextEdit both use.
    ///
    /// The find bar used to be a sibling of the whole pane split view down at the window
    /// bottom, so showing it resized *the entire pane area* (both panes, tab bars
    /// included). Keeping it inside the pane means showing it only resizes this pane's
    /// editor container, which is the smallest thing that actually has to change.
    /// Collapsed to zero height when the bar is hidden, so the editor gets the space back.
    let findBarHost = NSView()
    private(set) var findBarHeight: NSLayoutConstraint!

    /// Hosts the build output panel (T95), below the editor. Collapsed to zero height when
    /// no build has run — same arrangement as `findBarHost`, and for the same reason: only a
    /// constraint changes, and the panel keeps its output for next time.
    let buildPanelHost = NSView()
    private(set) var buildPanelHeight: NSLayoutConstraint!

    /// `tabBar` + `findBarHost` + `editorContainer` + `buildPanelHost`, laid out vertically —
    /// what a split adds to the window's pane split view as one arranged subview.
    let view = NSView()

    var editor: EditorView { activeTab.editor }
    var activeIndex: Int { tabs.firstIndex { $0 === activeTab } ?? 0 }

    init() {
        tabBarScroll.documentView = tabBar
        tabBarScroll.hasHorizontalScroller = false
        tabBarScroll.hasVerticalScroller = false
        tabBarScroll.horizontalScrollElasticity = .allowed
        tabBarScroll.verticalScrollElasticity = .none
        // `TabBar.draw(_:)` fills its own background, so this only removes a redundant
        // fill and the `NSVisualEffectView` backdrop AppKit builds behind it. See the
        // matching comment in `MainWindowController.addTab(for:in:)`.
        tabBarScroll.drawsBackground = false
        tabBarScroll.translatesAutoresizingMaskIntoConstraints = false

        editorContainer.translatesAutoresizingMaskIntoConstraints = false
        findBarHost.translatesAutoresizingMaskIntoConstraints = false
        buildPanelHost.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(tabBarScroll)
        view.addSubview(findBarHost)
        view.addSubview(editorContainer)
        view.addSubview(buildPanelHost)
        findBarHeight = findBarHost.heightAnchor.constraint(equalToConstant: 0)
        buildPanelHeight = buildPanelHost.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            tabBarScroll.topAnchor.constraint(equalTo: view.topAnchor),
            tabBarScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBarScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabBarScroll.heightAnchor.constraint(equalToConstant: TabBar.preferredHeight),

            findBarHost.topAnchor.constraint(equalTo: tabBarScroll.bottomAnchor),
            findBarHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            findBarHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            findBarHeight,

            editorContainer.topAnchor.constraint(equalTo: findBarHost.bottomAnchor),
            editorContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            editorContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            editorContainer.bottomAnchor.constraint(equalTo: buildPanelHost.topAnchor),

            buildPanelHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            buildPanelHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            buildPanelHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            buildPanelHeight,
        ])
    }

    func append(_ tab: Tab) {
        tabs.append(tab)
    }

    func removeTab(at index: Int) {
        tabs.remove(at: index)
    }

    func moveTab(from index: Int, to newIndex: Int) {
        tabs.swapAt(index, newIndex)
    }

    /// Sets `activeTab` and shows/hides every tab's scroll view accordingly. Does *not*
    /// touch window-level chrome (title, status line, first responder) — callers that
    /// need that also call through `MainWindowController.activate(_:)`, which wraps this.
    func activate(_ tab: Tab) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        activeTab = tab
        for candidate in tabs { candidate.container.isHidden = (candidate !== tab) }
    }

    /// Every tab's container is stacked in `editorContainer` with identical constraints, so
    /// only `isHidden` decides what you see. If two are visible you see whichever is topmost
    /// in subview order, which need not be the tab the controller is routing keys to — the
    /// document then changes while the screen does not.
    var visibleContainerCount: Int { tabs.filter { !$0.container.isHidden }.count }
    var activeContainerIsVisible: Bool { activeTab.map { !$0.container.isHidden } ?? false }

    func refreshTabBar() {
        tabBar.items = tabs.map { TabBar.Item(title: $0.title, isDirty: $0.isDirty) }
        tabBar.selectedIndex = activeIndex
    }
}
