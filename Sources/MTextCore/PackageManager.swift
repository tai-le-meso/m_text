import Foundation

/// Installs user-supplied syntax definitions and colour schemes into the Packages
/// folder, so languages missing from the built-in set can be added without a rebuild.
///
/// Fully offline by design: it copies from a path the user picked, never fetches. Every
/// candidate is *validated by actually loading it* before being installed, so a broken
/// grammar is reported at import time instead of silently failing to colour anything.
public final class PackageManager {

    /// `~/Library/Application Support/m_text/Packages`
    public let packagesDirectory: URL

    public init(packagesDirectory: URL? = nil) {
        if let packagesDirectory {
            self.packagesDirectory = packagesDirectory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.packagesDirectory = support
                .appendingPathComponent("m_text", isDirectory: true)
                .appendingPathComponent("Packages", isDirectory: true)
        }
    }

    // MARK: - Kinds

    public enum ItemKind: String, CaseIterable {
        case sublimeSyntax = "sublime-syntax"
        case tmLanguage = "tmlanguage"
        case sublimeColorScheme = "sublime-color-scheme"
        case tmTheme = "tmtheme"

        public var isGrammar: Bool { self == .sublimeSyntax || self == .tmLanguage }

        public static var allExtensions: [String] { allCases.map(\.rawValue) }

        init?(fileExtension: String) {
            guard let kind = ItemKind(rawValue: fileExtension.lowercased()) else { return nil }
            self = kind
        }
    }

    // MARK: - Results

    public struct InstalledItem {
        public let name: String
        public let scope: String?
        public let kind: ItemKind
        public let url: URL
        /// True when this replaced a file already in the Packages folder.
        public let replacedExisting: Bool
    }

    public struct ImportReport {
        public var installed: [InstalledItem] = []
        /// File name → why it was skipped.
        public var rejected: [(name: String, reason: String)] = []
        /// Non-fatal loader complaints, prefixed with the file they came from.
        public var diagnostics: [String] = []

        public var isEmpty: Bool { installed.isEmpty && rejected.isEmpty }

        /// One-line summary for an alert.
        public var summary: String {
            var parts: [String] = []
            if !installed.isEmpty {
                let names = installed.map(\.name).joined(separator: ", ")
                parts.append("Imported \(installed.count): \(names)")
            }
            if !rejected.isEmpty {
                parts.append("Skipped \(rejected.count)")
            }
            return parts.isEmpty ? "Nothing to import" : parts.joined(separator: ". ")
        }

        /// Full detail for the alert's accessory text.
        public var details: String {
            var lines: [String] = []
            for item in installed {
                lines.append("✓ \(item.name)\(item.replacedExisting ? " (replaced)" : "")")
            }
            for item in rejected {
                lines.append("✗ \(item.name) — \(item.reason)")
            }
            lines.append(contentsOf: diagnostics.map { "· \($0)" })
            return lines.joined(separator: "\n")
        }
    }

    public struct PackageError: LocalizedError {
        public let reason: String
        public var errorDescription: String? { reason }
    }

    // MARK: - Import

    /// Imports a single file, or every supported file inside a folder (recursively).
    @discardableResult
    public func `import`(from url: URL) throws -> ImportReport {
        try createPackagesDirectoryIfNeeded()

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw PackageError(reason: "\(url.lastPathComponent) does not exist.")
        }

        var report = ImportReport()
        if isDirectory.boolValue {
            for candidate in supportedFiles(in: url) {
                install(candidate, into: &report)
            }
            if report.isEmpty {
                throw PackageError(reason: """
                No syntax definitions or colour schemes found in \(url.lastPathComponent). \
                Looking for: \(ItemKind.allExtensions.map { "." + $0 }.joined(separator: ", ")).
                """)
            }
        } else {
            install(url, into: &report)
            if let rejection = report.rejected.first, report.installed.isEmpty {
                throw PackageError(reason: rejection.reason)
            }
        }
        return report
    }

    /// Imports several picked items in one report.
    @discardableResult
    public func `import`(from urls: [URL]) throws -> ImportReport {
        try createPackagesDirectoryIfNeeded()
        var combined = ImportReport()
        for url in urls {
            do {
                let report = try `import`(from: url)
                combined.installed.append(contentsOf: report.installed)
                combined.rejected.append(contentsOf: report.rejected)
                combined.diagnostics.append(contentsOf: report.diagnostics)
            } catch {
                combined.rejected.append((url.lastPathComponent, error.localizedDescription))
            }
        }
        return combined
    }

    /// Validates one file and, if it loads, copies it into the Packages folder.
    private func install(_ url: URL, into report: inout ImportReport) {
        let fileName = url.lastPathComponent
        guard let kind = ItemKind(fileExtension: url.pathExtension) else {
            report.rejected.append((fileName, "Unsupported file type '.\(url.pathExtension)'."))
            return
        }

        let validated: (name: String, scope: String?)
        do {
            validated = try validate(url, kind: kind, into: &report)
        } catch {
            report.rejected.append((fileName, error.localizedDescription))
            return
        }

        // Same-named file wins: importing a newer copy of a grammar should replace it,
        // not accumulate "Java 2.sublime-syntax".
        let destination = packagesDirectory.appendingPathComponent(fileName)

        // Re-importing a file that is *already* installed — one click away via
        // Reveal Packages Folder → Import — must not remove-then-copy, or the source
        // and the destination are the same file and it gets deleted.
        if url.resolvingSymlinksInPath().standardizedFileURL
            == destination.resolvingSymlinksInPath().standardizedFileURL {
            report.installed.append(InstalledItem(name: validated.name,
                                                  scope: validated.scope,
                                                  kind: kind,
                                                  url: destination,
                                                  replacedExisting: true))
            return
        }

        let replacing = FileManager.default.fileExists(atPath: destination.path)
        do {
            if replacing { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            report.rejected.append((fileName, "Could not copy into Packages: \(error.localizedDescription)"))
            return
        }

        report.installed.append(InstalledItem(name: validated.name,
                                              scope: validated.scope,
                                              kind: kind,
                                              url: destination,
                                              replacedExisting: replacing))
    }

    /// Loads the file to prove it works, returning its display name and scope.
    private func validate(_ url: URL, kind: ItemKind, into report: inout ImportReport) throws
        -> (name: String, scope: String?) {
        let fileName = url.lastPathComponent
        switch kind {
        case .sublimeSyntax:
            let loaded = try SublimeSyntaxLoader.load(contentsOf: url)
            report.diagnostics.append(contentsOf: loaded.diagnostics.messages.map { "\(fileName): \($0)" })
            return (loaded.grammar.name, loaded.grammar.scope.raw)
        case .tmLanguage:
            let loaded = try TMLanguageLoader.load(contentsOf: url)
            report.diagnostics.append(contentsOf: loaded.diagnostics.messages.map { "\(fileName): \($0)" })
            return (loaded.grammar.name, loaded.grammar.scope.raw)
        case .sublimeColorScheme, .tmTheme:
            let scheme = try ColorSchemeLoader.load(contentsOf: url)
            return (scheme.name, nil)
        }
    }

    private func supportedFiles(in directory: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: directory,
                                                          includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]) else { return [] }
        var found: [URL] = []
        for case let candidate as URL in walker
        where ItemKind(fileExtension: candidate.pathExtension) != nil {
            found.append(candidate)
        }
        return found.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - Inventory

    public func createPackagesDirectoryIfNeeded() throws {
        guard !FileManager.default.fileExists(atPath: packagesDirectory.path) else { return }
        try FileManager.default.createDirectory(at: packagesDirectory,
                                                withIntermediateDirectories: true)
    }

    /// Everything currently installed, grammars and schemes alike.
    public func installedFiles() -> [URL] {
        supportedFiles(in: packagesDirectory)
    }

    public func remove(_ url: URL) throws {
        // Only ever delete strictly inside our own folder. A bare `hasPrefix` would
        // also accept a sibling like "…/PackagesEvil/x", and would not resolve "..".
        let root = packagesDirectory.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        guard target.hasPrefix(root.hasSuffix("/") ? root : root + "/") else {
            throw PackageError(reason: "\(url.lastPathComponent) is not in the Packages folder.")
        }
        try FileManager.default.removeItem(at: url)
    }
}
