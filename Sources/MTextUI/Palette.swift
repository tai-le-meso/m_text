import AppKit

/// One row in the overlay palette (T71): a title (optionally with fuzzy-matched
/// character positions to highlight), an optional secondary detail string, and an
/// opaque payload the palette's owner uses to know what was picked when `onCommit`
/// fires. `matchedIndices` are `Character` offsets into `title`, as produced by
/// `FuzzyMatcher.Match.indices`.
public struct PaletteItem {
    public let title: String
    public let subtitle: String?
    public let matchedIndices: [Int]
    public let payload: Any?

    public init(title: String, subtitle: String? = nil, matchedIndices: [Int] = [], payload: Any? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.matchedIndices = matchedIndices
        self.payload = payload
    }
}

/// A floating, borderless "Goto Anything" / Command Palette overlay: a search field
/// over a filtered, fuzzy-ranked list. Shared by both features (T73, T75) — the palette
/// itself holds no notion of files, symbols, or commands; it just shows whatever
/// `PaletteItem`s its owner hands it and reports query changes, highlight changes (for
/// preview-on-highlight), commits, and cancellation.
///
/// Modelled on `FindBar`'s delegate/notify idiom, but this is a floating panel rather
/// than docked chrome, since Sublime's palette overlays the whole window rather than
/// occupying permanent layout space — there is no existing borderless-panel precedent
/// in this codebase, so this is the first one.
/// The palette's window.
///
/// **A borderless window cannot become key unless it says so.** `NSWindow.canBecomeKey`
/// returns false for anything without a title bar, and that is inherited unchanged by a
/// borderless `NSPanel`. The panel then shows, positions and draws perfectly — its search
/// field even reports focus, because `makeFirstResponder` succeeds within a non-key window —
/// while every keystroke goes somewhere else entirely. The palette opens and simply refuses
/// to search.
///
/// This is the entire fix, and it is why the smoke test asserts `canBecomeKey` rather than
/// only "the palette appeared".
final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    /// Key, but never *main*: the document window behind it stays the main window, so its
    /// title bar keeps its active appearance while the palette is up.
    override var canBecomeMain: Bool { false }
}

public final class Palette: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {

    /// Called on every keystroke in the search field. The owner is expected to respond
    /// synchronously with `setItems(_:)` — there is no async plumbing here, matching
    /// how `SearchSession` and `FuzzyMatcher` are both fast enough to run on every
    /// keystroke on the main thread.
    public var onQueryChanged: ((String) -> Void)?
    /// Called when the highlighted (not yet committed) row changes, via arrow keys or
    /// mouse hover — lets the owner preview a location without fully committing to it.
    public var onHighlightChanged: ((PaletteItem) -> Void)?
    /// Called on Enter, or a single click on a row.
    public var onCommit: ((PaletteItem) -> Void)?
    /// Called on Escape, or when the panel loses key status (click-away dismiss).
    public var onCancel: (() -> Void)?

    private let panel: NSPanel
    private let searchField: NSTextField
    private let tableView: NSTableView
    private let scrollView: NSScrollView
    private let emptyLabel: NSTextField

    private var items: [PaletteItem] = []

    // MARK: - Smoke-test hooks

    /// What the palette's field currently holds, how many rows it is offering, and whether
    /// its panel can actually take keyboard focus. A palette that shows but cannot become
    /// key swallows every keystroke — see `MTEXT_SMOKE_TEST`.
    public var smokeTestQuery: String { searchField.stringValue }
    public var smokeTestItemCount: Int { items.count }
    public var smokeTestPanelCanBecomeKey: Bool { panel.canBecomeKey }
    public var smokeTestPanelIsKey: Bool { panel.isKeyWindow }
    public var smokeTestFieldHasFocus: Bool {
        guard let responder = panel.firstResponder else { return false }
        // A focused NSTextField is edited by the window's shared field editor, whose delegate
        // is the field itself — the responder is never the NSTextField object.
        if responder === searchField { return true }
        return (responder as? NSTextView)?.delegate === searchField
    }
    private var isShowing = false

    private static let rowHeight: CGFloat = 22
    private static let rowHeightWithSubtitle: CGFloat = 36
    private static let panelWidth: CGFloat = 560
    private static let maxVisibleRows = 9

    public override init() {
        let contentRect = NSRect(x: 0, y: 0, width: Palette.panelWidth, height: 60)
        panel = PalettePanel(contentRect: contentRect,
                             styleMask: [.borderless, .fullSizeContentView],
                             backing: .buffered,
                             defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = false

        searchField = NSTextField(frame: .zero)
        searchField.isBordered = false
        searchField.focusRingType = .none
        searchField.drawsBackground = false
        searchField.font = .systemFont(ofSize: 18)

        tableView = NSTableView(frame: .zero)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.width = Palette.panelWidth - 16
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.rowSizeStyle = .custom
        tableView.style = .plain

        scrollView = NSScrollView(frame: .zero)
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        emptyLabel = NSTextField(labelWithString: "No results")
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true

        super.init()

        searchField.delegate = self
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(tableViewClicked)

        buildLayout()

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(panelDidResignKey),
                                               name: NSWindow.didResignKeyNotification,
                                               object: panel)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        // If the owner drops its last reference without calling `dismiss()` first, the
        // panel would otherwise stay in AppKit's window list — visible on screen with
        // nothing left to dismiss it.
        panel.close()
    }

    private func buildLayout() {
        guard let content = panel.contentView else { return }

        let background = NSVisualEffectView(frame: .zero)
        background.material = .sidebar
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true

        content.wantsLayer = true
        content.addSubview(background)
        content.addSubview(searchField)
        content.addSubview(scrollView)
        content.addSubview(emptyLabel)

        background.translatesAutoresizingMaskIntoConstraints = false
        searchField.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: content.topAnchor),
            background.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            background.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            searchField.heightAnchor.constraint(equalToConstant: 24),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),

            emptyLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 16),
        ])
    }

    // MARK: - Show / dismiss

    /// Shows the palette centred over the upper third of `window`, with `placeholder`
    /// in the search field and an initially empty query — the owner should call
    /// `setItems(_:)` right away with whatever an empty query should show (typically
    /// "everything, unranked", matching `FuzzyMatcher.match`'s empty-query behaviour).
    public func show(over window: NSWindow, placeholder: String) {
        searchField.stringValue = ""
        searchField.placeholderString = placeholder
        items = []
        tableView.reloadData()
        updateEmptyState()
        layoutHeight()

        let parentFrame = window.frame
        let x = parentFrame.midX - Palette.panelWidth / 2
        let y = parentFrame.maxY - parentFrame.height * 0.28
        panel.setFrameTopLeftPoint(NSPoint(x: x, y: y))

        isShowing = true
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
    }

    /// Idempotent — safe to call even if the palette isn't showing.
    public func dismiss() {
        guard isShowing else { return }
        isShowing = false
        panel.orderOut(nil)
    }

    @objc private func panelDidResignKey() {
        guard isShowing else { return }
        isShowing = false
        panel.orderOut(nil)
        onCancel?()
    }

    // MARK: - Items

    /// Replaces the visible list. `selectedIndex` resets to the top match unless
    /// `preserveSelection` is set and the previously-selected payload is still present.
    public func setItems(_ newItems: [PaletteItem], preserveSelection: Bool = false) {
        let previousPayload = preserveSelection ? selectedItem?.payload : nil
        items = newItems
        tableView.reloadData()
        updateEmptyState()
        layoutHeight()

        if newItems.isEmpty { return }
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        if preserveSelection, let previousPayload,
           let match = newItems.firstIndex(where: { samePayload($0.payload, previousPayload) }) {
            tableView.selectRowIndexes(IndexSet(integer: match), byExtendingSelection: false)
        }
        tableView.scrollRowToVisible(tableView.selectedRow)
        notifyHighlightChanged()
    }

    private func samePayload(_ a: Any?, _ b: Any?) -> Bool {
        guard let a = a as? AnyHashable, let b = b as? AnyHashable else { return false }
        return a == b
    }

    private var selectedItem: PaletteItem? {
        let row = tableView.selectedRow
        guard row >= 0, row < items.count else { return nil }
        return items[row]
    }

    private func updateEmptyState() {
        emptyLabel.isHidden = !items.isEmpty
        scrollView.isHidden = items.isEmpty
    }

    private func layoutHeight() {
        let rowsShown = min(max(items.count, items.isEmpty ? 2 : 1), Palette.maxVisibleRows)
        let hasSubtitles = items.contains { $0.subtitle != nil }
        let perRow = hasSubtitles ? Palette.rowHeightWithSubtitle : Palette.rowHeight
        let listHeight = items.isEmpty ? 40 : CGFloat(rowsShown) * perRow
        let totalHeight: CGFloat = 14 + 24 + 10 + listHeight + 8
        var frame = panel.frame
        let topLeft = NSPoint(x: frame.minX, y: frame.maxY)
        frame.size.height = totalHeight
        panel.setFrame(frame, display: true)
        panel.setFrameTopLeftPoint(topLeft)
    }

    // MARK: - Keyboard

    public func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextField) === searchField else { return }
        onQueryChanged?(searchField.stringValue)
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
            onCancel?()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if let item = selectedItem {
                dismiss()
                onCommit?(item)
            }
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        default:
            return false
        }
    }

    private func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let current = max(tableView.selectedRow, 0)
        let next = min(max(current + delta, 0), items.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
        notifyHighlightChanged()
    }

    private func notifyHighlightChanged() {
        if let item = selectedItem {
            onHighlightChanged?(item)
        }
    }

    @objc private func tableViewClicked() {
        guard let item = selectedItem else { return }
        dismiss()
        onCommit?(item)
    }

    // MARK: - NSTableViewDataSource / Delegate

    public func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < items.count else { return Palette.rowHeight }
        return items[row].subtitle != nil ? Palette.rowHeightWithSubtitle : Palette.rowHeight
    }

    /// Builds a fresh row view every time rather than pooling via
    /// `makeView(withIdentifier:owner:)` — a reused view whose constraints were fixed
    /// at creation time (title centred vs. title-plus-subtitle-below) would show the
    /// wrong layout when recycled onto a row whose subtitle-presence differs from
    /// whatever row last used that pooled view. The palette only ever shows a handful
    /// of visible rows at once, so the pooling optimisation isn't worth that footgun.
    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < items.count else { return nil }
        let item = items[row]

        let cell = NSTableCellView(frame: .zero)
        let titleField = NSTextField(labelWithString: "")
        let subtitleField = NSTextField(labelWithString: "")
        subtitleField.font = .systemFont(ofSize: 11)
        subtitleField.textColor = .secondaryLabelColor

        cell.addSubview(titleField)
        cell.addSubview(subtitleField)
        cell.textField = titleField

        titleField.translatesAutoresizingMaskIntoConstraints = false
        subtitleField.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            titleField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            subtitleField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            subtitleField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
        ])
        if item.subtitle != nil {
            NSLayoutConstraint.activate([
                titleField.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),
                subtitleField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 1),
            ])
        } else {
            NSLayoutConstraint.activate([
                titleField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        titleField.attributedStringValue = attributedTitle(for: item)
        subtitleField.stringValue = item.subtitle ?? ""
        subtitleField.isHidden = item.subtitle == nil
        return cell
    }

    private func attributedTitle(for item: PaletteItem) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 13)
        let boldFont = NSFont.boldSystemFont(ofSize: 13)
        let result = NSMutableAttributedString(string: item.title, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ])
        guard !item.matchedIndices.isEmpty else { return result }

        let characters = Array(item.title)
        for index in item.matchedIndices where index >= 0 && index < characters.count {
            guard let stringIndex = item.title.index(item.title.startIndex, offsetBy: index, limitedBy: item.title.endIndex)
            else { continue }
            let nextIndex = item.title.index(after: stringIndex)
            let range = NSRange(stringIndex ..< nextIndex, in: item.title)
            result.addAttribute(.font, value: boldFont, range: range)
            result.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: range)
        }
        return result
    }
}
