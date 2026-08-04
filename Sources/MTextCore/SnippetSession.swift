import Foundation

/// Live state of a snippet the user is currently filling in (T91).
///
/// Tracks every tab stop as an **absolute UTF-8 byte range** in the document, matching
/// `TextDocument.byteOffset(of:)` — the same coordinate space multi-cursor editing already
/// rebases in, so snippet ranges survive edits the same way selections do.
///
/// Deliberately in `MTextCore` and free of AppKit: all the fiddly parts (rebasing ranges
/// across an edit, deciding when an edit has invalidated the session, computing mirror
/// updates) are pure offset arithmetic and are unit tested. `EditorView` only applies the
/// edits this hands back.
public final class SnippetSession {

    /// One stop, with every place it appears. `ranges[0]` is where the caret goes; the
    /// rest are mirrors that follow whatever is typed there.
    public struct Stop: Equatable {
        public let index: Int
        public var ranges: [Range<Int>]

        public init(index: Int, ranges: [Range<Int>]) {
            self.index = index
            self.ranges = ranges
        }

        public var primary: Range<Int> { ranges[0] }
    }

    public private(set) var stops: [Stop]
    /// Position within `stops`, not the stop's own number.
    public private(set) var position: Int
    public private(set) var isFinished = false

    public var currentStop: Stop? {
        guard !isFinished, stops.indices.contains(position) else { return nil }
        return stops[position]
    }

    /// The full span the snippet occupies, for deciding whether an edit is still "inside".
    public var span: Range<Int> {
        let lower = stops.flatMap(\.ranges).map(\.lowerBound).min() ?? origin
        let upper = stops.flatMap(\.ranges).map(\.upperBound).max() ?? origin
        return min(lower, origin) ..< max(upper, origin + bodyByteLength)
    }

    private let origin: Int
    private let bodyByteLength: Int

    /// Converts the expansion's *character* offsets into absolute byte offsets. Returns nil
    /// for a snippet with nothing to fill in — a body of pure literal text with only the
    /// synthesized `$0` is just an insertion, not a session worth tracking.
    public init?(expansion: SnippetExpansion, originByteOffset: Int) {
        let characters = Array(expansion.text)
        /// UTF-8 length of the first `count` characters — the snippet's own text is the
        /// only thing between `origin` and any stop, so prefix length is the conversion.
        func byteOffset(ofCharacter count: Int) -> Int {
            originByteOffset + String(characters.prefix(count)).utf8.count
        }

        let converted = expansion.stops.map { stop in
            Stop(index: stop.index,
                 ranges: stop.ranges.map { byteOffset(ofCharacter: $0.lowerBound) ..< byteOffset(ofCharacter: $0.upperBound) })
        }
        // Only `$0` means there is nowhere to Tab to.
        guard converted.contains(where: { $0.index != 0 }) else { return nil }

        self.stops = converted
        self.origin = originByteOffset
        self.bodyByteLength = expansion.text.utf8.count
        self.position = 0
    }

    // MARK: - Navigation

    /// Tab. Returns the stop to select, or nil when the snippet is done.
    @discardableResult
    public func advance() -> Stop? {
        guard !isFinished else { return nil }
        guard position + 1 < stops.count else {
            isFinished = true
            return nil
        }
        position += 1
        return stops[position]
    }

    /// Shift-Tab. Stays put at the first stop rather than ending the session, so an
    /// accidental Shift-Tab doesn't throw the snippet away.
    @discardableResult
    public func retreat() -> Stop? {
        guard !isFinished, position > 0 else { return currentStop }
        position -= 1
        return stops[position]
    }

    public func finish() {
        isFinished = true
    }

    // MARK: - Edits

    /// Rebases every range across an edit that replaced `replaced` with `newByteLength`
    /// bytes. Returns false when the edit invalidated the session — the caller should then
    /// end it rather than track ranges it can no longer trust.
    ///
    /// An edit *straddling* a stop boundary is what invalidates: the user has selected
    /// across the edge of a placeholder and replaced it, so there is no longer a coherent
    /// answer for where that stop begins and ends.
    @discardableResult
    public func rebase(replaced: Range<Int>, newByteLength: Int) -> Bool {
        guard !isFinished else { return false }
        let delta = newByteLength - replaced.count

        // Wholly outside the snippet: nothing to do beyond shifting, and an edit *before*
        // the snippet is perfectly normal (another cursor, an external change).
        if replaced.lowerBound > span.upperBound { return true }

        for stopIndex in stops.indices {
            for rangeIndex in stops[stopIndex].ranges.indices {
                let range = stops[stopIndex].ranges[rangeIndex]
                if range.upperBound <= replaced.lowerBound {
                    continue                                   // entirely before the edit
                } else if range.lowerBound >= replaced.upperBound {
                    stops[stopIndex].ranges[rangeIndex] =
                        range.lowerBound + delta ..< range.upperBound + delta
                } else if replaced.lowerBound >= range.lowerBound
                            && replaced.upperBound <= range.upperBound {
                    stops[stopIndex].ranges[rangeIndex] =
                        range.lowerBound ..< range.upperBound + delta   // edit inside: grow
                } else {
                    isFinished = true                          // straddles a boundary
                    return false
                }
            }
        }
        return true
    }

    /// Edits needed to make every mirror of the current stop match `activeText`, **ordered
    /// back to front** so applying them in order doesn't invalidate the ones still to come.
    ///
    /// Internal ranges are updated as if the caller applies all of them, which it must.
    public func mirrorEdits(activeText: String) -> [(range: Range<Int>, replacement: String)] {
        guard let stop = currentStop, stop.ranges.count > 1 else { return [] }
        let newLength = activeText.utf8.count

        // Every mirror except the primary, which is what the user is typing in.
        let targets = stop.ranges.enumerated()
            .filter { $0.offset != 0 }
            .map { $0.element }
            .sorted { $0.lowerBound > $1.lowerBound }

        // Every mirror is rewritten unconditionally rather than only when its byte length
        // differs: same-length-but-different text ("abc" → "xyz") is the common case and
        // a length check would silently skip it.
        let edits = targets.map { (range: $0, replacement: activeText) }
        // Apply the same rebasing the caller's edits will cause, back to front.
        for edit in edits {
            _ = rebaseForMirror(replaced: edit.range, newByteLength: newLength)
        }
        return edits
    }

    /// Like `rebase`, but never invalidates: a mirror rewrite is an edit this session is
    /// itself performing, so an exact-boundary replacement is expected rather than
    /// suspicious.
    private func rebaseForMirror(replaced: Range<Int>, newByteLength: Int) -> Bool {
        let delta = newByteLength - replaced.count
        for stopIndex in stops.indices {
            for rangeIndex in stops[stopIndex].ranges.indices {
                let range = stops[stopIndex].ranges[rangeIndex]
                if range == replaced {
                    stops[stopIndex].ranges[rangeIndex] = range.lowerBound ..< range.lowerBound + newByteLength
                } else if range.upperBound <= replaced.lowerBound {
                    continue
                } else if range.lowerBound >= replaced.upperBound {
                    stops[stopIndex].ranges[rangeIndex] =
                        range.lowerBound + delta ..< range.upperBound + delta
                } else if replaced.lowerBound >= range.lowerBound
                            && replaced.upperBound <= range.upperBound {
                    stops[stopIndex].ranges[rangeIndex] =
                        range.lowerBound ..< range.upperBound + delta
                }
            }
        }
        return true
    }
}
