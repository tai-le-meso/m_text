import Foundation

public enum TextDocumentError: LocalizedError {
    case noSaveDestination

    public var errorDescription: String? {
        switch self {
        case .noSaveDestination: return "This document has no file to save to."
        }
    }
}

/// The editable document: a `PieceTree` plus undo history, encoding, line-ending
/// convention and a line-string cache. This is the API the UI talks to.
///
/// Positions use Character (grapheme) columns; internally everything is UTF-8
/// byte offsets, which is what keeps edits O(log n) regardless of file size.
public final class TextDocument {

    // MARK: Storage

    private var tree: PieceTree
    public let undoStack = UndoStack()

    public private(set) var encoding: TextEncodingKind = .utf8
    public private(set) var lineEnding: LineEnding = .lf
    public private(set) var fileURL: URL?
    public private(set) var modificationDate: Date?

    private var savedGroupID: UInt64?
    private var lineCache: [Int: String] = [:]
    private static let lineCacheLimit = 4096

    private var storedLongestLineLength = 0
    private var longestLineIsStale = false

    /// Longest known line in Characters. Exact for small files; for very large
    /// files it starts as an estimate and grows as lines are measured.
    ///
    /// Recomputed lazily: undo/redo only mark it stale, so holding ⌘Z doesn't pay
    /// a full document scan per step.
    public var longestLineLength: Int {
        if longestLineIsStale { recomputeLongestLine() }
        return storedLongestLineLength
    }

    /// Bumped on every mutation. Background workers stamp their results with the
    /// generation they read, so stale results can be dropped.
    public private(set) var generation: UInt64 = 0

    public init(text: String = "") {
        tree = PieceTree(text: text)
        recomputeLongestLine()
    }

    // MARK: Metrics

    public var lineCount: Int { tree.lineCount }
    public var byteCount: Int { tree.byteCount }
    /// Compared by group identity, not stack depth: undoing back to the save point
    /// is clean, but undo-then-retype (same depth, different edit) is dirty.
    public var isDirty: Bool { undoStack.currentGroupID != savedGroupID }

    /// O(1) immutable snapshot for background readers (highlighter, search).
    /// Must be called from the thread that owns the document.
    public func snapshot() -> PieceTree { tree }

    // MARK: Text access

    public var text: String { tree.text }

    public func line(_ index: Int) -> String {
        guard index >= 0, index < lineCount else { return "" }
        if let cached = lineCache[index] { return cached }
        let value = tree.lineText(index)
        if lineCache.count >= TextDocument.lineCacheLimit { lineCache.removeAll(keepingCapacity: true) }
        lineCache[index] = value
        if value.count > storedLongestLineLength { storedLongestLineLength = value.count }
        return value
    }

    public func lineLength(_ index: Int) -> Int { line(index).count }

    /// Replaces the whole document and resets history — used when opening a file.
    public func setText(_ newText: String,
                        url: URL? = nil,
                        encoding: TextEncodingKind = .utf8,
                        lineEnding: LineEnding = .lf,
                        modificationDate: Date? = nil) {
        tree = PieceTree(text: newText)
        self.encoding = encoding
        self.lineEnding = lineEnding
        self.fileURL = url
        self.modificationDate = modificationDate
        undoStack.clear()
        savedGroupID = nil
        invalidateCaches()
        recomputeLongestLine()
    }

    // MARK: Position <-> byte offset

    public func clamp(_ p: Position) -> Position {
        let line = max(0, min(p.line, lineCount - 1))
        let column = max(0, min(p.column, lineLength(line)))
        return Position(line: line, column: column)
    }

    public func byteOffset(of position: Position) -> Int {
        let p = clamp(position)
        let start = tree.offsetOfLine(p.line)
        if p.column == 0 { return start }
        let s = line(p.line)
        let idx = s.index(s.startIndex, offsetBy: p.column)
        return start + s[..<idx].utf8.count
    }

    public func position(ofByteOffset offset: Int) -> Position {
        let o = max(0, min(offset, byteCount))
        let lineIndex = tree.lineOfOffset(o)
        let start = tree.offsetOfLine(lineIndex)
        if o <= start { return Position(line: lineIndex, column: 0) }
        let prefix = tree.text(offset: start, length: o - start)
        return Position(line: lineIndex, column: prefix.count)
    }

    // MARK: Editing

    /// Inserts `string` (may contain newlines) and returns the position after it.
    @discardableResult
    public func insert(_ string: String, at position: Position) -> Position {
        guard !string.isEmpty else { return clamp(position) }
        let before = clamp(position)
        let offset = byteOffset(of: before)
        tree.insert(string, at: offset)
        invalidateCaches()
        let after = self.position(ofByteOffset: offset + string.utf8.count)
        undoStack.record(TextEdit(offset: offset, removed: "", inserted: string,
                                  caretBefore: before, caretAfter: after))
        noteEditedLines(from: before.line, to: after.line)
        return after
    }

    /// Deletes the byte range `[start, end)` and returns the caret position at `start`.
    @discardableResult
    public func delete(from start: Position, to end: Position) -> Position {
        let a = clamp(start)
        let b = clamp(end)
        let lo = min(a, b), hi = max(a, b)
        let loOffset = byteOffset(of: lo)
        let hiOffset = byteOffset(of: hi)
        guard hiOffset > loOffset else { return lo }
        let removed = tree.text(offset: loOffset, length: hiOffset - loOffset)
        tree.delete(offset: loOffset, length: hiOffset - loOffset)
        invalidateCaches()
        let after = position(ofByteOffset: loOffset)
        undoStack.record(TextEdit(offset: loOffset, removed: removed, inserted: "",
                                  caretBefore: hi, caretAfter: after))
        noteEditedLines(from: after.line, to: after.line)
        return after
    }

    /// Deletes the grapheme cluster before `position` (joining lines at column 0).
    @discardableResult
    public func deleteBackward(at position: Position) -> Position {
        let p = clamp(position)
        if p.column > 0 {
            let s = line(p.line)
            let end = s.index(s.startIndex, offsetBy: p.column)
            let start = s.index(before: end)
            let previous = Position(line: p.line, column: p.column - s.distance(from: start, to: end))
            return delete(from: previous, to: p)
        }
        guard p.line > 0 else { return p }
        let previousLine = p.line - 1
        let previous = Position(line: previousLine, column: lineLength(previousLine))
        return delete(from: previous, to: p)
    }

    /// Deletes the grapheme cluster after `position`.
    @discardableResult
    public func deleteForward(at position: Position) -> Position {
        let p = clamp(position)
        let length = lineLength(p.line)
        if p.column < length {
            return delete(from: p, to: Position(line: p.line, column: p.column + 1))
        }
        guard p.line + 1 < lineCount else { return p }
        return delete(from: p, to: Position(line: p.line + 1, column: 0))
    }

    // MARK: Undo / redo

    public var canUndo: Bool { undoStack.canUndo }
    public var canRedo: Bool { undoStack.canRedo }

    /// Call when the caret moves without editing, so the next keystroke starts a
    /// fresh undo step (Sublime behaviour).
    public func breakUndoCoalescing() { undoStack.breakCoalescing() }

    @discardableResult
    public func undo() -> Position? {
        let caret = undoStack.undo { [weak self] edit in
            guard let self else { return }
            self.tree.replace(offset: edit.offset,
                              length: edit.inserted.utf8.count,
                              with: edit.removed)
        }
        if caret != nil {
            invalidateCaches()
            longestLineIsStale = true
        }
        return caret.map(clamp)
    }

    @discardableResult
    public func redo() -> Position? {
        let caret = undoStack.redo { [weak self] edit in
            guard let self else { return }
            self.tree.replace(offset: edit.offset,
                              length: edit.removed.utf8.count,
                              with: edit.inserted)
        }
        if caret != nil {
            invalidateCaches()
            longestLineIsStale = true
        }
        return caret.map(clamp)
    }

    // MARK: File I/O

    public func load(from url: URL) throws {
        let loaded = try FileIO.load(url)
        setText(loaded.text,
                url: url,
                encoding: loaded.encoding,
                lineEnding: loaded.lineEnding,
                modificationDate: loaded.modificationDate)
    }

    public func save(to url: URL? = nil) throws {
        guard let target = url ?? fileURL else { throw TextDocumentError.noSaveDestination }
        modificationDate = try FileIO.save(text: text,
                                           to: target,
                                           encoding: encoding,
                                           lineEnding: lineEnding)
        fileURL = target
        undoStack.breakCoalescing()
        savedGroupID = undoStack.currentGroupID
    }

    /// T85 (hot exit): a buffer restored from the session must report `isDirty` even
    /// though its undo history is freshly reset — `setText` cleared `savedGroupID` to
    /// nil, and a fresh `undoStack.currentGroupID` is also nil, which would read as
    /// clean. Setting the save point to a sentinel no real undo group ever gets makes
    /// `isDirty` true until the next actual `save(to:)` records a real save point.
    public func markRestoredDirty() {
        savedGroupID = .max
    }

    /// True when the file on disk changed since we last read or wrote it.
    public func hasExternalChanges() -> Bool {
        guard let url = fileURL, let known = modificationDate,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let current = attrs[.modificationDate] as? Date else { return false }
        return current > known
    }

    public func setEncoding(_ encoding: TextEncodingKind) { self.encoding = encoding }
    public func setLineEnding(_ lineEnding: LineEnding) { self.lineEnding = lineEnding }

    // MARK: Caches

    private func invalidateCaches() {
        lineCache.removeAll(keepingCapacity: true)
        generation &+= 1
    }

    private func noteEditedLines(from: Int, to: Int) {
        let lower = max(0, from)
        let upper = min(to, lineCount - 1)
        guard lower <= upper else { return }
        for i in lower ... upper {
            storedLongestLineLength = max(storedLongestLineLength, lineLength(i))
        }
    }

    /// Exact for documents up to 100k lines; larger files keep the widest line seen
    /// so far rather than paying an O(n) scan.
    private func recomputeLongestLine() {
        longestLineIsStale = false
        let count = lineCount
        guard count <= 100_000 else {
            storedLongestLineLength = max(storedLongestLineLength, 256)
            return
        }
        var longest = 0
        for i in 0 ..< count { longest = max(longest, tree.lineText(i).count) }
        storedLongestLineLength = longest
    }
}
