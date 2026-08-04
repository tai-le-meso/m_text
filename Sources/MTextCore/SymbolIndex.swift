import Foundation

/// Project-wide symbol index (T74): runs `SymbolExtractor` over a list of files —
/// typically whatever `FileIndex` last reported — on a background queue, so Goto
/// Symbol in Project (⌘⇧R) and Goto Definition (F12) can search across files that
/// aren't even open.
///
/// Same concurrency idiom as `FileIndex`/`HighlightService`: a plain class with a
/// private serial queue and a `generation` stamp, so a slow indexing pass that's since
/// been superseded by a newer request can never overwrite fresher results.
///
/// Deliberately **not** wired to re-run automatically on every filesystem change the
/// way `FileIndex`'s live watchers are — reading and tokenizing every file in a large
/// project on every save would be its own performance problem. Indexing instead runs
/// on demand (`index(files:registry:)`), called once per Goto Symbol/Goto Definition
/// session; re-run it explicitly (e.g. before showing the palette) if fresher results
/// matter more than instant results for a given call site.
public final class SymbolIndex {

    public struct Entry: Equatable {
        public let symbol: SymbolExtractor.Symbol
        public let url: URL
        public let displayPath: String
    }

    /// Called on the main thread when an indexing pass finishes.
    public var onUpdate: (([Entry]) -> Void)?

    /// Bounds worst-case indexing time for very large projects — a known, documented
    /// scaling limit (like `FileIndex`'s watcher cap), not a correctness bug. Files
    /// beyond this count, or larger than `maximumFileSizeBytes`, are simply skipped.
    public static let maximumFilesIndexed = 20_000
    public static let maximumFileSizeBytes = 2 * 1024 * 1024

    private let queue = DispatchQueue(label: "io.mesoneer.mtext.symbolindex", qos: .utility)
    private var generation: UInt64 = 0

    public init() {}

    /// `registry` picks each file's grammar the same way opening it normally would.
    public func index(files: [FileIndex.Entry], registry: GrammarRegistry) {
        generation &+= 1
        let stamp = generation
        let limited = Array(files.prefix(SymbolIndex.maximumFilesIndexed))
        queue.async { [weak self] in
            let entries = SymbolIndex.performIndex(files: limited, registry: registry)
            DispatchQueue.main.async {
                guard let self, stamp == self.generation else { return }
                self.onUpdate?(entries)
            }
        }
    }

    /// The pure, synchronous half — no queue, no instance state — so it can be
    /// unit-tested directly against real temp files without the generation-stamped
    /// async wrapper.
    public static func performIndex(files: [FileIndex.Entry],
                                    registry: GrammarRegistry,
                                    maximumFileSizeBytes: Int = SymbolIndex.maximumFileSizeBytes) -> [Entry] {
        var entries: [Entry] = []
        for file in files {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.url.path),
                  let size = attributes[.size] as? Int, size <= maximumFileSizeBytes,
                  let data = try? Data(contentsOf: file.url),
                  let text = String(data: data, encoding: .utf8)
            else { continue }

            let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
            let grammar = registry.grammar(for: file.url, firstLine: firstLine)
            guard grammar.scope.raw != "text.plain" else { continue }

            let tree = PieceTree(text: text)
            for symbol in SymbolExtractor.extractSymbols(from: tree, grammar: grammar) {
                entries.append(Entry(symbol: symbol, url: file.url, displayPath: file.displayPath))
            }
        }
        return entries
    }
}
