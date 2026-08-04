import Foundation

/// One hit, with the line it was found on (T63).
public struct FileMatch: Equatable {
    public let url: URL
    /// 0-based, matching `Position` and Goto Anything's `:line` conversion.
    public let line: Int
    public let column: Int
    public let length: Int
    /// The whole line, for showing context without re-reading the file.
    public let lineText: String
    /// Lines immediately before and after, when the request asked for context.
    ///
    /// Captured during the sweep rather than re-read when the results buffer is built: the
    /// file is already in memory at that point, and re-opening every matched file later
    /// would both cost more and risk showing text that changed in between.
    public let contextBefore: [String]
    public let contextAfter: [String]

    public init(url: URL, line: Int, column: Int, length: Int, lineText: String,
                contextBefore: [String] = [], contextAfter: [String] = []) {
        self.url = url
        self.line = line
        self.column = column
        self.length = length
        self.lineText = lineText
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
    }
}

/// What to search, and where.
public struct FindInFilesRequest {
    public var query: SearchQuery
    public var roots: [URL]
    public var excludedNames: Set<String>
    /// Files larger than this are skipped. A search is not the right way to discover that
    /// a 2 GB log exists, and reading one would stall the whole sweep.
    public var maximumFileSizeBytes: Int
    /// Stops the sweep once this many matches are found, so a pattern like `e` across a
    /// large tree can't fill memory before anyone sees the first result.
    public var maximumMatches: Int
    public var maximumFiles: Int
    /// Lines of surrounding context to capture with each match (T64).
    public var contextLines: Int

    public init(query: SearchQuery,
                roots: [URL],
                excludedNames: Set<String> = FileIndex.defaultExcludedNames,
                maximumFileSizeBytes: Int = 4 * 1024 * 1024,
                maximumMatches: Int = 20_000,
                maximumFiles: Int = 200_000,
                contextLines: Int = 0) {
        self.query = query
        self.roots = roots
        self.excludedNames = excludedNames
        self.maximumFileSizeBytes = maximumFileSizeBytes
        self.maximumMatches = maximumMatches
        self.maximumFiles = maximumFiles
        self.contextLines = contextLines
    }
}

/// How a sweep ended — reported so the UI can say *why* results stopped rather than
/// implying the tree was fully searched.
public struct FindInFilesSummary: Equatable {
    public var filesSearched = 0
    public var filesSkipped = 0
    public var matchCount = 0
    public var hitMatchLimit = false
    public var wasCancelled = false

    public init() {}
}

/// Searches a folder tree, streaming matches as they are found.
///
/// **Streams rather than collecting.** A sweep over a large tree takes long enough that
/// waiting for it to finish before showing anything would feel broken, and the results
/// buffer (T64) is designed to append live. Batches are delivered on the main queue so the
/// UI can consume them directly; the walking and reading happen off it.
public final class FindInFilesSearch {

    /// Called on the main queue with each batch of matches, in file order within a batch.
    public var onMatches: (([FileMatch]) -> Void)?
    /// Called on the main queue once, when the sweep ends for any reason.
    public var onFinish: ((FindInFilesSummary) -> Void)?

    public private(set) var isRunning = false

    private let queue = DispatchQueue(label: "m_text.findInFiles", qos: .userInitiated)
    private var cancelled = false
    private let lock = NSLock()

    public init() {}

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public func run(_ request: FindInFilesRequest) {
        guard !request.query.isEmpty, !request.roots.isEmpty else {
            onFinish?(FindInFilesSummary())
            return
        }
        lock.lock(); cancelled = false; lock.unlock()
        isRunning = true

        queue.async { [weak self] in
            guard let self else { return }
            // Batches hop to the main queue as they are produced; the sweep itself stays
            // off it.
            let summary = self.sweep(request) { batch in
                DispatchQueue.main.async { [weak self] in self?.onMatches?(batch) }
            }
            DispatchQueue.main.async {
                self.isRunning = false
                self.onFinish?(summary)
            }
        }
    }

    /// The sweep itself, parameterised by how it hands back batches.
    ///
    /// Taking `emit` rather than posting to the main queue directly is what makes the
    /// matching, skipping and limit rules testable on the calling thread — see
    /// `runSynchronously`. The async entry point passes an `emit` that dispatches.
    private func sweep(_ request: FindInFilesRequest, emit: ([FileMatch]) -> Void) -> FindInFilesSummary {
        var summary = FindInFilesSummary()
        guard let matcher = try? SearchMatcher(request.query) else { return summary }

        // Reuses `FileIndex`'s walk rather than carrying a second directory traversal with
        // its own exclude handling — the two would drift, and Goto Anything's idea of what
        // is in the project should match Find in Files'.
        let walk = FileIndex.walk(roots: request.roots,
                                  excludedNames: request.excludedNames,
                                  maximumFiles: request.maximumFiles)

        var pending: [FileMatch] = []
        func flush() {
            guard !pending.isEmpty else { return }
            emit(pending)
            pending = []
        }

        for entry in walk.entries {
            if isCancelled {
                summary.wasCancelled = true
                break
            }
            guard let text = Self.readSearchableText(at: entry.url,
                                                     maximumBytes: request.maximumFileSizeBytes) else {
                summary.filesSkipped += 1
                continue
            }
            summary.filesSearched += 1

            let lines = text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                for match in matcher.matches(inLine: index, text: line) {
                    let context = request.contextLines
                    pending.append(FileMatch(url: entry.url,
                                             line: index,
                                             column: match.region.start.column,
                                             length: match.text.count,
                                             lineText: line,
                                             contextBefore: context > 0
                                                 ? Array(lines[max(0, index - context) ..< index])
                                                 : [],
                                             contextAfter: context > 0
                                                 ? Array(lines[min(index + 1, lines.count) ..< min(index + 1 + context, lines.count)])
                                                 : []))
                    summary.matchCount += 1
                    if summary.matchCount >= request.maximumMatches {
                        summary.hitMatchLimit = true
                        flush()
                        return summary
                    }
                }
            }
            // Batched per file rather than per match: a file with 500 hits would otherwise
            // hop to the main queue 500 times.
            flush()
        }
        flush()
        return summary
    }

    /// Runs the sweep on the calling thread and returns everything found — for tests, which
    /// should exercise the matching, skipping and limit rules without threading in the way.
    public func runSynchronously(_ request: FindInFilesRequest) -> (matches: [FileMatch], summary: FindInFilesSummary) {
        guard !request.query.isEmpty, !request.roots.isEmpty else { return ([], FindInFilesSummary()) }
        var collected: [FileMatch] = []
        let summary = sweep(request) { collected.append(contentsOf: $0) }
        return (collected, summary)
    }

    /// Reads a file only if it looks like text.
    ///
    /// A NUL byte in the first chunk is the binary test — extension lists miss unknown
    /// formats and wrongly exclude text files with odd names, whereas essentially no text
    /// encoding this app can read contains an embedded NUL. Oversized files are skipped
    /// before being read at all, not after.
    static func readSearchableText(at url: URL, maximumBytes: Int) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize, size <= maximumBytes
        else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        if data.prefix(8000).contains(0) { return nil }
        return String(data: data, encoding: .utf8)
            // Latin-1 never fails, so a non-UTF-8 file is still searchable rather than
            // silently skipped — the same fallback `TextEncoding` uses on load.
            ?? String(data: data, encoding: .isoLatin1)
    }
}
