import AppKit
import MTextCore

/// The build output panel at the bottom of a pane (T95).
///
/// A plain `NSTextView` rather than another `EditorView`: this is read-only console output
/// with no editing, no syntax highlighting and no multi-cursor, and reusing the editor would
/// drag in a document, an undo stack and a row map for text nobody edits. The one editor-like
/// behaviour it needs — jump to the file and line an error names — is `F4`, driven from the
/// diagnostics list rather than from the text.
final class BuildPanel: NSView {

    /// Diagnostics parsed out of the current output, in the order they appeared.
    private(set) var diagnostics: [BuildDiagnostic] = []
    /// Which diagnostic F4 will go to next. -1 before the first press.
    private var currentDiagnostic = -1

    /// Asks the window to open a file at a position — the panel doesn't know about tabs.
    var onJump: ((BuildDiagnostic) -> Void)?
    var onCancel: (() -> Void)?

    private let textView = NSTextView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let cancelButton = NSButton()

    static let preferredHeight: CGFloat = 160

    /// The echoed command line, kept **separate** from `output` so it is displayed but not
    /// scanned by `file_regex`. A command containing a path and numbers — which any compiler
    /// invocation does — otherwise matches the error pattern and every build reports a
    /// spurious first error pointing at its own command line.
    private var header = ""
    private var output = ""
    private var fileRegex: String?
    private var workingDirectory = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 4)

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .small
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.isHidden = true
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        addSubview(statusLabel)
        addSubview(cancelButton)
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            cancelButton.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: cancelButton.leadingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    override var isFlipped: Bool { true }

    // MARK: - Driving

    /// Resets for a new run. `command` is echoed first so what executed is always visible.
    func beginBuild(command: String, fileRegex: String?, workingDirectory: String) {
        self.fileRegex = fileRegex
        self.workingDirectory = workingDirectory
        diagnostics = []
        currentDiagnostic = -1
        header = "$ \(command)\n"
        output = ""
        textView.string = header
        statusLabel.stringValue = "Building…"
        cancelButton.isHidden = false
    }

    func append(_ text: String) {
        output += text
        textView.string = header + output
        textView.scrollToEndOfDocument(nil)
    }

    /// Called once the process exits. Re-parses the whole output for diagnostics — output
    /// arrives in arbitrary chunks, so a partial line mid-stream could match a regex
    /// incorrectly or not at all; parsing once at the end is both simpler and correct.
    func finishBuild(status: Int32?) {
        cancelButton.isHidden = true
        diagnostics = BuildOutputParser.diagnostics(in: output, fileRegex: fileRegex,
                                                    workingDirectory: workingDirectory)
        let errors = diagnostics.isEmpty ? "" : " — \(diagnostics.count) issue\(diagnostics.count == 1 ? "" : "s") (F4 to step through)"
        switch status {
        case nil: statusLabel.stringValue = "Cancelled"
        case 0: statusLabel.stringValue = "Build succeeded\(errors)"
        case let code?: statusLabel.stringValue = "Build failed (exit \(code))\(errors)"
        }
    }

    // MARK: - Error navigation

    /// F4 / ⇧F4. Wraps, so stepping past the last error returns to the first rather than
    /// silently doing nothing.
    func goToDiagnostic(offset: Int) -> Bool {
        guard !diagnostics.isEmpty else { return false }
        let count = diagnostics.count
        currentDiagnostic = currentDiagnostic < 0
            ? (offset > 0 ? 0 : count - 1)
            : ((currentDiagnostic + offset) % count + count) % count
        onJump?(diagnostics[currentDiagnostic])
        return true
    }

    @objc private func cancelClicked() { onCancel?() }
}
