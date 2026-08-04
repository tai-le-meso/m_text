import AppKit
import MTextCore

public final class MainWindowController: NSWindowController {

    // MARK: - Panes (T81) and sidebar (T82)

    /// One or two panes side by side (see `Pane`'s own doc comment for why the cap).
    /// Always non-empty: `init` creates and activates one before returning.
    private var panes: [Pane] = []
    private var focusedPaneIndex = 0
    private var focusedPane: Pane { panes[focusedPaneIndex] }

    /// Every tab across every pane — for window-wide concerns (re-detecting syntax
    /// after a grammar import, Goto Anything's fallback scan roots, the dirty-tabs
    /// count on window close) that shouldn't only see whichever pane has focus.
    private var allTabs: [Tab] { panes.flatMap { $0.tabs } }

    /// Forwarding shims to `focusedPane`, preserving nearly every existing call site
    /// (`tabs`, `activeTab`, `editor`, ...) exactly as they were before panes existed —
    /// only the handful of methods that manage panes themselves, or that explicitly
    /// need *every* tab (`allTabs`, above), needed to change at all.
    private var tabs: [Tab] { focusedPane.tabs }
    private var activeTab: Tab! { focusedPane.activeTab }
    private var editor: EditorView { activeTab.editor }
    private var activeIndex: Int { tabs.firstIndex { $0 === activeTab } ?? 0 }

    /// Read-only window into `focusedPaneIndex` for the `MTEXT_SMOKE_TEST` hook, which
    /// lives in the executable target and so can't see anything `private`. Exposed rather
    /// than loosening `focusedPaneIndex` itself, so nothing outside can *set* it.
    public var smokeTestFocusedPaneIndex: Int { focusedPaneIndex }

    /// Diagnostics the last build produced, for the `MTEXT_SMOKE_TEST` hook (T95). Same
    /// reason as above: the hook lives in the executable target and can't see `BuildPanel`,
    /// which stays internal.
    public var smokeTestBuildDiagnostics: [(file: String, line: Int, column: Int)] {
        buildPanel.diagnostics.map { ($0.file, $0.line, $0.column) }
    }

    private let sidebar = Sidebar()
    private let sidebarSplitView = NSSplitView()
    private let paneSplitView = NSSplitView()

    private let statusLabel = NSTextField(labelWithString: "")
    private let findBar = FindBar()
    /// Which pane currently hosts `findBar` in its `findBarHost`, so hiding collapses the
    /// right pane's slot even if focus has since moved to the other pane. One shared bar
    /// across both panes (unchanged from before — see T81's notes); only where it is
    /// mounted changes.
    private var findBarPane: Pane?
    private var findBarEdgeConstraints: [NSLayoutConstraint] = []

    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        window.center()
        window.setFrameAutosaveName("m_text.MainWindow")
        window.tabbingMode = .disallowed
        window.delegate = self

        statusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .right
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        findBar.translatesAutoresizingMaskIntoConstraints = false
        findBar.delegate = self
        findBar.isHidden = true

        paneSplitView.isVertical = true
        paneSplitView.dividerStyle = .thin
        paneSplitView.translatesAutoresizingMaskIntoConstraints = false
        paneSplitView.delegate = self

        let pane = Pane()
        pane.tabBar.delegate = self
        panes = [pane]
        paneSplitView.addSubview(pane.view)

        // `workspace`, `sidebar`, and `sidebarSplitView` deliberately KEEP
        // `translatesAutoresizingMaskIntoConstraints = true` (the default): each is
        // positioned by its parent setting its *frame* — the window sets its
        // contentView's frame, and `NSSplitView` sets its arranged subviews' frames —
        // and the translated autoresizing constraints are exactly what anchors those
        // frames in the Auto Layout world. Setting `translates...=false` on them (as an
        // earlier revision did) left them with NO size/position-defining constraints at
        // all — an *ambiguous* layout that the engine resolved arbitrarily: fine on the
        // first frame-based pass at launch, then collapsing `workspace` to hug just the
        // find bar + status label on the next real constraint solve (the
        // `layoutSubtreeIfNeeded` in `showFindBar`), which blanked the entire pane area
        // (tab bar + editor) irrecoverably. Only views that are *fully pinned by
        // explicit constraints* (`paneSplitView`, `findBar`, `statusLabel`, and the
        // subviews inside `Pane.view`) opt out of translation.
        // `findBar` is no longer a child of `workspace`: it is mounted into whichever
        // pane has focus (see `showFindBar`), so the only things left at window level are
        // the pane area and the status line.
        let workspace = NSView()
        workspace.addSubview(paneSplitView)
        workspace.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            paneSplitView.topAnchor.constraint(equalTo: workspace.topAnchor),
            paneSplitView.leadingAnchor.constraint(equalTo: workspace.leadingAnchor),
            paneSplitView.trailingAnchor.constraint(equalTo: workspace.trailingAnchor),
            paneSplitView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -2),

            statusLabel.leadingAnchor.constraint(equalTo: workspace.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: workspace.trailingAnchor, constant: -8),
            statusLabel.bottomAnchor.constraint(equalTo: workspace.bottomAnchor, constant: -4),
        ])

        // Hidden (zero width) until a project or ad hoc folder is opened — see
        // `setProject(_:)`. Frame-positioned by the split view (see the comment on
        // `workspace` above), so no `translatesAutoresizingMaskIntoConstraints = false`.
        sidebar.isHidden = true
        sidebar.onOpenFile = { [weak self] url in self?.open(url: url) }

        sidebarSplitView.isVertical = true
        sidebarSplitView.dividerStyle = .thin
        sidebarSplitView.delegate = self
        sidebarSplitView.addSubview(sidebar)
        sidebarSplitView.addSubview(workspace)
        // Sidebar's preferred width when shown; `holdingPriority` keeps `workspace` the
        // side that actually grows/shrinks as the window resizes.
        sidebarSplitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)

        window.contentView = sidebarSplitView
        // Auto Layout only resolves geometry lazily at the next display pass; forcing it
        // now means the tab bar's very first layout (triggered by creating the first tab
        // below) already sees the window's real width instead of a transient zero size.
        window.contentView?.layoutSubtreeIfNeeded()

        // An import can add the grammar this document should have been using.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(grammarsDidChange),
            name: SyntaxMenuController.grammarsDidChange,
            object: nil
        )
        // T86: a settings file was edited (in this app or any other editor).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange),
            name: SettingsController.settingsDidChange,
            object: nil
        )

        activate(makeBlankTab(in: pane))
    }

    /// Built-in grammars plus anything in the user's Packages folder. Owned by the
    /// Syntax menu controller so an import and the menu stay in step.
    public static var sharedRegistry: GrammarRegistry { SyntaxMenuController.shared.registry }

    /// Name and scope of the grammar this window is using. The menu checkmarks by scope.
    public var currentSyntaxName: String { editor.syntaxName }
    public var currentSyntaxScope: String { editor.syntaxScope }

    @objc private func grammarsDidChange() {
        // An import may have added the grammar a file should have been using — but
        // never override a syntax the user picked by hand, in any tab, in any pane.
        for tab in allTabs where tab.editor.autoDetectsSyntax {
            tab.editor.detectSyntax()
        }
        // An import can change which syntax a tab uses, and therefore which syntax
        // settings layer applies to it.
        applySettingsToAllTabs()
        refreshChrome()
        for pane in panes { pane.refreshTabBar() }
    }

    @objc public func setSyntaxFromMenu(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        let registry = MainWindowController.sharedRegistry
        let grammar = (item.representedObject as? String).flatMap { registry.grammar(forScope: $0) }
            ?? registry.grammar(named: item.title)
        guard let grammar else { return }
        editor.setGrammar(grammar, isManualChoice: true)
        // The syntax layer is keyed by syntax name, so changing the syntax can change
        // every resolved setting (this is what makes per-language `tab_size` work).
        applySettings(to: activeTab)
        refreshChrome()
    }

    // MARK: - Build systems (T95)

    private let buildRunner = BuildRunner()
    private lazy var buildPanel: BuildPanel = {
        let panel = BuildPanel(frame: .zero)
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.onCancel = { [weak self] in self?.cancelBuild(nil) }
        panel.onJump = { [weak self] diagnostic in self?.jump(to: diagnostic) }
        return panel
    }()
    private var buildPanelPane: Pane?
    /// The build system last run, so ⌘B repeats it rather than re-asking.
    private var lastBuildSystem: BuildSystem?

    /// Variables for the active tab, resolved at run time rather than at parse time so the
    /// same build system works from whichever file is in front.
    private func buildVariables() -> BuildVariables {
        BuildVariables(filePath: textDocument.fileURL?.path ?? "",
                       projectPath: currentProject?.fileURL?.path ?? "",
                       folder: currentProject?.folders.first?.url.path
                           ?? textDocument.fileURL?.deletingLastPathComponent().path ?? "",
                       packages: BuildSystemStore.defaultDirectories.first?.path ?? "")
    }

    /// ⌘B — run the last build system, or pick one when there is no obvious choice.
    ///
    /// **Only ever reached from this command.** Nothing about opening a file, restoring a
    /// session or changing syntax runs a build; see `BuildRunner`'s note.
    @objc public func build(_ sender: Any?) {
        if let system = lastBuildSystem {
            start(system)
            return
        }
        let candidates = BuildSystemStore.matching(
            scope: editor.syntaxScope,
            in: BuildSystemStore.available(directories: BuildSystemStore.defaultDirectories))
        guard !candidates.isEmpty else {
            statusLabel.stringValue = "No build system — add a .sublime-build to ~/Library/Application Support/m_text/Build"
            NSSound.beep()
            return
        }
        // One obvious candidate and no variants: just run it. Otherwise ask, rather than
        // guessing which of several commands the user meant.
        if candidates.count == 1, candidates[0].variants.isEmpty {
            start(candidates[0])
        } else {
            chooseBuildSystem(sender)
        }
    }

    /// **Build With…** — a palette over every applicable build system and variant.
    @objc public func chooseBuildSystem(_ sender: Any?) {
        guard let window else { return }
        let systems = BuildSystemStore.matching(
            scope: editor.syntaxScope,
            in: BuildSystemStore.available(directories: BuildSystemStore.defaultDirectories))
        // Variants are offered alongside their parent — that is how a "Run" or "Test" is
        // reached, and Sublime lists them the same way.
        var choices: [BuildSystem] = []
        for system in systems {
            if system.isRunnable { choices.append(system) }
            choices.append(contentsOf: system.variants)
        }
        guard !choices.isEmpty else {
            statusLabel.stringValue = "No build system applies to this file"
            NSSound.beep()
            return
        }

        overlayPalette.onQueryChanged = { [weak self] query in
            let names = choices.map(\.name)
            let ranked: [(index: Int, match: FuzzyMatcher.Match)] = query.isEmpty
                ? names.indices.map { ($0, FuzzyMatcher.Match(score: 0, indices: [])) }
                : FuzzyMatcher.rank(query: query, candidates: names)
            self?.overlayPalette.setItems(ranked.map { entry in
                let system = choices[entry.index]
                let command = system.cmd.isEmpty ? (system.shellCmd ?? "") : system.cmd.joined(separator: " ")
                return PaletteItem(title: system.name, subtitle: command,
                                   matchedIndices: entry.match.indices, payload: entry.index)
            })
        }
        overlayPalette.onHighlightChanged = { _ in }
        overlayPalette.onCommit = { [weak self] item in
            guard let self, let index = item.payload as? Int, choices.indices.contains(index) else { return }
            self.start(choices[index])
        }
        overlayPalette.onCancel = {}
        overlayPalette.show(over: window, placeholder: "Build With…")
        overlayPalette.onQueryChanged?("")
    }

    @objc public func cancelBuild(_ sender: Any?) {
        buildRunner.cancel()
        buildPanel.finishBuild(status: nil)
    }

    private func start(_ system: BuildSystem) {
        lastBuildSystem = system
        showBuildPanel()
        let variables = buildVariables()
        let workingDirectory = system.workingDir.map { variables.expand($0) } ?? variables.folder

        buildRunner.onOutput = { [weak self] text in self?.buildPanel.append(text) }
        buildRunner.onFinish = { [weak self] status in
            self?.buildPanel.finishBuild(status: status)
        }
        guard let command = buildRunner.run(system, variables: variables) else {
            statusLabel.stringValue = "Build system \(system.name) has nothing to run"
            return
        }
        buildPanel.beginBuild(command: command, fileRegex: system.fileRegex,
                              workingDirectory: workingDirectory)
    }

    /// F4 / ⇧F4 — step through the errors the last build reported.
    @objc public func nextBuildError(_ sender: Any?) {
        if !buildPanel.goToDiagnostic(offset: 1) { NSSound.beep() }
    }

    @objc public func previousBuildError(_ sender: Any?) {
        if !buildPanel.goToDiagnostic(offset: -1) { NSSound.beep() }
    }

    private func jump(to diagnostic: BuildDiagnostic) {
        guard FileManager.default.fileExists(atPath: diagnostic.file) else {
            statusLabel.stringValue = "Cannot find \(diagnostic.file)"
            return
        }
        openAndJump(to: URL(fileURLWithPath: diagnostic.file),
                    line: diagnostic.line, column: diagnostic.column)
        statusLabel.stringValue = diagnostic.message
    }

    /// Mounts the panel in the focused pane, the same way the find bar is mounted.
    private func showBuildPanel() {
        let pane = focusedPane
        if buildPanelPane !== pane {
            buildPanelPane?.buildPanelHeight.constant = 0
            buildPanel.removeFromSuperview()
            pane.buildPanelHost.addSubview(buildPanel)
            NSLayoutConstraint.activate([
                buildPanel.topAnchor.constraint(equalTo: pane.buildPanelHost.topAnchor),
                buildPanel.leadingAnchor.constraint(equalTo: pane.buildPanelHost.leadingAnchor),
                buildPanel.trailingAnchor.constraint(equalTo: pane.buildPanelHost.trailingAnchor),
                buildPanel.bottomAnchor.constraint(equalTo: pane.buildPanelHost.bottomAnchor),
            ])
            buildPanelPane = pane
        }
        pane.buildPanelHeight.constant = BuildPanel.preferredHeight
        window?.contentView?.layoutSubtreeIfNeeded()
        editor.wrapWidthDidChange()
    }

    /// Hides the panel without discarding what it holds.
    @objc public func toggleBuildPanel(_ sender: Any?) {
        guard let pane = buildPanelPane else { return }
        pane.buildPanelHeight.constant = pane.buildPanelHeight.constant > 0 ? 0 : BuildPanel.preferredHeight
        window?.contentView?.layoutSubtreeIfNeeded()
        editor.wrapWidthDidChange()
    }

    // MARK: - Macros (T94)

    /// Saves the last recorded macro as a `.sublime-macro` file, so it survives a relaunch
    /// and can be shared or hand-edited.
    @objc public func saveMacro(_ sender: Any?) {
        guard let window else { return }
        guard let macro = EditorView.lastMacro, !macro.isEmpty else {
            NSSound.beep()
            statusLabel.stringValue = "No macro to save"
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Macro.sublime-macro"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try MacroParser.serialize(macro).write(to: url, options: .atomic)
            } catch {
                self?.showError(error)
            }
        }
    }

    @objc public func openMacro(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // Filtered by the delegate, like the project and syntax pickers: no UTType is
        // registered for `.sublime-macro`.
        panel.delegate = self
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                let macro = try MacroParser.parse(data: Data(contentsOf: url))
                guard !macro.isEmpty else {
                    self.statusLabel.stringValue = "That macro has no usable steps"
                    return
                }
                EditorView.lastMacro = macro
                self.statusLabel.stringValue = "Loaded \(macro.steps.count) steps — ⌃⌘P to run"
            } catch {
                self.showError(error)
            }
        }
    }

    // MARK: - Snippets (T91)

    /// **Insert Snippet…** — a palette over every loaded snippet, for the ones you haven't
    /// memorised a tab trigger for. Reuses `Palette` and `FuzzyMatcher` exactly as Goto
    /// Anything does, so the interaction is identical.
    @objc public func insertSnippet(_ sender: Any?) {
        guard let window else { return }
        let store = EditorView.snippetStore
        store.reload()   // picks up a file dropped in since launch, like the Syntax menu does

        let snippets = store.snippets
        guard !snippets.isEmpty else {
            findBar.updateStatus("No snippets installed", isError: true)
            return
        }

        func items(matching query: String) -> [PaletteItem] {
            let labels = snippets.map { snippet -> String in
                snippet.description ?? snippet.name
            }
            let ranked: [(index: Int, match: FuzzyMatcher.Match)] = query.isEmpty
                ? labels.indices.map { ($0, FuzzyMatcher.Match(score: 0, indices: [])) }
                : FuzzyMatcher.rank(query: query, candidates: labels)
            return ranked.prefix(200).map { entry in
                let snippet = snippets[entry.index]
                // The trigger is the useful subtitle: it's what you'd type next time.
                let subtitle = snippet.tabTrigger.map { "⇥ \($0)" }
                return PaletteItem(title: labels[entry.index],
                                   subtitle: subtitle,
                                   matchedIndices: entry.match.indices,
                                   payload: entry.index)
            }
        }

        overlayPalette.onQueryChanged = { [weak self] query in
            self?.overlayPalette.setItems(items(matching: query))
        }
        // Snippets insert text, so previewing on highlight would edit the document as you
        // arrow through the list — only committing inserts.
        overlayPalette.onHighlightChanged = { _ in }
        overlayPalette.onCommit = { [weak self] item in
            guard let self, let index = item.payload as? Int, snippets.indices.contains(index)
            else { return }
            self.editor.insertSnippet(snippets[index])
            self.window?.makeFirstResponder(self.editor)
        }
        overlayPalette.onCancel = {}

        overlayPalette.show(over: window, placeholder: "Insert Snippet")
        overlayPalette.setItems(items(matching: ""))
    }

    // MARK: - Settings (T86)

    /// Re-resolves the whole stack for one tab and applies it.
    ///
    /// Called on tab creation, on syntax change, on project change, on a view override,
    /// and on a settings-file reload — every event that can move any layer. Resolving the
    /// full stack each time (rather than patching whatever changed) keeps precedence in
    /// exactly one place, and it is cheap: five dictionary lookups per key.
    private func applySettings(to tab: Tab?) {
        guard let tab else { return }
        let settings = SettingsController.shared.store.settings(
            syntaxName: tab.editor.syntaxName,
            project: currentProject?.settings ?? .empty,
            view: tab.editor.viewLayer
        )
        tab.editor.applySettings(settings)
    }

    private func applySettingsToAllTabs() {
        for tab in allTabs { applySettings(to: tab) }
    }

    @objc private func settingsDidChange() {
        applySettingsToAllTabs()
    }

    /// **Preferences: Settings** — opens the read-only defaults and the user's own file
    /// side by side, which is why T86 pairs this command with split panes: the left pane
    /// is documentation, the right is what you edit.
    @objc public func openPreferences(_ sender: Any?) {
        let store = SettingsController.shared.store
        do {
            let defaults = try store.writeDefaultFile()
            let user = try store.ensureUserFileExists()

            // Reuse the existing split rather than forcing a second one: with two panes
            // already open, "side by side" is satisfied by putting one file in each.
            if panes.count < 2 { splitViewRight(nil) }
            focusedPaneIndex = 0
            open(url: defaults)
            focusedPaneIndex = min(1, panes.count - 1)
            open(url: user)
        } catch {
            showError(error)
        }
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeFirstResponder(editor)
    }

    // Not named `document` — NSWindowController already declares that property.
    private var textDocument: TextDocument { editor.document }

    private func refreshChrome() {
        let fileName = textDocument.fileURL?.lastPathComponent ?? "untitled"
        // Folds the open project's name into the title (when there is one) rather than
        // `setProject` setting `window?.title` directly — this runs on every tab switch
        // and edit already, so it's the one place that can keep the title correct as the
        // active *file* changes without also having to re-derive the project half of it
        // from scratch at every one of those call sites.
        window?.title = currentProject.map { "\(fileName) — \(projectDisplayName($0))" } ?? fileName
        window?.representedURL = textDocument.fileURL
        var parts: [String] = []
        let selection = editor.selectionSummary
        if !selection.isEmpty { parts.append(selection) }
        parts.append("\(textDocument.lineCount) lines")
        parts.append(textDocument.encoding.displayName)
        parts.append(textDocument.lineEnding.displayName)
        parts.append(editor.syntaxName)
        statusLabel.stringValue = parts.joined(separator: " · ")
        // Session crash protection (T84/T85): almost everything session-relevant —
        // edits, caret moves, tab switches, project changes — already funnels through
        // here, making it the one cheap hook for "something changed, snapshot soon".
        // `SessionManager` debounces, so the post-per-keystroke rate is fine.
        NotificationCenter.default.post(name: SessionManager.stateDidChange, object: self)
    }

    private func refreshTabBar() {
        focusedPane.refreshTabBar()
    }

    // MARK: - Tabs

    @objc public func newTab(_ sender: Any?) {
        activate(makeBlankTab(in: focusedPane))
    }

    @discardableResult
    private func makeBlankTab(in pane: Pane) -> Tab {
        addTab(for: EditorView(), in: pane)
    }

    @discardableResult
    private func makeTab(loadingURL url: URL, in pane: Pane) throws -> Tab {
        let editorView = EditorView()
        try editorView.loadFile(url)
        return addTab(for: editorView, in: pane)
    }

    private func addTab(for editorView: EditorView, in pane: Pane) -> Tab {
        configureEditor(editorView)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        // `EditorView` is opaque and repaints its whole visible rect with the theme
        // background, so the scroll view's own background is never seen; leaving it on
        // also makes AppKit build an `NSVisualEffectView` backdrop behind the document
        // view for no reason. (Tried while chasing the blank-pane bug, KNOWLEDGE.md; it was
        // not the cause. Kept as a redundant-work removal, not a fix.)
        scrollView.drawsBackground = false
        scrollView.documentView = editorView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // T93: the scroll view and the minimap sit side by side in a per-tab container, so
        // the minimap belongs to *this* document rather than to the pane — switching tabs
        // shows that tab's own overview, and hiding one tab's container hides both together.
        let minimap = Minimap(frame: .zero)
        minimap.editor = editorView
        minimap.translatesAutoresizingMaskIntoConstraints = false
        editorView.minimap = minimap

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
        container.addSubview(minimap)

        // Collapsed to zero width when off, rather than removed: the constraint is the only
        // thing that has to change, and the view keeps its editor reference for next time.
        let minimapWidth = minimap.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.trailingAnchor.constraint(equalTo: minimap.leadingAnchor),

            minimap.topAnchor.constraint(equalTo: container.topAnchor),
            minimap.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            minimap.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            minimapWidth,
        ])

        // Hidden until activated — on the *container* now, so the minimap hides with it.
        container.isHidden = true
        pane.editorContainer.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: pane.editorContainer.topAnchor),
            container.leadingAnchor.constraint(equalTo: pane.editorContainer.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: pane.editorContainer.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: pane.editorContainer.bottomAnchor),
        ])

        editorView.onMinimapVisibilityChanged = { [weak editorView] in
            guard let editorView else { return }
            minimapWidth.constant = editorView.minimapEnabled ? Minimap.preferredWidth : 0
            // The editor's viewport just changed width, so wrapping has to re-measure (T28).
            container.layoutSubtreeIfNeeded()
            editorView.wrapWidthDidChange()
            editorView.refreshMinimap()
        }

        let tab = Tab(editor: editorView, scrollView: scrollView, container: container)
        pane.append(tab)
        pane.refreshTabBar()
        // After `pane.append`, so the tab is reachable from `allTabs` — and after
        // `configureEditor` has detected the syntax, since the syntax layer is keyed by
        // syntax name.
        applySettings(to: tab)
        return tab
    }

    /// Wires the closures and highlighting every tab's editor needs — this used to run
    /// once in `init` for the single editor; now it runs once per tab.
    private func configureEditor(_ editorView: EditorView) {
        editorView.onFindRequested = { [weak self, weak editorView] withReplace in
            guard let self else { return }
            // Mount the bar in the pane whose editor *actually received* ⌘F, rather than
            // trusting `focusedPaneIndex`. The menu dispatches ⌘F down the responder chain
            // to whichever editor has focus, so that editor is the ground truth for "which
            // side am I searching" — and it stays correct even if some path forgets to
            // keep `focusedPaneIndex` in step, which is precisely how the bar ended up
            // opening on the wrong side. Syncing the index here also repairs it.
            if let editorView,
               let index = self.panes.firstIndex(where: { pane in
                   pane.tabs.contains { $0.editor === editorView }
               }) {
                self.focusedPaneIndex = index
            }
            self.showFindBar(withReplace: withReplace)
        }
        editorView.onFindSeedText = { [weak self] text in
            self?.findBar.setSearchText(text)
        }
        editorView.onFindStatusChanged = { [weak self] text, isError in
            self?.findBar.updateStatus(text, isError: isError)
        }
        // `[weak editorView]` too, not just `[weak self]`: this closure is stored *on*
        // `editorView` itself, so capturing it strongly would make the editor retain a
        // closure that retains the editor right back — a self-cycle `self` being weak
        // does nothing to break. Tabs open and close repeatedly within one window's
        // life now, unlike the old single-editor setup, so that leak would compound.
        editorView.onChange = { [weak self, weak editorView] in
            guard let editorView else { return }
            self?.editorDidChange(editorView)
        }
        editorView.configureHighlighting(registry: MainWindowController.sharedRegistry)

        editorView.keymapEngine.load(userEntries: MainWindowController.keymapEntries.user,
                                     defaultEntries: MainWindowController.keymapEntries.defaults)
        editorView.onKeymapCommand = { [weak self] name, args in
            self?.dispatchKeymapCommand(name, args: args)
        }
        // A View-menu toggle or font zoom changed this editor's own layer (T86); the
        // editor can't re-resolve on its own, since it has no access to the other layers.
        editorView.onViewOverridesChanged = { [weak self, weak editorView] in
            guard let self, let editorView else { return }
            self.applySettings(to: self.allTabs.first { $0.editor === editorView })
        }
        // T94: macro state is app-wide, but its feedback belongs in this window's status
        // line — `refreshChrome` would overwrite it on the next caret move, which is fine:
        // the message is transient by nature.
        editorView.onMacroStatus = { [weak self] message in
            self?.statusLabel.stringValue = message
        }
        editorView.onDidBecomeFirstResponder = { [weak self, weak editorView] in
            guard let self, let editorView else { return }
            self.focusedPaneDidChange(to: editorView)
        }
        // T90: project-wide symbols for autocomplete. Reads only what `symbolIndex`
        // already holds and never triggers a walk — this runs on the keystroke path, and
        // Goto Symbol/Goto Definition are what populate the index (see their own comment
        // about being on-demand rather than indexing on every save).
        editorView.onCompletionSymbols = { [weak self] in
            guard let self else { return [] }
            return self.symbolIndexEntries.map {
                CompletionItem(text: $0.symbol.name,
                               kind: .symbol,
                               detail: "\($0.displayPath):\($0.symbol.line + 1)")
            }
        }
    }

    /// Finds whichever pane holds `tab` — every pane-aware tab operation (`activate`,
    /// `closeTab`, the `TabBarDelegate` methods) starts here rather than assuming
    /// `focusedPane`, since the tab in question isn't necessarily in the pane that
    /// currently has focus (e.g. clicking a tab, or its close button, in the *other*
    /// pane's tab bar).
    private func pane(owning tab: Tab) -> Pane? {
        panes.first { $0.tabs.contains { $0 === tab } }
    }

    private func editorDidChange(_ editorView: EditorView) {
        // The changed tab might be a background tab, in either pane — not necessarily
        // anything's `activeTab` — so its pane is found by membership, not by identity
        // against `activeTab.editor`.
        guard let owningPane = panes.first(where: { pane in pane.tabs.contains { $0.editor === editorView } })
        else { return }
        owningPane.refreshTabBar()
        // Window-level chrome (title, status line, the title bar's dirty dot) only
        // reflects whatever's actually on screen as "the" active document — the
        // focused pane's active tab.
        guard editorView === focusedPane.activeTab?.editor else { return }
        window?.isDocumentEdited = textDocument.isDirty
        refreshChrome()
    }

    /// Activates `tab` within whichever pane owns it, switching focus to that pane
    /// first if it isn't already focused (see `pane(owning:)`).
    private func activate(_ tab: Tab) {
        guard let owningPane = pane(owning: tab) else { return }
        if let index = panes.firstIndex(where: { $0 === owningPane }), index != focusedPaneIndex {
            focusedPaneIndex = index
        }
        owningPane.activate(tab)
        window?.makeFirstResponder(tab.editor)
        window?.isDocumentEdited = tab.editor.document.isDirty
        refreshChrome()
        refreshTabBar()
        // The find bar is shared chrome; follow it to this pane if the activated tab lives
        // in the other one, then re-run its query against the tab that just became active
        // rather than leaving it showing the old tab's matches.
        moveFindBarToFocusedPaneIfNeeded()
        if !findBar.isHidden {
            tab.editor.applySearchQuery(findBar.query)
        }
        // Selecting a row programmatically doesn't touch first responder, so this
        // can't steal keyboard focus back from the editor set above. A no-op when
        // there's no sidebar content (nothing to reveal) or the file isn't under any
        // open root.
        if let url = tab.editor.document.fileURL {
            sidebar.reveal(url)
        }
    }

    @objc public func selectNextTab(_ sender: Any?) {
        guard tabs.count > 1 else { return }
        activate(tabs[(activeIndex + 1) % tabs.count])
    }

    @objc public func selectPreviousTab(_ sender: Any?) {
        guard tabs.count > 1 else { return }
        activate(tabs[(activeIndex - 1 + tabs.count) % tabs.count])
    }

    /// Backs the hidden ⌘1–⌘9 shortcuts: tag 1–8 is that tab, 9 is always the last tab,
    /// matching the browser convention this is borrowed from.
    @objc public func selectTabByTag(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag else { return }
        let index = tag >= 9 ? tabs.count - 1 : tag - 1
        guard tabs.indices.contains(index) else { return }
        activate(tabs[index])
    }

    @objc public func closeActiveTab(_ sender: Any?) {
        closeTab(activeTab)
    }

    private func closeTab(_ tab: Tab) {
        guard tab.isDirty else {
            finishClosingTab(tab)
            return
        }
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes you made to \"\(tab.title)\"?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                self?.saveTab(tab) { saved in
                    if saved { self?.finishClosingTab(tab) }
                }
            case .alertSecondButtonReturn:
                self?.finishClosingTab(tab)
            default:
                break // Cancel: leave the tab open.
            }
        }
    }

    private func finishClosingTab(_ tab: Tab) {
        guard let owningPane = pane(owning: tab),
              let index = owningPane.tabs.firstIndex(where: { $0 === tab })
        else { return }
        let wasActive = tab === owningPane.activeTab
        owningPane.removeTab(at: index)
        tab.container.removeFromSuperview()

        guard !owningPane.tabs.isEmpty else {
            if panes.count > 1 {
                // This pane's last tab just closed and another pane still exists —
                // collapse the split rather than closing the window (only a window's
                // *only* pane running out of tabs closes it, just below).
                removePane(owningPane)
            } else {
                // `close()`, not `performClose(_:)`: the window-level unsaved-changes
                // check already ran per tab above, so there is nothing left to gate on.
                window?.close()
            }
            return
        }
        if wasActive {
            activate(owningPane.tabs[min(index, owningPane.tabs.count - 1)])
        } else {
            owningPane.refreshTabBar()
        }
    }

    /// Saves a specific tab's document, independent of which tab is active — a
    /// background tab can be closed (and so saved) without ever being switched to.
    private func saveTab(_ tab: Tab, completion: @escaping (Bool) -> Void) {
        if let url = tab.editor.document.fileURL {
            do {
                try tab.editor.document.save(to: url)
                pane(owning: tab)?.refreshTabBar()
                completion(true)
            } catch {
                showError(error)
                completion(false)
            }
            return
        }
        guard let window else {
            completion(false)
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "untitled.txt"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else {
                completion(false)
                return
            }
            do {
                try tab.editor.document.save(to: url)
                self?.pane(owning: tab)?.refreshTabBar()
                if tab === self?.focusedPane.activeTab { self?.refreshChrome() }
                completion(true)
            } catch {
                self?.showError(error)
                completion(false)
            }
        }
    }

    // MARK: - Split panes (T81)

    /// Splits the focused pane's tab into a second pane, side by side — capped at two
    /// (see `Pane`'s doc comment for why). The new pane starts with one blank tab and
    /// becomes focused, matching Sublime's own "Split View" behaviour of handing you a
    /// fresh, empty view rather than cloning the tab you split from.
    @objc public func splitViewRight(_ sender: Any?) {
        guard panes.count < 2 else { return }
        let pane = Pane()
        pane.tabBar.delegate = self
        panes.append(pane)
        paneSplitView.addSubview(pane.view)
        // **Required, not tidying.** A classic `NSSplitView` does not redistribute space
        // when a subview is added: the new pane keeps its zero-sized initial frame and is
        // laid out at the far right edge, so "Split View Right" produced a pane that was
        // present, focused, and completely invisible. Everything routed to the focused
        // pane then went nowhere — including, after the find bar moved inside the pane
        // (T60 relocation), ⌘F, which mounted the bar at the correct height and zero
        // width. `adjustSubviews` alone is not enough either: it distributes
        // *proportionally*, and a zero-width subview's share of the proportion is zero, so
        // the divider has to be placed explicitly.
        paneSplitView.adjustSubviews()
        paneSplitView.setPosition(paneSplitView.bounds.width / 2, ofDividerAt: 0)
        activate(makeBlankTab(in: pane))
    }

    /// Closes the focused pane and every tab in it. Mirrors `windowShouldClose`'s own
    /// dirty-tabs prompt (one combined warning, not a per-tab Save/Don't Save/Cancel
    /// dialog) rather than looping `closeTab` per tab: a dirty tab's close flow shows an
    /// *asynchronous* save-prompt sheet, so firing several at once — one per dirty tab —
    /// would either queue confusingly or race, instead of the single clear prompt this
    /// gives closing a whole pane's worth of tabs at once.
    @objc public func closeCurrentPane(_ sender: Any?) {
        guard panes.count > 1 else { return }
        let pane = focusedPane
        let dirtyCount = pane.tabs.filter(\.isDirty).count
        guard dirtyCount > 0 else {
            removePane(pane)
            return
        }
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = dirtyCount == 1
            ? "This pane has one tab with unsaved changes."
            : "This pane has \(dirtyCount) tabs with unsaved changes."
        alert.informativeText = "Closing now will lose those changes."
        alert.addButton(withTitle: "Close Without Saving")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.removePane(pane)
        }
    }

    private func removePane(_ pane: Pane) {
        guard let index = panes.firstIndex(where: { $0 === pane }) else { return }
        // The find bar is shared and lives inside whichever pane hosts it, so a pane
        // being torn down must hand it back first — otherwise it would be removed from
        // the window along with its host, and `findBarPane` would point at a pane that
        // is no longer in `panes`.
        if findBarPane === pane {
            NSLayoutConstraint.deactivate(findBarEdgeConstraints)
            findBarEdgeConstraints.removeAll()
            findBar.removeFromSuperview()
            findBar.isHidden = true
            findBarPane = nil
        }
        pane.view.removeFromSuperview()
        // Symmetric with `splitViewRight`: without this the surviving pane keeps the half
        // width it had while the split existed, leaving the other half blank.
        paneSplitView.adjustSubviews()
        panes.remove(at: index)
        focusedPaneIndex = min(focusedPaneIndex, panes.count - 1)
        window?.makeFirstResponder(focusedPane.editor)
        // Closing the *other* pane shifts which one is focused, so the bar may need to
        // move. (Closing the pane that hosts it is handled above, by detaching it.)
        moveFindBarToFocusedPaneIfNeeded()
        refreshChrome()
        refreshTabBar()
    }

    // MARK: - Sidebar (T82)

    @objc public func toggleSidebar(_ sender: Any?) {
        sidebar.isHidden.toggle()
        // Belt-and-suspenders: `NSSplitView` is expected to treat a hidden arranged
        // subview as collapsed (zero width, divider hidden) on its own, but forcing a
        // relayout here costs nothing and removes any doubt about that timing.
        sidebarSplitView.adjustSubviews()
    }

    // MARK: - Session persistence (T84) and hot exit (T85)

    /// Snapshot of this window for the session file. `writeBuffer` stashes a dirty
    /// tab's full text into the session directory and returns the buffer-file name to
    /// record (nil = the write failed; the tab is then recorded as a plain file
    /// reference and its unsaved changes are, unavoidably, not preserved).
    ///
    /// Lives inside `MainWindowController.swift` (not an extension file) deliberately:
    /// capture and restore need `panes`/`sidebar`/`currentProject`/`loadProject` and
    /// friends, all `private`, and Swift's `private` is file-scoped.
    public func captureSessionWindow(writeBuffer: (String) -> String?) -> SessionWindow {
        var paneStates: [SessionPane] = []
        for pane in panes {
            var tabStates: [SessionTab] = []
            for tab in pane.tabs {
                let document = tab.editor.document
                var state = SessionTab()
                state.filePath = document.fileURL?.path
                if tab.isDirty {
                    state.bufferFile = writeBuffer(document.text)
                    state.encodingRaw = document.encoding.rawValue
                    state.lineEndingRaw = document.lineEnding.rawValue
                }
                let caret = tab.editor.selection.primary.head
                state.caretLine = caret.line
                state.caretColumn = caret.column
                let scrollOrigin = tab.scrollView.contentView.bounds.origin
                state.scrollX = scrollOrigin.x
                state.scrollY = scrollOrigin.y
                // Only a hand-picked syntax is worth recording — auto-detection re-runs
                // on restore anyway, and stays correct if grammars changed between runs.
                if !tab.editor.autoDetectsSyntax {
                    state.syntaxScope = tab.editor.syntaxScope
                }
                tabStates.append(state)
            }
            paneStates.append(SessionPane(tabs: tabStates, activeIndex: pane.activeIndex))
        }

        var state = SessionWindow(sidebarVisible: !sidebar.isHidden,
                                  focusedPaneIndex: focusedPaneIndex,
                                  panes: paneStates)
        if let frame = window?.frame {
            state.frame = [frame.origin.x, frame.origin.y, frame.width, frame.height]
        }
        if let project = currentProject {
            if let fileURL = project.fileURL {
                state.projectFilePath = fileURL.path
            } else {
                // An ad hoc (Open Folder…) project has no file; its one folder is the
                // whole identity.
                state.adHocFolderPath = project.folders.first?.url.path
            }
        }
        return state
    }

    /// Rebuilds this (freshly initialised, one-blank-tab) window from a session
    /// snapshot. Best-effort throughout, matching `SessionStore.load`'s "a broken
    /// session must never block launch" rule: a file that vanished since last quit is
    /// skipped (unless its unsaved content was stashed — that restores as a dirty
    /// buffer), a missing buffer file falls back to the file on disk, an unknown
    /// syntax scope falls back to auto-detection.
    public func restoreSessionWindow(_ state: SessionWindow, store: SessionStore) {
        if let f = state.frame, f.count == 4 {
            let rect = NSRect(x: f[0], y: f[1], width: f[2], height: f[3])
            // Only adopt a frame some connected display can actually show — a session
            // saved on a since-disconnected external monitor must not restore a window
            // nobody can reach.
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) {
                window?.setFrame(rect, display: false)
            }
        }

        if let path = state.projectFilePath, FileManager.default.fileExists(atPath: path) {
            // The existence check isn't just politeness: `loadProject(from:)` reports
            // failures with a sheet, and this window hasn't been shown yet — a sheet on
            // an unordered window is exactly the kind of thing "best-effort, never
            // block launch" exists to avoid. A project file deleted between runs just
            // restores as no project.
            loadProject(from: URL(fileURLWithPath: path))
        } else if let path = state.adHocFolderPath {
            setProject(Project.adHoc(folder: URL(fileURLWithPath: path)))
        }

        for (paneIndex, paneState) in state.panes.enumerated() {
            if paneIndex >= panes.count {
                guard panes.count < 2 else { break } // 2-pane cap, same as splitViewRight
                splitViewRight(nil)
            }
            let pane = panes[paneIndex]
            // `init` (pane 0) / `splitViewRight` (pane 1) each created a blank
            // placeholder tab; remembered here and closed once real tabs are in, so a
            // restore doesn't leave a stray empty "untitled" at the front of the row.
            let placeholder = pane.tabs.first

            var restoredCount = 0
            for tabState in paneState.tabs where restoreTab(tabState, into: pane, store: store) != nil {
                restoredCount += 1
            }
            if restoredCount > 0, let placeholder,
               placeholder.editor.document.fileURL == nil, !placeholder.isDirty {
                finishClosingTab(placeholder)
            }
            let activeIndex = min(max(paneState.activeIndex, 0), pane.tabs.count - 1)
            if pane.tabs.indices.contains(activeIndex) {
                activate(pane.tabs[activeIndex])
            }
        }

        // Focus the recorded pane last, after the per-pane activations above.
        if panes.indices.contains(state.focusedPaneIndex),
           let tab = panes[state.focusedPaneIndex].activeTab {
            activate(tab)
        }

        // `setProject` above already showed/hid the sidebar by whether the project has
        // folders; the session's explicit visibility (the user may have ⌘K⌘B'd it away)
        // wins — but never shows a sidebar with no project to list.
        sidebar.isHidden = !(state.sidebarVisible && currentProject != nil)
        sidebarSplitView.adjustSubviews()
        refreshChrome()
    }

    /// One tab of `restoreSessionWindow`. nil when there's nothing left to restore
    /// (file gone from disk and no stashed buffer).
    private func restoreTab(_ state: SessionTab, into pane: Pane, store: SessionStore) -> Tab? {
        let fileURL = state.filePath.map { URL(fileURLWithPath: $0) }
        var tab: Tab?

        if let bufferFile = state.bufferFile, let text = store.readBuffer(named: bufferFile) {
            // Hot-exit content wins over the file on disk: it's strictly newer.
            let restored = makeBlankTab(in: pane)
            let encoding = state.encodingRaw.flatMap(TextEncodingKind.init(rawValue:)) ?? .utf8
            let lineEnding = state.lineEndingRaw.flatMap(LineEnding.init(rawValue:)) ?? .lf
            restored.editor.restoreBuffer(text: text, url: fileURL,
                                          encoding: encoding, lineEnding: lineEnding)
            tab = restored
        } else if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            tab = try? makeTab(loadingURL: fileURL, in: pane)
        } else if state.filePath == nil {
            tab = makeBlankTab(in: pane) // untitled and clean: an empty tab is faithful
        }
        guard let tab else { return nil }

        if let scope = state.syntaxScope,
           let grammar = MainWindowController.sharedRegistry.grammar(forScope: scope) {
            tab.editor.setGrammar(grammar, isManualChoice: true)
            // Restoring a hand-picked syntax happens after `addTab` applied settings for
            // whatever syntax was auto-detected, so the syntax layer has to be re-resolved.
            applySettings(to: tab)
        }
        let caret = tab.editor.document.clamp(Position(line: state.caretLine,
                                                       column: state.caretColumn))
        tab.editor.didMoveSelection(Selection(caret: caret), scroll: false)
        tab.scrollView.contentView.scroll(to: NSPoint(x: state.scrollX, y: state.scrollY))
        tab.scrollView.reflectScrolledClipView(tab.scrollView.contentView)
        return tab
    }

    // MARK: - File actions (reached via the responder chain from the main menu)

    @objc public func openDocument(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.open(url: url)
        }
    }

    /// Opens into a new tab, unless the active tab is a blank, never-saved, unmodified
    /// document — then it loads in place, matching Sublime's own "Open File" behaviour
    /// so a fresh window doesn't collect a stray empty tab next to the file you opened.
    public func open(url: URL) {
        do {
            let current = activeTab.editor.document
            if current.fileURL == nil, !current.isDirty {
                try activeTab.editor.loadFile(url)
                // Loading re-runs syntax detection, so the syntax layer may have changed
                // under a tab that already had settings applied when it was created.
                applySettings(to: activeTab)
                window?.isDocumentEdited = false
                refreshChrome()
                refreshTabBar()
            } else {
                activate(try makeTab(loadingURL: url, in: focusedPane))
            }
        } catch {
            showError(error)
        }
    }

    @objc public func saveDocument(_ sender: Any?) {
        if textDocument.fileURL != nil {
            write(to: nil)
        } else {
            saveDocumentAs(sender)
        }
    }

    @objc public func saveDocumentAs(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = textDocument.fileURL?.lastPathComponent ?? "untitled.txt"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.write(to: url)
        }
    }

    private func write(to url: URL?) {
        do {
            try textDocument.save(to: url)
            window?.isDocumentEdited = false
            refreshChrome()
            refreshTabBar()
        } catch {
            showError(error)
        }
    }

    // Named showError to avoid clashing with NSResponder.presentError(_:).
    private func showError(_ error: Error) {
        guard let window else { return }
        NSAlert(error: error).beginSheetModal(for: window)
    }

    // MARK: - Find bar

    /// Mounts the shared find bar into `pane`'s slot, moving it out of whichever pane
    /// previously held it. A no-op when it is already there, so repeated ⌘F doesn't churn
    /// the view tree.
    private func mountFindBar(in pane: Pane) {
        guard findBarPane !== pane else { return }
        NSLayoutConstraint.deactivate(findBarEdgeConstraints)
        findBarEdgeConstraints.removeAll()
        findBarPane?.findBarHeight.constant = 0
        findBar.removeFromSuperview()

        pane.findBarHost.addSubview(findBar)
        findBarEdgeConstraints = [
            findBar.topAnchor.constraint(equalTo: pane.findBarHost.topAnchor),
            findBar.leadingAnchor.constraint(equalTo: pane.findBarHost.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: pane.findBarHost.trailingAnchor),
            findBar.bottomAnchor.constraint(equalTo: pane.findBarHost.bottomAnchor),
        ]
        NSLayoutConstraint.activate(findBarEdgeConstraints)
        findBarPane = pane
    }

    /// Keeps the find bar in the pane it is actually searching.
    ///
    /// Every `FindBarDelegate` method operates on `editor` — the *focused* pane's active
    /// editor — but the bar itself stays mounted wherever it was opened. Those two used to
    /// diverge the moment focus moved to the other pane, which put the bar over one
    /// document while it searched (and highlighted matches in) the other, with a match
    /// count belonging to neither. Moving the bar to follow focus keeps "what you see" and
    /// "what is being searched" the same pane, which is the only arrangement a single
    /// shared find bar can be coherent in.
    private func moveFindBarToFocusedPaneIfNeeded() {
        guard !findBar.isHidden, findBarPane !== focusedPane else { return }
        // Stop highlighting matches in the pane being left behind — they belong to a
        // search that is no longer on screen there. `clearSearchHighlights()`, *not*
        // `dismissFind()`: the latter restores first responder to its own editor, which
        // would snap focus straight back to the pane being left and undo the focus change
        // that got us here. (Found exactly that way — the smoke test caught the fix
        // fighting itself.)
        findBarPane?.activeTab?.editor.clearSearchHighlights()
        mountFindBar(in: focusedPane)
        findBarPane?.findBarHeight.constant = findBar.preferredHeight
        resizeEditorForFindBarChange()
    }

    /// Called when an editor takes first responder. Clicking directly into the other
    /// pane's text moves focus without going through `activate(_:)`, so `focusedPaneIndex`
    /// went stale — and everything reading `focusedPane` (the status line, the find bar's
    /// target editor, where ⌘F mounts) was then describing a pane the user had left.
    private func focusedPaneDidChange(to editorView: EditorView) {
        guard let index = panes.firstIndex(where: { pane in
            pane.tabs.contains { $0.editor === editorView }
        }), index != focusedPaneIndex else { return }
        focusedPaneIndex = index
        moveFindBarToFocusedPaneIfNeeded()
        if !findBar.isHidden { editor.applySearchQuery(findBar.query) }
        refreshChrome()
        refreshTabBar()
    }

    /// Opens the find bar **in the focused pane**. Callers that know which editor asked
    /// (see `onFindRequested` in `configureEditor`) sync `focusedPaneIndex` to that editor
    /// first, so this is correct by construction rather than by trusting focus tracking.
    private func showFindBar(withReplace: Bool) {
        mountFindBar(in: focusedPane)
        findBar.isHidden = false
        findBar.setReplaceVisible(withReplace)
        findBarPane?.findBarHeight.constant = findBar.preferredHeight
        resizeEditorForFindBarChange()
        findBar.focusFindField()
    }

    private func hideFindBar() {
        findBar.isHidden = true
        findBarPane?.findBarHeight.constant = 0
        resizeEditorForFindBarChange()
    }

    /// Showing/hiding the find bar resizes the editor's viewport by changing an Auto
    /// Layout constant, which only takes effect at the *next* layout pass. Left alone,
    /// the clip view resizes later without ever being told to repaint what is newly
    /// visible — `NSClipView` stopped copying/redrawing the revealed strip on resize as
    /// of macOS 11 (see `clipBoundsChanged`) — so the editor can sit stale until some
    /// unrelated redraw happens to touch it. Forcing the layout pass now and invalidating
    /// closes that gap.
    ///
    /// The forced synchronous `displayIfNeeded()` calls that used to be here (and in
    /// `showFindBar`/`hideFindBar`) are gone: they were added by an earlier round of the
    /// blank-pane investigation on a theory that round then disproved, they never fixed
    /// anything, and forcing a layer-backed view to display mid-resize, outside the normal
    /// CoreAnimation cycle, is itself a plausible way to strand a backing store. Scoped to
    /// the visible rect rather than the full bounds, which on a wide document can be
    /// thousands of points of off-screen area nobody is going to look at.
    private func resizeEditorForFindBarChange() {
        window?.contentView?.layoutSubtreeIfNeeded()
        editor.setNeedsDisplay(editor.visibleRect)
        focusedPane.tabBar.needsDisplay = true
    }

    // MARK: - Find commands forwarded from the responder chain
    //
    // While the find field has focus, the editor is on a sibling branch of the responder
    // chain, so nil-target menu items like Find Next would validate as disabled and do
    // nothing. The window controller *is* in the chain, so it forwards them.

    @objc public func performFind(_ sender: Any?) {
        showFindBar(withReplace: findBar.showsReplace)
    }

    @objc public func performFindAndReplace(_ sender: Any?) {
        showFindBar(withReplace: true)
    }

    @objc public func findNextMatch(_ sender: Any?) { editor.findNextMatch(sender) }
    @objc public func findPreviousMatch(_ sender: Any?) { editor.findPreviousMatch(sender) }
    @objc public func selectAllMatches(_ sender: Any?) { findBarFindAll(findBar) }

    @objc public func useSelectionForFind(_ sender: Any?) {
        editor.useSelectionForFind(sender)
    }

    // MARK: - Project (T83)

    /// The project open in this window, if any — `nil` until "Open Folder…" or "Switch
    /// Project…" is used, matching Sublime's own per-window project model (each
    /// `MainWindowController` is one window, so this is naturally per-window too, the
    /// same scoping `fileIndex`/`symbolIndex` already have). Not persisted across
    /// relaunches — that's session restore's job (T84), out of scope here.
    private var currentProject: Project?

    @objc public func openFolder(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.setProject(.adHoc(folder: url))
        }
    }

    @objc public func switchProject(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // Filtered via the delegate rather than `allowedContentTypes`/`allowedFileTypes`:
        // no UTType is registered for `.sublime-project`, matching how
        // `SyntaxMenuController`'s import panel already handles its own
        // no-registered-UTType extensions.
        panel.delegate = self
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.loadProject(from: url)
        }
    }

    private func loadProject(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let project = try ProjectParser.parse(data: data, projectFileURL: url)
            setProject(project)
        } catch {
            showError(error)
        }
    }

    /// Falls back to the tab-derived approximation `fileIndex`'s roots always used
    /// before this existed — closing a project shouldn't make Goto Anything stop
    /// working, just make it less scoped.
    @objc public func closeProject(_ sender: Any?) {
        setProject(nil)
    }

    private func setProject(_ project: Project?) {
        currentProject = project
        sidebar.setFolders(project?.folders ?? [])
        sidebar.isHidden = (project?.folders.isEmpty ?? true)
        sidebarSplitView.adjustSubviews()
        // The project layer just moved (T86) — including on close, where dropping the
        // project must also drop whatever it was overriding.
        applySettingsToAllTabs()
        refreshChrome()
    }

    /// Only ever called with the *current* project already known non-nil (see
    /// `refreshChrome`'s `currentProject.map { ... }`) — takes `Project` rather than
    /// `Project?` so that's enforced at the call site instead of handled here.
    private func projectDisplayName(_ project: Project) -> String {
        if let fileURL = project.fileURL { return fileURL.deletingPathExtension().lastPathComponent }
        return project.folders.first?.displayName ?? "m_text"
    }

    /// Scan roots for `fileIndex`/`symbolIndex`: the open project's folders when there
    /// is one, otherwise every currently open tab's containing folder — the
    /// approximation Goto Anything/Goto Symbol used everywhere before a project model
    /// existed, and still the right fallback with no project open.
    private func fileIndexRoots() -> [URL] {
        if let currentProject, !currentProject.folders.isEmpty {
            return currentProject.folders.map { $0.url }
        }
        // Every tab in every pane — Goto Anything shouldn't only see whichever pane
        // happens to have focus.
        return Array(Set(allTabs.compactMap { $0.editor.document.fileURL?.deletingLastPathComponent() }))
    }

    /// Applies the open project's exclude names (on top of `FileIndex`'s own defaults)
    /// and hands `fileIndex` its roots — the two pieces of "scan scope" a project can
    /// influence, kept together so no call site can update one and forget the other.
    private func applyFileIndexScanScope(roots: [URL]) {
        fileIndex.excludedNames = FileIndex.defaultExcludedNames.union(currentProject?.allExcludedNames ?? [])
        fileIndex.setRoots(roots)
    }

    // MARK: - Goto Anything (T73)
    //
    // One palette, four modes selected by a prefix character (matching Sublime): a bare
    // query fuzzy-searches file paths from `fileIndex`; `:42` or `:42:10` jumps to a
    // line (and column) in the *current* file; `@name` fuzzy-searches symbols in the
    // current file (via `SymbolExtractor` — see T74 for a project-wide version);
    // `#text` fuzzy-searches the current file's lines. The first three modes preview
    // live as you arrow through results (they only move the caret in an already-open
    // document); file-search results are deliberately *not* live-previewed, since
    // opening another file's tab just to show a highlighted row would leave stray tabs
    // behind on cancel — only committing (Enter or a click) opens one.

    private lazy var overlayPalette = Palette()
    private let fileIndex = FileIndex()
    private var fileIndexEntries: [FileIndex.Entry] = []
    private var lastGotoAnythingQuery = ""

    /// Extracting symbols or collecting every line's text is a whole-file pass — worth
    /// doing once per Goto Anything session and re-ranking against the query on every
    /// keystroke, rather than redoing the pass itself each time. Reset when the palette
    /// opens, since the file may have changed since the last session.
    private var cachedSymbolsForCurrentFile: [SymbolExtractor.Symbol]?
    private var cachedDisplayLinesForCurrentFile: [String]?

    private enum GotoAnythingTarget {
        case position(Position)
        case file(URL)
        /// A symbol found somewhere in the project that isn't necessarily open yet —
        /// distinct from `.position`, which always targets the *current* editor.
        case symbolInFile(url: URL, line: Int, column: Int)
    }

    @objc public func showGotoAnything(_ sender: Any?) {
        guard let window else { return }

        cachedSymbolsForCurrentFile = nil
        cachedDisplayLinesForCurrentFile = nil

        fileIndex.onUpdate = { [weak self] entries in
            self?.fileIndexEntries = entries
            self?.refreshGotoAnythingIfShowingFiles()
        }
        applyFileIndexScanScope(roots: fileIndexRoots())

        recordJumpOrigin()

        overlayPalette.onQueryChanged = { [weak self] query in
            self?.updateGotoAnythingResults(query: query)
        }
        overlayPalette.onHighlightChanged = { [weak self] item in
            self?.previewGotoAnything(item)
        }
        overlayPalette.onCommit = { [weak self] item in
            self?.commitGotoAnythingTarget(item)
        }
        overlayPalette.onCancel = { [weak self] in
            self?.cancelGotoAnything()
        }

        overlayPalette.show(over: window, placeholder: "Goto Anything — filename, :line, @symbol, #text")
        updateGotoAnythingResults(query: "")
    }

    private func updateGotoAnythingResults(query: String) {
        lastGotoAnythingQuery = query
        if query.hasPrefix(":") {
            showLineResults(String(query.dropFirst()))
        } else if query.hasPrefix("@") {
            showSymbolResults(String(query.dropFirst()))
        } else if query.hasPrefix("#") {
            showTextResults(String(query.dropFirst()))
        } else {
            showFileResults(query)
        }
    }

    /// The file index can finish an (async) walk after the user has already moved on to
    /// a `:`/`@`/`#` mode — only re-render if a bare file query is still what's showing.
    private func refreshGotoAnythingIfShowingFiles() {
        guard !lastGotoAnythingQuery.hasPrefix(":"),
              !lastGotoAnythingQuery.hasPrefix("@"),
              !lastGotoAnythingQuery.hasPrefix("#")
        else { return }
        showFileResults(lastGotoAnythingQuery)
    }

    private func showLineResults(_ remainder: String) {
        let parts = remainder.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first, let lineNumber = Int(first), lineNumber > 0 else {
            overlayPalette.setItems([])
            return
        }
        let targetLine = lineNumber - 1
        guard targetLine < textDocument.lineCount else {
            overlayPalette.setItems([])
            return
        }
        let column = parts.count > 1 ? (Int(parts[1]) ?? 1) : 1
        let targetColumn = max(0, column - 1)
        let preview = textDocument.line(targetLine).trimmingCharacters(in: .whitespaces)

        let item = PaletteItem(title: "Line \(lineNumber)",
                               subtitle: preview.isEmpty ? nil : preview,
                               payload: GotoAnythingTarget.position(Position(line: targetLine, column: targetColumn)))
        overlayPalette.setItems([item])
    }

    private func showSymbolResults(_ query: String) {
        let symbols: [SymbolExtractor.Symbol]
        if let cached = cachedSymbolsForCurrentFile {
            symbols = cached
        } else {
            symbols = SymbolExtractor.extractSymbols(from: textDocument, grammar: editor.highlightService.grammar)
            cachedSymbolsForCurrentFile = symbols
        }

        let names = symbols.map { $0.name }
        let ranked: [(index: Int, match: FuzzyMatcher.Match)] = query.isEmpty
            ? names.indices.map { ($0, FuzzyMatcher.Match(score: 0, indices: [])) }
            : FuzzyMatcher.rank(query: query, candidates: names)

        let items = ranked.prefix(200).map { entry -> PaletteItem in
            let symbol = symbols[entry.index]
            return PaletteItem(title: symbol.name,
                               subtitle: "Line \(symbol.line + 1)",
                               matchedIndices: entry.match.indices,
                               payload: GotoAnythingTarget.position(Position(line: symbol.line, column: symbol.column)))
        }
        overlayPalette.setItems(Array(items))
    }

    private func showTextResults(_ query: String) {
        guard !query.isEmpty else {
            overlayPalette.setItems([])
            return
        }

        let displayLines: [String]
        if let cached = cachedDisplayLinesForCurrentFile {
            displayLines = cached
        } else {
            // Capped so a pathologically large file can't turn every keystroke into a
            // full-file scan; the vast majority of real files never hit this limit.
            let scanLimit = min(textDocument.lineCount, 50_000)
            var lines: [String] = []
            lines.reserveCapacity(scanLimit)
            for i in 0 ..< scanLimit {
                lines.append(textDocument.line(i).trimmingCharacters(in: .whitespaces))
            }
            displayLines = lines
            cachedDisplayLinesForCurrentFile = lines
        }

        let ranked = FuzzyMatcher.rank(query: query, candidates: displayLines)
        let items = ranked.prefix(200).map { entry -> PaletteItem in
            PaletteItem(title: displayLines[entry.index],
                       subtitle: "Line \(entry.index + 1)",
                       matchedIndices: entry.match.indices,
                       payload: GotoAnythingTarget.position(Position(line: entry.index, column: 0)))
        }
        overlayPalette.setItems(Array(items))
    }

    private func showFileResults(_ query: String) {
        let candidates = fileIndexEntries.map { $0.displayPath }
        let ranked: [(index: Int, match: FuzzyMatcher.Match)] = query.isEmpty
            ? candidates.indices.map { ($0, FuzzyMatcher.Match(score: 0, indices: [])) }
            : FuzzyMatcher.rank(query: query, candidates: candidates)

        let items = ranked.prefix(200).map { entry -> PaletteItem in
            let fileEntry = fileIndexEntries[entry.index]
            return PaletteItem(title: fileEntry.displayPath,
                               matchedIndices: entry.match.indices,
                               payload: GotoAnythingTarget.file(fileEntry.url))
        }
        // The index can refresh mid-session (a file changed on disk); don't yank the
        // selection out from under someone who's already arrowed down to a result.
        overlayPalette.setItems(Array(items), preserveSelection: true)
    }

    private func previewGotoAnything(_ item: PaletteItem) {
        guard let target = item.payload as? GotoAnythingTarget else { return }
        if case .position(let position) = target {
            editor.didMoveSelection(Selection(caret: textDocument.clamp(position)), scroll: true)
        }
    }

    /// Shared commit handler for every palette session that produces a
    /// `GotoAnythingTarget` payload — Goto Anything itself (T73), Goto Symbol in
    /// Project, and the Goto Definition disambiguation palette (both T74).
    private func commitGotoAnythingTarget(_ item: PaletteItem) {
        guard let target = item.payload as? GotoAnythingTarget else { return }
        switch target {
        case .position(let position):
            editor.didMoveSelection(Selection(caret: textDocument.clamp(position)), scroll: true)
        case .file(let url):
            open(url: url)
        case .symbolInFile(let url, let line, let column):
            openAndJump(to: url, line: line, column: column)
        }
        // A fresh, deliberate jump was just committed — any old "forward" history from
        // before this jump no longer leads anywhere coherent, same as a browser
        // discarding forward history after you follow a new link.
        jumpForwardStack.removeAll()
    }

    /// Opens `url` (reusing an existing tab if it's already open, via `open(url:)`'s own
    /// logic) and moves the caret to a specific position in it — `open(url:)` runs
    /// synchronously, so `editor` already refers to the newly active tab by the time
    /// the position is applied.
    private func openAndJump(to url: URL, line: Int, column: Int) {
        open(url: url)
        editor.didMoveSelection(Selection(caret: textDocument.clamp(Position(line: line, column: column))), scroll: true)
    }

    /// Escape: undo whatever `previewGotoAnything` moved the caret to while browsing,
    /// by popping the very entry `recordJumpOrigin` pushed when the palette opened —
    /// nothing was actually committed, so it shouldn't linger as a stray "back" target
    /// that would just return you to where you already are.
    private func cancelGotoAnything() {
        guard let origin = jumpBackStack.popLast() else { return }
        if origin.tab === activeTab {
            origin.tab.editor.didMoveSelection(origin.selection, scroll: true)
        }
    }

    // MARK: - Project symbol index + Goto Definition (T74)
    //
    // `symbolIndex` is only ever (re-)built on demand — once per Goto Symbol/Goto
    // Definition session, not automatically on every file change the way `fileIndex`'s
    // live watchers work. Re-tokenizing every file in a project on every save would be
    // its own performance problem; this trades a little staleness for that. Whatever
    // was indexed last session shows immediately (instant-feeling repeat use) while a
    // fresh background pass quietly replaces it once ready.

    private let symbolIndex = SymbolIndex()
    private var symbolIndexEntries: [SymbolIndex.Entry] = []
    private var lastProjectSymbolQuery = ""

    @objc public func showGotoSymbolInProject(_ sender: Any?) {
        guard let window else { return }

        recordJumpOrigin()
        lastProjectSymbolQuery = ""

        overlayPalette.onQueryChanged = { [weak self] query in
            self?.lastProjectSymbolQuery = query
            self?.updateProjectSymbolResults(query: query)
        }
        overlayPalette.onHighlightChanged = { [weak self] item in
            self?.previewGotoAnything(item)
        }
        overlayPalette.onCommit = { [weak self] item in
            self?.commitGotoAnythingTarget(item)
        }
        overlayPalette.onCancel = { [weak self] in
            self?.cancelGotoAnything()
        }

        overlayPalette.show(over: window, placeholder: "Goto Symbol in Project")
        updateProjectSymbolResults(query: "")
        refreshProjectSymbolIndex()
    }

    private func refreshProjectSymbolIndex() {
        fileIndex.onUpdate = { [weak self] entries in
            guard let self else { return }
            self.fileIndexEntries = entries
            self.symbolIndex.index(files: entries, registry: MainWindowController.sharedRegistry)
        }
        symbolIndex.onUpdate = { [weak self] entries in
            guard let self else { return }
            self.symbolIndexEntries = entries
            self.updateProjectSymbolResults(query: self.lastProjectSymbolQuery)
        }
        applyFileIndexScanScope(roots: fileIndexRoots())
    }

    private func updateProjectSymbolResults(query: String) {
        let names = symbolIndexEntries.map { $0.symbol.name }
        let ranked: [(index: Int, match: FuzzyMatcher.Match)] = query.isEmpty
            ? names.indices.map { ($0, FuzzyMatcher.Match(score: 0, indices: [])) }
            : FuzzyMatcher.rank(query: query, candidates: names)

        let items = ranked.prefix(200).map { entry -> PaletteItem in
            let match = symbolIndexEntries[entry.index]
            return PaletteItem(title: match.symbol.name,
                               subtitle: "\(match.displayPath):\(match.symbol.line + 1)",
                               matchedIndices: entry.match.indices,
                               payload: GotoAnythingTarget.symbolInFile(url: match.url,
                                                                        line: match.symbol.line,
                                                                        column: match.symbol.column))
        }
        // The index can (re-)finish in the background mid-session; don't yank the
        // selection out from under someone who's already arrowed to a candidate.
        overlayPalette.setItems(items, preserveSelection: true)
    }

    /// F12: jumps straight to a symbol's definition if there's exactly one match
    /// anywhere in the project; shows a disambiguation palette if there's more than
    /// one; does nothing if there's a caret under an identifier but no index yet — a
    /// first press kicks off an index and retries automatically once it lands, so a
    /// second press isn't needed in the common case.
    @objc public func gotoDefinition(_ sender: Any?) {
        guard let identifier = identifierUnderCaret(), !identifier.isEmpty else { return }

        // Snapshotted here, synchronously, at press time — not re-read inside
        // `jumpToDefinition`, which in the deferred (no-index-yet) branch below can run
        // seconds later, by which point the caret/active tab may no longer be where the
        // user pressed F12. Only actually pushed onto jump history once a match is
        // confirmed (inside `jumpToDefinition`), so a miss doesn't leave a dead entry
        // behind for ⌃- to land on.
        // Explicitly typed: `activeTab` is `Tab!` (implicitly-unwrapped), which only
        // auto-unwraps to plain `Tab` when the surrounding context demands it — an
        // untyped tuple literal like `(activeTab, ...)` would otherwise infer `Tab?`
        // here and fail to match `jumpToDefinition`'s `(tab: Tab, ...)` parameter.
        let origin: (tab: Tab, selection: Selection) = (activeTab, editor.selection)

        guard !symbolIndexEntries.isEmpty else {
            let roots = fileIndexRoots()
            guard !roots.isEmpty else { return }
            fileIndex.onUpdate = { [weak self] entries in
                guard let self else { return }
                self.fileIndexEntries = entries
                self.symbolIndex.index(files: entries, registry: MainWindowController.sharedRegistry)
            }
            symbolIndex.onUpdate = { [weak self] entries in
                guard let self else { return }
                self.symbolIndexEntries = entries
                self.jumpToDefinition(of: identifier, origin: origin)
            }
            applyFileIndexScanScope(roots: roots)
            return
        }

        jumpToDefinition(of: identifier, origin: origin)
    }

    /// The run of identifier characters (letters, digits, `_`) touching the caret —
    /// checking one character back too, since a caret that landed at the *end* of a
    /// word (e.g. after double-clicking to select it, which collapses to the tail)
    /// would otherwise see only whatever comes next.
    private func identifierUnderCaret() -> String? {
        guard !editor.selection.isMultiple else { return nil }
        let position = editor.selection.primary.head
        let characters = Array(textDocument.line(position.line))
        guard !characters.isEmpty else { return nil }

        func isIdentifierCharacter(_ character: Character) -> Bool {
            character.isLetter || character.isNumber || character == "_"
        }

        var start = position.column
        if start >= characters.count || !isIdentifierCharacter(characters[start]) {
            start = position.column - 1
        }
        guard start >= 0, start < characters.count, isIdentifierCharacter(characters[start]) else { return nil }

        var begin = start
        while begin > 0, isIdentifierCharacter(characters[begin - 1]) { begin -= 1 }
        var end = start
        while end < characters.count - 1, isIdentifierCharacter(characters[end + 1]) { end += 1 }

        return String(characters[begin ... end])
    }

    private func jumpToDefinition(of identifier: String, origin: (tab: Tab, selection: Selection)) {
        let matches = symbolIndexEntries.filter { $0.symbol.name == identifier }
        guard !matches.isEmpty else { return }

        // Pushed from the snapshot captured at F12-press time (see `gotoDefinition`),
        // not from current live state, which may have moved on by the time this runs.
        if !isNavigatingJumpHistory {
            jumpBackStack.append(origin)
            if jumpBackStack.count > 200 { jumpBackStack.removeFirst() }
        }

        if matches.count == 1, let only = matches.first {
            openAndJump(to: only.url, line: only.symbol.line, column: only.symbol.column)
            jumpForwardStack.removeAll()
        } else {
            showDefinitionDisambiguationPalette(for: matches)
        }
    }

    private func showDefinitionDisambiguationPalette(for matches: [SymbolIndex.Entry]) {
        guard let window else { return }
        let items = matches.map { match -> PaletteItem in
            PaletteItem(title: match.symbol.name,
                       subtitle: "\(match.displayPath):\(match.symbol.line + 1)",
                       payload: GotoAnythingTarget.symbolInFile(url: match.url,
                                                                line: match.symbol.line,
                                                                column: match.symbol.column))
        }
        overlayPalette.onQueryChanged = nil
        overlayPalette.onHighlightChanged = { [weak self] item in
            self?.previewGotoAnything(item)
        }
        overlayPalette.onCommit = { [weak self] item in
            self?.commitGotoAnythingTarget(item)
        }
        overlayPalette.onCancel = { [weak self] in
            self?.cancelGotoAnything()
        }
        overlayPalette.show(over: window, placeholder: "Multiple definitions — pick one")
        overlayPalette.setItems(items)
    }

    // MARK: - Command Palette (T75)

    private static let recentCommandsDefaultsKey = "io.mesoneer.mtext.recentCommands"
    private static let maximumRecentCommands = 20

    /// ⌘⇧P: every command dispatchable from the app's own menu tree (see
    /// `CommandRegistry`), fuzzy-searchable, most-recently-used first. Doesn't move the
    /// caret or touch `jumpBackStack` — nothing here previews, so there's nothing for a
    /// cancel to undo.
    @objc public func showCommandPalette(_ sender: Any?) {
        guard let window, let mainMenu = NSApplication.shared.mainMenu else { return }

        let commands = CommandRegistry.commands(from: mainMenu)
        let recent = UserDefaults.standard.stringArray(forKey: MainWindowController.recentCommandsDefaultsKey) ?? []
        let ordered = MainWindowController.order(commands, byRecent: recent)

        func items(for query: String) -> [PaletteItem] {
            if query.isEmpty {
                return ordered.map { command in
                    PaletteItem(title: command.title, subtitle: command.keyEquivalentDisplay,
                               matchedIndices: [], payload: command)
                }
            }
            let ranked = FuzzyMatcher.rank(query: query, candidates: ordered.map { $0.title })
            return ranked.map { entry in
                let command = ordered[entry.index]
                return PaletteItem(title: command.title, subtitle: command.keyEquivalentDisplay,
                                   matchedIndices: entry.match.indices, payload: command)
            }
        }

        overlayPalette.onQueryChanged = { [weak self] query in
            self?.overlayPalette.setItems(items(for: query))
        }
        overlayPalette.onHighlightChanged = nil
        overlayPalette.onCommit = { [weak self] item in
            guard let self, let command = item.payload as? PaletteCommand,
                  let action = command.menuItem.action
            else { return }
            self.rememberRecentCommand(command.title)
            // Dispatched through the original menu item (its real target and, for items
            // like Syntax's `setSyntaxFromMenu(_:)`, its `representedObject`) rather than
            // a bare selector from `self` — see `PaletteCommand`'s doc comment for why.
            NSApp.sendAction(action, to: command.menuItem.target, from: command.menuItem)
        }
        overlayPalette.onCancel = nil
        overlayPalette.show(over: window, placeholder: "Command Palette")
        overlayPalette.setItems(items(for: ""))
    }

    /// Recently-used commands (most recent first) sort ahead of the rest, which keep the
    /// registry's original menu order; duplicate titles collapse to whichever menu item
    /// was found last (there are none in practice — menu titles are already unique once
    /// nested ones are prefixed by `CommandRegistry`).
    private static func order(_ commands: [PaletteCommand], byRecent recent: [String]) -> [PaletteCommand] {
        var byTitle: [String: PaletteCommand] = [:]
        for command in commands { byTitle[command.title] = command }

        var seen = Set<String>()
        var ordered: [PaletteCommand] = []
        for title in recent {
            guard let command = byTitle[title], !seen.contains(title) else { continue }
            ordered.append(command)
            seen.insert(title)
        }
        for command in commands where !seen.contains(command.title) {
            ordered.append(command)
            seen.insert(command.title)
        }
        return ordered
    }

    private func rememberRecentCommand(_ title: String) {
        var recent = UserDefaults.standard.stringArray(forKey: MainWindowController.recentCommandsDefaultsKey) ?? []
        recent.removeAll { $0 == title }
        recent.insert(title, at: 0)
        if recent.count > MainWindowController.maximumRecentCommands {
            recent.removeLast(recent.count - MainWindowController.maximumRecentCommands)
        }
        UserDefaults.standard.set(recent, forKey: MainWindowController.recentCommandsDefaultsKey)
    }

    // MARK: - Keymap (T76)

    /// Parsed once per process and shared by every tab's `KeymapEngine` — the built-in
    /// defaults are a compiled-in string literal and the user file doesn't change while
    /// the app is running, matching this app's existing "no live config reload" posture
    /// elsewhere (e.g. color schemes, grammars). A person editing their keymap file
    /// needs to relaunch to pick up changes.
    private static let keymapEntries: (user: [KeymapEntry], defaults: [KeymapEntry]) = {
        let defaults = (try? KeymapParser.parse(data: Data(DefaultKeymap.json.utf8))) ?? []
        return (userKeymapEntries(), defaults)
    }()

    /// `~/Library/Application Support/m_text/User/Default.sublime-keymap` — same
    /// `User/` folder name Sublime itself uses, so a person migrating settings over
    /// mostly just has to drop their existing file in.
    private static func userKeymapEntries() -> [KeymapEntry] {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                        in: .userDomainMask).first
        else { return [] }
        let url = appSupport.appendingPathComponent("m_text/User/Default.sublime-keymap")
        guard let data = try? Data(contentsOf: url) else { return [] }
        // A missing file is normal (most people never create one); a malformed one is
        // skipped entirely rather than crashing the app or partially applying —  either
        // it parses cleanly or the built-in defaults are used until it's fixed.
        return (try? KeymapParser.parse(data: data)) ?? []
    }

    private func dispatchKeymapCommand(_ name: String, args: [String: Any]?) {
        guard let selector = KeymapCommands.selector(forCommand: name, args: args) else { return }
        NSApp.sendAction(selector, to: nil, from: self)
    }

    // MARK: - Jump history (T77)

    private var jumpBackStack: [(tab: Tab, selection: Selection)] = []
    private var jumpForwardStack: [(tab: Tab, selection: Selection)] = []
    /// Stops `recordJumpOrigin` from treating a `jumpToPrevious/NextLocation`-driven
    /// caret move as itself a new origin to record.
    private var isNavigatingJumpHistory = false

    /// Call before any deliberate "go somewhere else" navigation that should be
    /// undoable with ⌃- (Goto Anything; later, Goto Definition) — not for incidental
    /// caret moves like typing or arrow keys.
    private func recordJumpOrigin() {
        guard !isNavigatingJumpHistory else { return }
        jumpBackStack.append((activeTab, editor.selection))
        if jumpBackStack.count > 200 { jumpBackStack.removeFirst() }
    }

    @objc public func jumpToPreviousLocation(_ sender: Any?) {
        guard let previous = jumpBackStack.popLast() else { return }
        // Checked against every pane's tabs, not just the focused one — the target
        // tab may well live in the *other* pane, which doesn't mean it's closed.
        guard allTabs.contains(where: { $0 === previous.tab }) else {
            // That tab closed since this entry was recorded — skip it rather than
            // getting stuck on a dead entry forever.
            jumpToPreviousLocation(sender)
            return
        }
        jumpForwardStack.append((activeTab, editor.selection))
        isNavigatingJumpHistory = true
        if previous.tab !== activeTab { activate(previous.tab) }
        previous.tab.editor.didMoveSelection(previous.selection, scroll: true)
        isNavigatingJumpHistory = false
    }

    @objc public func jumpToNextLocation(_ sender: Any?) {
        guard let next = jumpForwardStack.popLast() else { return }
        guard allTabs.contains(where: { $0 === next.tab }) else {
            jumpToNextLocation(sender)
            return
        }
        jumpBackStack.append((activeTab, editor.selection))
        isNavigatingJumpHistory = true
        if next.tab !== activeTab { activate(next.tab) }
        next.tab.editor.didMoveSelection(next.selection, scroll: true)
        isNavigatingJumpHistory = false
    }
}

// MARK: - FindBarDelegate

extension MainWindowController: FindBarDelegate {

    public func findBar(_ bar: FindBar, queryChanged query: SearchQuery) {
        editor.applySearchQuery(query)
    }

    public func findBarFindNext(_ bar: FindBar) {
        editor.findNextMatch(nil)
    }

    public func findBarFindPrevious(_ bar: FindBar) {
        editor.findPreviousMatch(nil)
    }

    public func findBarFindAll(_ bar: FindBar) {
        editor.selectAllMatches(nil)
        // Multi-cursor editing belongs in the editor, so hand focus back.
        hideFindBar()
        window?.makeFirstResponder(editor)
    }

    public func findBar(_ bar: FindBar, replaceCurrentWith template: String) {
        editor.replaceCurrentMatch(with: template)
    }

    public func findBar(_ bar: FindBar, replaceAllWith template: String) {
        editor.replaceAllMatches(with: template)
    }

    public func findBarDismissed(_ bar: FindBar) {
        editor.dismissFind()
        hideFindBar()
    }
}

// MARK: - TabBarDelegate

extension MainWindowController: TabBarDelegate {

    /// Every delegate method starts by mapping the specific `TabBar` instance that
    /// fired it back to its owning `Pane` — with two panes possibly on screen at once,
    /// `bar` is not necessarily `focusedPane.tabBar` (clicking a tab, or a tab's close
    /// button, or "+", in the *other* pane's tab bar is exactly how that pane becomes
    /// focused in the first place).
    private func pane(for bar: TabBar) -> Pane? {
        panes.first { $0.tabBar === bar }
    }

    public func tabBar(_ bar: TabBar, didSelectTabAt index: Int) {
        guard let pane = pane(for: bar), pane.tabs.indices.contains(index) else { return }
        activate(pane.tabs[index])
    }

    public func tabBar(_ bar: TabBar, didCloseTabAt index: Int) {
        guard let pane = pane(for: bar), pane.tabs.indices.contains(index) else { return }
        closeTab(pane.tabs[index])
    }

    public func tabBar(_ bar: TabBar, didMoveTabAt index: Int, to newIndex: Int) {
        // `TabBar` only ever moves one adjacent step per call, and does the matching
        // swap in its own `items` array itself — mirroring that exactly (a swap, not a
        // remove/insert) is what keeps the two arrays in the same order.
        guard let pane = pane(for: bar), pane.tabs.indices.contains(index), pane.tabs.indices.contains(newIndex)
        else { return }
        pane.moveTab(from: index, to: newIndex)
    }

    public func tabBarDidRequestNewTab(_ bar: TabBar) {
        guard let pane = pane(for: bar) else { return }
        activate(makeBlankTab(in: pane))
    }
}

// MARK: - NSWindowDelegate

extension MainWindowController: NSWindowDelegate {

    /// The standard `isDocumentEdited`-driven close prompt only ever reflects the
    /// active tab, so it would silently discard a dirty *background* tab when the
    /// window closes. This checks every tab instead. It intentionally does not offer a
    /// per-file save here (unlike closing a single tab, which does) — reviewing several
    /// unsaved files one at a time on the way out is more machinery than a window close
    /// warrants; declining still leaves every tab open and nothing lost.
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        let dirtyCount = allTabs.filter(\.isDirty).count
        guard dirtyCount > 0 else { return true }

        let alert = NSAlert()
        alert.messageText = dirtyCount == 1
            ? "This window has one tab with unsaved changes."
            : "This window has \(dirtyCount) tabs with unsaved changes."
        alert.informativeText = "Closing now will lose those changes."
        alert.addButton(withTitle: "Close Without Saving")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.window?.close()
            }
        }
        return false
    }
}

extension MainWindowController: NSOpenSavePanelDelegate {

    /// Enables the extensions this app opens through a picker — `.sublime-project` for
    /// `switchProject` and `.sublime-macro` for `openMacro` (T94) — see the comment at
    /// `switchProject` for why this is delegate-based rather than
    /// `allowedContentTypes`/`allowedFileTypes`. Directories must stay enabled regardless of
    /// extension (matching `SyntaxMenuController`'s own import panel) — otherwise
    /// `shouldEnable` returning false for every folder would also block navigating *into*
    /// them to find a nested file.
    ///
    /// One list for both panels rather than a mode flag: the two extensions don't overlap,
    /// so the worst case is a macro file appearing selectable in the project picker, which
    /// then fails to parse as a project and reports it.
    public func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        if values?.isDirectory == true { return true }
        return ["sublime-project", "sublime-macro"].contains(url.pathExtension.lowercased())
    }
}

extension MainWindowController: NSSplitViewDelegate {

    /// One delegate serves both split views (`sidebarSplitView` and `paneSplitView`,
    /// disambiguated by `splitView` itself) — keeps either from being dragged down to
    /// nothing, which for `paneSplitView` would otherwise leave a pane with no visible
    /// width but no way to tell it's still there.
    public func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                          ofSubviewAt dividerIndex: Int) -> CGFloat {
        proposedMinimumPosition + (splitView === sidebarSplitView ? 160 : 200)
    }

    /// The sidebar is capped so it can't eat the window. `paneSplitView` needs the mirror
    /// image of its own minimum: without subtracting a minimum width for the *trailing*
    /// pane, the divider could be dragged flush to the right edge, leaving a focused pane
    /// with zero width and no way to see it — the same broken state `splitViewRight` used
    /// to create outright.
    public func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                          ofSubviewAt dividerIndex: Int) -> CGFloat {
        if splitView === sidebarSplitView { return min(proposedMaximumPosition, 400) }
        return max(0, proposedMaximumPosition - 200)
    }
}
