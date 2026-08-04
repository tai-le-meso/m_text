import AppKit
import MTextCore

/// Builds the Syntax menu on demand and handles grammar import.
///
/// The menu is populated from `NSMenuDelegate.menuNeedsUpdate`, not once at launch, so a
/// grammar imported mid-session appears immediately without a restart.
public final class SyntaxMenuController: NSObject, NSMenuDelegate {

    public static let shared = SyntaxMenuController()

    public let packageManager = PackageManager()
    public let registry = GrammarRegistry()

    private override init() {
        super.init()
        // Deliberately not `reloadGrammars()`: that posts a notification, and this runs
        // inside `static let shared`'s one-time initialiser. Any observer touching
        // `SyntaxMenuController.shared` from the notification would deadlock.
        registry.reload(packagesDirectory: packageManager.packagesDirectory)
    }

    // MARK: - Registry

    public func reloadGrammars() {
        registry.reload(packagesDirectory: packageManager.packagesDirectory)
        NotificationCenter.default.post(name: SyntaxMenuController.grammarsDidChange, object: self)
    }

    public static let grammarsDidChange = Notification.Name("io.mesoneer.mtext.grammarsDidChange")

    // MARK: - NSMenuDelegate

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let importItem = NSMenuItem(title: "Import Syntax…",
                                    action: #selector(importSyntax(_:)),
                                    keyEquivalent: "")
        importItem.target = self
        menu.addItem(importItem)

        let revealItem = NSMenuItem(title: "Reveal Packages Folder",
                                    action: #selector(revealPackagesFolder(_:)),
                                    keyEquivalent: "")
        revealItem.target = self
        menu.addItem(revealItem)

        let reloadItem = NSMenuItem(title: "Reload Syntaxes",
                                    action: #selector(reloadSyntaxes(_:)),
                                    keyEquivalent: "")
        reloadItem.target = self
        menu.addItem(reloadItem)

        menu.addItem(.separator())

        // Nil target: routed through the responder chain to the focused window.
        // Identity is the scope, not the title: two grammars may share a display name
        // (an imported "Java" alongside the built-in) and titles would misroute.
        let activeScope = (NSApp.keyWindow?.windowController as? MainWindowController)?.currentSyntaxScope
        for grammar in registry.selectableGrammars {
            let item = NSMenuItem(title: grammar.name,
                                  action: #selector(MainWindowController.setSyntaxFromMenu(_:)),
                                  keyEquivalent: "")
            item.representedObject = grammar.scope.raw
            item.state = grammar.scope.raw == activeScope ? .on : .off
            menu.addItem(item)
        }

        if !registry.diagnostics.isEmpty {
            menu.addItem(.separator())
            let item = NSMenuItem(title: "\(registry.diagnostics.count) grammar warning(s)…",
                                  action: #selector(showDiagnostics(_:)),
                                  keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
    }

    // MARK: - Actions

    @objc private func importSyntax(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        // Filtered via the delegate rather than `allowedContentTypes`: these extensions
        // have no registered UTType, so a UTType-based filter would rely on dynamic
        // types. (`allowedFileTypes` is the deprecated string-based equivalent.)
        panel.delegate = self
        panel.message = """
        Choose .sublime-syntax, .tmLanguage, .sublime-color-scheme or .tmTheme files, \
        or a folder containing them.
        """
        panel.prompt = "Import"

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        do {
            let report = try packageManager.import(from: panel.urls)
            reloadGrammars()
            present(report)
        } catch {
            presentError(error)
        }
    }

    @objc private func revealPackagesFolder(_ sender: Any?) {
        do {
            try packageManager.createPackagesDirectoryIfNeeded()
            NSWorkspace.shared.activateFileViewerSelecting([packageManager.packagesDirectory])
        } catch {
            presentError(error)
        }
    }

    @objc private func reloadSyntaxes(_ sender: Any?) {
        reloadGrammars()
    }

    @objc private func showDiagnostics(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Grammar warnings"
        alert.informativeText = registry.diagnostics.prefix(30).joined(separator: "\n")
        alert.alertStyle = .informational
        alert.runModal()
    }

    // MARK: - Reporting

    private func present(_ report: PackageManager.ImportReport) {
        let alert = NSAlert()
        alert.messageText = report.summary
        alert.informativeText = report.details
        alert.alertStyle = report.installed.isEmpty ? .warning : .informational
        alert.runModal()
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could not import"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}

// MARK: - Open panel filtering

extension SyntaxMenuController: NSOpenSavePanelDelegate {

    /// Folders stay navigable and selectable (importing a folder scans it); files are
    /// enabled only when their extension is one we can install.
    public func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        if values?.isDirectory == true { return true }
        return PackageManager.ItemKind.allExtensions.contains(url.pathExtension.lowercased())
    }
}
