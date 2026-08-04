import Foundation

/// A single primitive edit expressed in UTF-8 byte offsets, with the caret before
/// and after so undo restores the user's place (Sublime behaviour).
public struct TextEdit {
    public let offset: Int
    public let removed: String
    public let inserted: String
    public let caretBefore: Position
    public let caretAfter: Position

    public init(offset: Int, removed: String, inserted: String,
                caretBefore: Position, caretAfter: Position) {
        self.offset = offset
        self.removed = removed
        self.inserted = inserted
        self.caretBefore = caretBefore
        self.caretAfter = caretAfter
    }
}

/// One undo step. Typing runs are coalesced into a single group so ⌘Z removes a
/// word-ish chunk rather than one character.
public struct UndoGroup {
    /// Stable identity — the dirty flag marks a save point by group id, not by
    /// stack depth, so undo-then-retype and history trimming can't fake "clean".
    public let id: UInt64
    public internal(set) var edits: [TextEdit]
    var lastEditTime: TimeInterval
    /// A group stays open for coalescing until a non-typing edit or a timeout.
    var isOpen: Bool

    var caretBefore: Position { edits.first?.caretBefore ?? .zero }
    var caretAfter: Position { edits.last?.caretAfter ?? .zero }
}

public final class UndoStack {

    /// Typing pauses longer than this start a new undo group.
    public var coalesceInterval: TimeInterval = 1.0
    public var maxGroups = 10_000

    private(set) var undoGroups: [UndoGroup] = []
    private(set) var redoGroups: [UndoGroup] = []
    private var nextGroupID: UInt64 = 1

    /// Nesting depth of `beginTransaction`, and the group all edits inside the
    /// outermost transaction are folded into.
    private var transactionDepth = 0
    private var transactionGroupIndex: Int?

    /// Set while applying an undo/redo so re-entrant records are ignored.
    public private(set) var isApplying = false

    public init() {}

    public var canUndo: Bool { !undoGroups.isEmpty }
    public var canRedo: Bool { !redoGroups.isEmpty }
    public var undoDepth: Int { undoGroups.count }
    /// Identity of the newest undo step — the save-point marker for the dirty flag.
    public var currentGroupID: UInt64? { undoGroups.last?.id }

    public func clear() {
        undoGroups.removeAll()
        redoGroups.removeAll()
        transactionDepth = 0
        transactionGroupIndex = nil
    }

    private func trimHistory() {
        guard undoGroups.count > maxGroups else { return }
        let dropped = undoGroups.count - maxGroups
        undoGroups.removeFirst(dropped)
        if let index = transactionGroupIndex { transactionGroupIndex = max(0, index - dropped) }
    }

    /// Forces the next edit to start a fresh undo group (caret moves, save points…).
    public func breakCoalescing() {
        if !undoGroups.isEmpty { undoGroups[undoGroups.count - 1].isOpen = false }
    }

    /// Folds every edit until the matching `endTransaction` into one undo step.
    ///
    /// Multi-cursor commands apply one edit per caret; without this, ⌘Z would undo
    /// them one caret at a time. Nesting is allowed; only the outermost pair counts.
    public func beginTransaction() {
        if transactionDepth == 0 {
            breakCoalescing()
            transactionGroupIndex = nil
        }
        transactionDepth += 1
    }

    public func endTransaction() {
        guard transactionDepth > 0 else { return }
        transactionDepth -= 1
        if transactionDepth == 0 {
            transactionGroupIndex = nil
            breakCoalescing()
        }
    }

    public var isInTransaction: Bool { transactionDepth > 0 }

    public func record(_ edit: TextEdit, now: TimeInterval = Date().timeIntervalSinceReferenceDate) {
        guard !isApplying else { return }
        redoGroups.removeAll()

        if transactionDepth > 0 {
            if let index = transactionGroupIndex, index < undoGroups.count {
                undoGroups[index].edits.append(edit)
                undoGroups[index].lastEditTime = now
            } else {
                undoGroups.append(UndoGroup(id: nextGroupID, edits: [edit],
                                            lastEditTime: now, isOpen: false))
                nextGroupID &+= 1
                transactionGroupIndex = undoGroups.count - 1
                trimHistory()
            }
            return
        }

        // `isNewline` on the Character rather than contains("\n"): a pasted "\r\n" is
        // one Character and would slip past a substring search.
        let isTyping = edit.removed.isEmpty
            && edit.inserted.count == 1
            && !(edit.inserted.first?.isNewline ?? false)

        if isTyping,
           var last = undoGroups.last,
           last.isOpen,
           now - last.lastEditTime <= coalesceInterval,
           let previous = last.edits.last,
           previous.offset + previous.inserted.utf8.count == edit.offset,
           previous.removed.isEmpty {
            last.edits.append(edit)
            last.lastEditTime = now
            undoGroups[undoGroups.count - 1] = last
            return
        }

        breakCoalescing()
        undoGroups.append(UndoGroup(id: nextGroupID, edits: [edit], lastEditTime: now, isOpen: isTyping))
        nextGroupID &+= 1
        trimHistory()
    }

    /// Pops an undo group and hands its edits (already reversed) to `apply`.
    /// Returns the caret position to restore.
    @discardableResult
    public func undo(_ apply: (TextEdit) -> Void) -> Position? {
        guard let group = undoGroups.popLast() else { return nil }
        isApplying = true
        for edit in group.edits.reversed() { apply(edit) }
        isApplying = false
        redoGroups.append(group)
        return group.caretBefore
    }

    @discardableResult
    public func redo(_ apply: (TextEdit) -> Void) -> Position? {
        guard let group = redoGroups.popLast() else { return nil }
        isApplying = true
        for edit in group.edits { apply(edit) }
        isApplying = false
        var reopened = group
        reopened.isOpen = false
        undoGroups.append(reopened)
        return group.caretAfter
    }
}
