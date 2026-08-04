import AppKit
import MTextCore

/// The inline autocomplete list (T90).
///
/// Deliberately **not** built on `Palette`, despite the visual similarity. `Palette` is a
/// modal overlay that takes key focus and owns its own search field; autocomplete is the
/// opposite in both respects — you keep typing in the editor, so the editor must keep
/// first responder and the popup is a passive display driven from outside. That makes it a
/// `.nonactivatingPanel` that is only ever `orderFront`ed, never made key.
///
/// Keeping the editor as first responder is also what keeps the caret blinking and the
/// selection tinted while the list is up, and it sidesteps the whole class of problem
/// behind the blank-pane bug (KNOWLEDGE.md), which was triggered precisely by the editor
/// losing focus to an overlay.
final class CompletionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    private let panel: NSPanel
    private let tableView: NSTableView
    private let scrollView: NSScrollView

    private(set) var items: [CompletionItem] = []

    /// Fired by a double-click. Keyboard commits go through the editor's own key handling,
    /// which reads `selectedItem` — the popup never sees those keystrokes.
    var onCommit: ((CompletionItem) -> Void)?

    private static let rowHeight: CGFloat = 20
    private static let maxVisibleRows = 10
    private static let minWidth: CGFloat = 180
    private static let maxWidth: CGFloat = 520

    var isVisible: Bool { panel.isVisible }

    var selectedItem: CompletionItem? {
        let row = tableView.selectedRow
        guard row >= 0, row < items.count else { return nil }
        return items[row]
    }

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 100),
                        // `.nonactivatingPanel` is the load-bearing flag: without it,
                        // ordering the panel front deactivates the main window and the
                        // editor stops looking (and behaving) focused.
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Above the document window but below palettes/panels that *are* modal.
        panel.level = .popUpMenu
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = false
        // Autocomplete must not survive its editor: a popup left behind after a ⌘W would
        // float over whatever window came next.
        panel.hidesOnDeactivate = true

        tableView = NSTableView(frame: .zero)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("completion"))
        column.width = 240
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = CompletionPopup.rowHeight
        tableView.style = .plain
        tableView.allowsEmptySelection = false

        scrollView = NSScrollView(frame: .zero)
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false

        super.init()

        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(tableViewDoubleClicked)

        let background = NSVisualEffectView(frame: .zero)
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        background.layer?.masksToBounds = true
        background.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView(frame: .zero)
        content.addSubview(background)
        content.addSubview(scrollView)
        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: content.topAnchor),
            background.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            background.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            scrollView.topAnchor.constraint(equalTo: content.topAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -4),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -4),
        ])
        panel.contentView = content
    }

    // MARK: - Presentation

    /// Shows (or updates) the list. `anchor` is the caret rectangle in **screen**
    /// coordinates; the list hangs below it, flipping above when there isn't room, the way
    /// every other completion UI on the platform behaves.
    func show(items: [CompletionItem], over window: NSWindow, anchor: NSRect) {
        guard !items.isEmpty else {
            hide()
            return
        }
        self.items = items
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        tableView.scrollRowToVisible(0)

        let rows = min(items.count, CompletionPopup.maxVisibleRows)
        let height = CGFloat(rows) * CompletionPopup.rowHeight + 8
        let width = measuredWidth()

        var origin = NSPoint(x: anchor.minX, y: anchor.minY - height - 2)
        let screen = window.screen ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            if origin.y < visible.minY { origin.y = anchor.maxY + 2 } // flip above the caret
            // Keep it on screen horizontally too — a caret near the right edge with a long
            // symbol name would otherwise put half the list off the display.
            origin.x = min(origin.x, visible.maxX - width - 4)
            origin.x = max(origin.x, visible.minX + 4)
        }

        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)),
                       display: true)
        tableView.tableColumns.first?.width = width - 8

        if panel.parent == nil {
            // A child window follows its parent when the window moves and closes with it,
            // which a bare `orderFront` panel would not.
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    func hide() {
        guard panel.isVisible || panel.parent != nil else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        items = []
        tableView.reloadData()
    }

    /// Arrow-key navigation, driven from the editor. Wraps, matching the palette and
    /// Sublime's own list behaviour.
    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let current = tableView.selectedRow
        let next = ((current + delta) % items.count + items.count) % items.count
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    private func measuredWidth() -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        var widest: CGFloat = 0
        for item in items.prefix(CompletionPopup.maxVisibleRows * 3) {
            var text = item.text
            if let detail = item.detail { text += "   \(detail)" }
            widest = max(widest, (text as NSString).size(withAttributes: [.font: font]).width)
        }
        return min(max(widest + 28, CompletionPopup.minWidth), CompletionPopup.maxWidth)
    }

    @objc private func tableViewDoubleClicked() {
        guard let item = selectedItem else { return }
        onCommit?(item)
    }

    // MARK: - Table data

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < items.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("CompletionRow")
        let field: NSTextField
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
            field = reused
        } else {
            field = NSTextField(labelWithString: "")
            field.identifier = identifier
            field.lineBreakMode = .byTruncatingTail
        }
        field.attributedStringValue = attributedRow(for: items[row])
        return field
    }

    /// Name with the matched characters bolded and accented (same treatment `Palette`
    /// gives fuzzy matches, so the two lists read alike), then the detail dimmed.
    private func attributedRow(for item: CompletionItem) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        let result = NSMutableAttributedString(string: item.text, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ])
        let characters = Array(item.text)
        for index in item.matchedIndices where index >= 0 && index < characters.count {
            // `matchedIndices` are Character offsets; NSAttributedString ranges are UTF-16,
            // so they only coincide until something outside the BMP shows up in an
            // identifier. Converting through String.Index keeps emoji/CJK names correct.
            let start = item.text.index(item.text.startIndex, offsetBy: index)
            let end = item.text.index(after: start)
            let range = NSRange(start ..< end, in: item.text)
            result.addAttribute(.font, value: bold, range: range)
            result.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: range)
        }
        if let detail = item.detail {
            result.append(NSAttributedString(string: "   \(detail)", attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
        }
        return result
    }
}
