import AppKit
import MTextCore

/// The find/replace panel that sits below the editor.
///
/// Built programmatically like everything else. It owns no search state — it reports
/// user intent through `delegate` and displays whatever the `SearchSession` reports.
public protocol FindBarDelegate: AnyObject {
    func findBar(_ bar: FindBar, queryChanged query: SearchQuery)
    func findBarFindNext(_ bar: FindBar)
    func findBarFindPrevious(_ bar: FindBar)
    func findBarFindAll(_ bar: FindBar)
    func findBar(_ bar: FindBar, replaceCurrentWith template: String)
    func findBar(_ bar: FindBar, replaceAllWith template: String)
    func findBarDismissed(_ bar: FindBar)
}

public final class FindBar: NSView, NSTextFieldDelegate {

    public weak var delegate: FindBarDelegate?

    public private(set) var showsReplace = false

    private let findField = NSTextField()
    private let replaceField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "")

    private let regexToggle = NSButton()
    private let caseToggle = NSButton()
    private let wordToggle = NSButton()
    private let wrapToggle = NSButton()
    private let preserveCaseToggle = NSButton()

    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let findAllButton = NSButton()
    private let replaceButton = NSButton()
    private let replaceAllButton = NSButton()
    private let closeButton = NSButton()

    private var replaceRow: NSStackView!
    private var rootStack: NSStackView!

    // MARK: - Init

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        build()
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    public override var isFlipped: Bool { true }

    private func build() {
        let findRow = NSStackView(views: [
            label("Find"),
            findField,
            toggle(regexToggle, title: ".*", tooltip: "Regular expression"),
            toggle(caseToggle, title: "Aa", tooltip: "Case sensitive"),
            toggle(wordToggle, title: "W", tooltip: "Whole word"),
            toggle(wrapToggle, title: "↻", tooltip: "Wrap around"),
            statusLabel,
            button(previousButton, title: "‹", action: #selector(findPrevious(_:)), tooltip: "Previous (⇧⌘G)"),
            button(nextButton, title: "›", action: #selector(findNext(_:)), tooltip: "Next (⌘G)"),
            button(findAllButton, title: "Find All", action: #selector(findAll(_:)), tooltip: nil),
            button(closeButton, title: "✕", action: #selector(dismiss(_:)), tooltip: "Close (⎋)"),
        ])
        findRow.orientation = .horizontal
        findRow.spacing = 6
        findRow.alignment = .centerY

        replaceRow = NSStackView(views: [
            label("Replace"),
            replaceField,
            toggle(preserveCaseToggle, title: "AB", tooltip: "Preserve case"),
            button(replaceButton, title: "Replace", action: #selector(replaceCurrent(_:)), tooltip: nil),
            button(replaceAllButton, title: "All", action: #selector(replaceAll(_:)), tooltip: nil),
        ])
        replaceRow.orientation = .horizontal
        replaceRow.spacing = 6
        replaceRow.alignment = .centerY
        replaceRow.isHidden = true

        rootStack = NSStackView(views: [findRow, replaceRow])
        rootStack.orientation = .vertical
        rootStack.spacing = 6
        rootStack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rootStack)

        // The bar is collapsed to zero height when hidden. `isHidden` does not exempt a
        // view from its constraints in AppKit, so the bottom pin has to yield and the
        // stack must not resist being clipped — otherwise every launch and every dismiss
        // logs an unsatisfiable-constraints warning.
        let bottom = rootStack.bottomAnchor.constraint(equalTo: bottomAnchor)
        bottom.priority = .defaultHigh
        rootStack.setClippingResistancePriority(.defaultHigh, for: .vertical)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: topAnchor),
            bottom,
        ])

        for field in [findField, replaceField] {
            field.delegate = self
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.placeholderString = field === findField ? "Find" : "Replace with"
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            field.widthAnchor.constraint(greaterThanOrEqualTo: widthAnchor, multiplier: 0.25).isActive = true
        }
        findField.target = self
        findField.action = #selector(findNext(_:)) // Return in the field finds the next match

        statusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .right
        statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true

        wrapToggle.state = .on
        // Case-sensitive by default, matching `SearchQuery.literal` so that ⌘D, ⌘E and
        // the find bar all agree.
        caseToggle.state = .on
    }

    // MARK: - Builders

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        field.widthAnchor.constraint(equalToConstant: 52).isActive = true
        field.alignment = .right
        return field
    }

    private func toggle(_ button: NSButton, title: String, tooltip: String) -> NSButton {
        button.title = title
        button.setButtonType(.pushOnPushOff)
        button.bezelStyle = .rounded
        button.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        button.toolTip = tooltip
        button.target = self
        button.action = #selector(optionsChanged(_:))
        button.widthAnchor.constraint(equalToConstant: 34).isActive = true
        return button
    }

    private func button(_ button: NSButton, title: String, action: Selector, tooltip: String?) -> NSButton {
        button.title = title
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 11)
        button.toolTip = tooltip
        button.target = self
        button.action = action
        return button
    }

    // MARK: - Appearance

    public override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    /// Single source of truth for the bar's height — the window controller drives its
    /// height constraint from this rather than repeating the numbers.
    public var preferredHeight: CGFloat { showsReplace ? 74 : 40 }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: preferredHeight)
    }

    // MARK: - State

    public var query: SearchQuery {
        SearchQuery(pattern: findField.stringValue,
                    isRegex: regexToggle.state == .on,
                    caseSensitive: caseToggle.state == .on,
                    wholeWord: wordToggle.state == .on,
                    wrap: wrapToggle.state == .on,
                    preserveCase: preserveCaseToggle.state == .on)
    }

    public var replacementTemplate: String { replaceField.stringValue }

    public func setReplaceVisible(_ visible: Bool) {
        showsReplace = visible
        replaceRow.isHidden = !visible
        invalidateIntrinsicContentSize()
    }

    /// Seeds the find field, typically from the current selection.
    public func setSearchText(_ text: String) {
        findField.stringValue = text
        notifyQueryChanged()
    }

    /// Displays what the session found, and flags an invalid pattern.
    public func updateStatus(_ text: String?, isError: Bool) {
        statusLabel.stringValue = text ?? ""
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
        findField.textColor = isError ? .systemRed : .labelColor

        let hasMatches = !(text ?? "").isEmpty && !isError && text != "No results"
        for control in [previousButton, nextButton, replaceButton, replaceAllButton] {
            control.isEnabled = hasMatches
        }
        findAllButton.isEnabled = !findField.stringValue.isEmpty && !isError
    }

    public func focusFindField() {
        window?.makeFirstResponder(findField)
        findField.currentEditor()?.selectAll(nil)
    }

    // MARK: - Actions

    @objc private func optionsChanged(_ sender: Any?) { notifyQueryChanged() }
    @objc private func findNext(_ sender: Any?) { delegate?.findBarFindNext(self) }
    @objc private func findPrevious(_ sender: Any?) { delegate?.findBarFindPrevious(self) }
    @objc private func findAll(_ sender: Any?) { delegate?.findBarFindAll(self) }
    @objc private func dismiss(_ sender: Any?) { delegate?.findBarDismissed(self) }

    @objc private func replaceCurrent(_ sender: Any?) {
        delegate?.findBar(self, replaceCurrentWith: replacementTemplate)
    }

    @objc private func replaceAll(_ sender: Any?) {
        delegate?.findBar(self, replaceAllWith: replacementTemplate)
    }

    private func notifyQueryChanged() {
        delegate?.findBar(self, queryChanged: query)
    }

    // MARK: - NSTextFieldDelegate

    /// Incremental find: every keystroke re-runs the search.
    public func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextField) === findField else { return }
        notifyQueryChanged()
    }

    public func control(_ control: NSControl,
                        textView: NSTextView,
                        doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            delegate?.findBarDismissed(self)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if control === replaceField {
                delegate?.findBar(self, replaceCurrentWith: replacementTemplate)
            } else {
                // Shift-Return searches backwards, matching Sublime.
                if NSEvent.modifierFlags.contains(.shift) {
                    delegate?.findBarFindPrevious(self)
                } else {
                    delegate?.findBarFindNext(self)
                }
            }
            return true
        default:
            return false
        }
    }
}
