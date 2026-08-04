import Foundation

/// An inline annotation shown *between* lines (T103) — Sublime calls these phantoms.
///
/// The canonical use is surfacing a build error under the line it refers to, which is what
/// `MainWindowController` wires them to; nothing about the model is specific to that.
public struct Phantom: Equatable {
    public enum Kind: Equatable {
        case error
        case warning
        case info
    }

    /// Document line this sits **below**.
    public let line: Int
    public let text: String
    public let kind: Kind
    /// Where it came from, so one source can clear its own phantoms without disturbing
    /// another's. A build clearing its errors must not remove a plugin's annotations.
    public let owner: String

    public init(line: Int, text: String, kind: Kind = .info, owner: String = "") {
        self.line = line
        self.text = text
        self.kind = kind
        self.owner = owner
    }
}

/// The phantoms attached to one document, and the row accounting that follows.
///
/// Phantoms **add** rows, exactly as folding removes them and wrapping adds them — so they
/// go through `RowMap` rather than being drawn as an overlay. An overlay would sit on top of
/// real text: the whole point is that the lines below move down to make room.
public struct PhantomSet: Equatable {

    public private(set) var phantoms: [Phantom] = []

    public init(_ phantoms: [Phantom] = []) {
        self.phantoms = phantoms.sorted { $0.line < $1.line }
    }

    public var isEmpty: Bool { phantoms.isEmpty }

    public mutating func add(_ phantom: Phantom) {
        phantoms.append(phantom)
        phantoms.sort { $0.line < $1.line }
    }

    /// Removes everything from one source, leaving other sources' phantoms alone.
    public mutating func removeAll(owner: String) {
        phantoms.removeAll { $0.owner == owner }
    }

    public mutating func removeAll() { phantoms.removeAll() }

    public func phantoms(onLine line: Int) -> [Phantom] {
        phantoms.filter { $0.line == line }
    }

    /// Extra rows each line needs, keyed by line — one row per phantom.
    ///
    /// One row each rather than measuring wrapped phantom text: an annotation that needs
    /// more than a line of explanation is better truncated than allowed to push the code
    /// off screen, and it keeps the row accounting exact without a second layout pass.
    public var rowsPerLine: [Int: Int] {
        var counts: [Int: Int] = [:]
        for phantom in phantoms { counts[phantom.line, default: 0] += 1 }
        return counts
    }

    /// Shifts phantoms to follow an edit, dropping any whose line was deleted.
    ///
    /// Same rule `FoldSet.adjust` follows: an annotation whose line is gone has nothing left
    /// to annotate, so it goes rather than pointing at unrelated text.
    public mutating func adjust(afterEditAt fromLine: Int, linesDelta: Int) {
        guard linesDelta != 0 else { return }
        phantoms = phantoms.compactMap { phantom in
            guard phantom.line >= fromLine else { return phantom }
            let line = phantom.line + linesDelta
            guard line >= 0 else { return nil }
            return Phantom(line: line, text: phantom.text, kind: phantom.kind, owner: phantom.owner)
        }
        .sorted { $0.line < $1.line }
    }
}
