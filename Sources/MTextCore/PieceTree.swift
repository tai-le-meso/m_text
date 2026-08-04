import Foundation

// MARK: - Piece

/// A slice of one of the immutable byte buffers. Offsets are UTF-8 bytes.
struct Piece {
    let bufferIndex: Int
    /// Byte offset of this piece inside its buffer.
    let start: Int
    let length: Int
    /// Offsets of `\n` bytes, relative to `start`, ascending.
    let newlines: [Int]

    /// Splits at a relative byte offset (0 < rel < length).
    func split(at rel: Int) -> (Piece, Piece) {
        let cut = lowerBound(newlines, rel)
        let leftNewlines = Array(newlines[..<cut])
        var rightNewlines = [Int]()
        rightNewlines.reserveCapacity(newlines.count - cut)
        for i in cut ..< newlines.count { rightNewlines.append(newlines[i] - rel) }
        return (
            Piece(bufferIndex: bufferIndex, start: start, length: rel, newlines: leftNewlines),
            Piece(bufferIndex: bufferIndex, start: start + rel, length: length - rel, newlines: rightNewlines)
        )
    }
}

/// Index of the first element >= `value`.
@inline(__always)
func lowerBound(_ a: [Int], _ value: Int) -> Int {
    var lo = 0
    var hi = a.count
    while lo < hi {
        let mid = (lo + hi) / 2
        if a[mid] < value { lo = mid + 1 } else { hi = mid }
    }
    return lo
}

// MARK: - Rope node

/// Immutable node. Immutability is what makes snapshots O(1) and safe to hand
/// to background workers (highlighter, search) while the main thread keeps editing.
final class RopeNode {
    let left: RopeNode?
    let right: RopeNode?
    let piece: Piece?
    let byteCount: Int
    let newlineCount: Int
    let height: Int

    init(piece: Piece) {
        self.left = nil
        self.right = nil
        self.piece = piece
        self.byteCount = piece.length
        self.newlineCount = piece.newlines.count
        self.height = 1
    }

    init(left: RopeNode, right: RopeNode) {
        self.left = left
        self.right = right
        self.piece = nil
        self.byteCount = left.byteCount + right.byteCount
        self.newlineCount = left.newlineCount + right.newlineCount
        self.height = max(left.height, right.height) + 1
    }
}

// MARK: - PieceTree

/// A piece table stored in an AVL-balanced rope, indexed by UTF-8 byte offset.
///
/// - insert / delete / substring / line lookup: O(log n)
/// - `PieceTree` is a value type, so `let snap = tree` is a cheap immutable snapshot.
///   Buffers are copy-on-write; only the currently-growing add chunk can ever be
///   duplicated, never the (potentially huge) original buffer.
///
/// Snapshots must be *taken* on the owning thread; once taken they can be read
/// concurrently while the original keeps being mutated.
public struct PieceTree {

    static let chunkSize = 64 * 1024

    /// buffers[0] is the original file content; the rest are append-only add chunks.
    private var buffers: [[UInt8]]
    private var root: RopeNode?

    // MARK: Construction

    public init() {
        buffers = [[]]
        root = nil
    }

    public init(bytes: [UInt8]) {
        buffers = [bytes]
        root = PieceTree.makeNodes(bufferIndex: 0, bufferStart: 0, bytes: bytes)
    }

    public init(text: String) {
        self.init(bytes: Array(text.utf8))
    }

    // MARK: Metrics

    public var byteCount: Int { root?.byteCount ?? 0 }
    public var isEmpty: Bool { byteCount == 0 }
    /// A document always has at least one line.
    public var lineCount: Int { (root?.newlineCount ?? 0) + 1 }

    // MARK: Editing

    public mutating func insert(_ text: String, at offset: Int) {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return }
        let clamped = max(0, min(offset, byteCount))
        let (bufferIndex, bufferStart) = appendToAddBuffer(bytes)
        guard let inserted = PieceTree.makeNodes(bufferIndex: bufferIndex,
                                                 bufferStart: bufferStart,
                                                 bytes: bytes) else { return }
        let (l, r) = PieceTree.split(root, clamped)
        root = PieceTree.concat(PieceTree.concat(l, inserted), r)
    }

    public mutating func delete(offset: Int, length: Int) {
        guard length > 0, offset < byteCount else { return }
        let start = max(0, offset)
        // A negative offset shortens the range rather than shifting it.
        let len = min(length + min(0, offset), byteCount - start)
        guard len > 0 else { return }
        let (a, rest) = PieceTree.split(root, start)
        let (_, c) = PieceTree.split(rest, len)
        root = PieceTree.concat(a, c)
    }

    public mutating func replace(offset: Int, length: Int, with text: String) {
        delete(offset: offset, length: length)
        insert(text, at: offset)
    }

    // MARK: Reading

    public func bytes(offset: Int, length: Int) -> [UInt8] {
        var out = [UInt8]()
        guard length > 0, offset < byteCount else { return out }
        let start = max(0, offset)
        let len = min(length + min(0, offset), byteCount - start)
        guard len > 0 else { return out }
        out.reserveCapacity(len)
        PieceTree.collect(root, start, len, buffers, &out)
        return out
    }

    public func text(offset: Int, length: Int) -> String {
        String(decoding: bytes(offset: offset, length: length), as: UTF8.self)
    }

    public var text: String { text(offset: 0, length: byteCount) }

    // MARK: Line index

    /// Byte offset of the first character of `line` (0-based).
    public func offsetOfLine(_ line: Int) -> Int {
        if line <= 0 { return 0 }
        let k = line - 1
        guard let root, k < root.newlineCount else { return byteCount }
        return PieceTree.offsetOfNewline(root, k) + 1
    }

    /// 0-based line containing `offset`, i.e. the number of newlines strictly before it.
    public func lineOfOffset(_ offset: Int) -> Int {
        guard let root else { return 0 }
        return PieceTree.countNewlines(root, before: max(0, min(offset, root.byteCount)))
    }

    /// Byte range of `line`, excluding its trailing newline.
    public func lineRange(_ line: Int) -> (start: Int, length: Int) {
        let start = offsetOfLine(line)
        let end: Int
        if line + 1 < lineCount {
            end = offsetOfLine(line + 1) - 1 // drop the '\n'
        } else {
            end = byteCount
        }
        return (start, max(0, end - start))
    }

    public func lineText(_ line: Int) -> String {
        guard line >= 0, line < lineCount else { return "" }
        let r = lineRange(line)
        return text(offset: r.start, length: r.length)
    }

    // MARK: - Add buffer

    private mutating func appendToAddBuffer(_ bytes: [UInt8]) -> (bufferIndex: Int, start: Int) {
        let last = buffers.count - 1
        // Never append to buffers[0] (the original file image).
        if last >= 1, buffers[last].count + bytes.count <= PieceTree.chunkSize {
            let start = buffers[last].count
            buffers[last].append(contentsOf: bytes)
            return (last, start)
        }
        buffers.append(bytes)
        return (buffers.count - 1, 0)
    }

    // MARK: - Node construction

    /// Splits `bytes` into leaf-sized pieces referencing `bufferIndex` starting at
    /// `bufferStart`, and builds a perfectly balanced tree over them.
    private static func makeNodes(bufferIndex: Int, bufferStart: Int, bytes: [UInt8]) -> RopeNode? {
        if bytes.isEmpty { return nil }
        var pieces = [Piece]()
        var i = 0
        while i < bytes.count {
            var end = min(i + chunkSize, bytes.count)
            // Never split in the middle of a UTF-8 sequence.
            while end < bytes.count && (bytes[end] & 0xC0) == 0x80 { end += 1 }
            var newlines = [Int]()
            var j = i
            while j < end {
                if bytes[j] == 0x0A { newlines.append(j - i) }
                j += 1
            }
            pieces.append(Piece(bufferIndex: bufferIndex,
                                start: bufferStart + i,
                                length: end - i,
                                newlines: newlines))
            i = end
        }
        return buildBalanced(pieces, 0, pieces.count)
    }

    private static func buildBalanced(_ p: [Piece], _ lo: Int, _ hi: Int) -> RopeNode? {
        if lo >= hi { return nil }
        if hi - lo == 1 { return RopeNode(piece: p[lo]) }
        let mid = (lo + hi) / 2
        guard let l = buildBalanced(p, lo, mid), let r = buildBalanced(p, mid, hi) else { return nil }
        return RopeNode(left: l, right: r)
    }

    // MARK: - AVL join / concat / split

    private static func join(_ l: RopeNode, _ r: RopeNode) -> RopeNode {
        RopeNode(left: l, right: r)
    }

    /// One rebalancing step; assumes |height(l) - height(r)| <= 2.
    private static func balanced(_ l: RopeNode, _ r: RopeNode) -> RopeNode {
        let bf = l.height - r.height
        if bf > 1, let ll = l.left, let lr = l.right {
            if ll.height >= lr.height {
                return join(ll, join(lr, r))
            }
            if let lrl = lr.left, let lrr = lr.right {
                return join(join(ll, lrl), join(lrr, r))
            }
            return join(l, r)
        }
        if bf < -1, let rl = r.left, let rr = r.right {
            if rr.height >= rl.height {
                return join(join(l, rl), rr)
            }
            if let rll = rl.left, let rlr = rl.right {
                return join(join(l, rll), join(rlr, rr))
            }
            return join(l, r)
        }
        return join(l, r)
    }

    static func concat(_ l: RopeNode?, _ r: RopeNode?) -> RopeNode? {
        guard let l else { return r }
        guard let r else { return l }
        if l.height > r.height + 1 {
            guard let ll = l.left, let lr = l.right else { return balanced(l, r) }
            guard let merged = concat(lr, r) else { return l }
            return balanced(ll, merged)
        }
        if r.height > l.height + 1 {
            guard let rl = r.left, let rr = r.right else { return balanced(l, r) }
            guard let merged = concat(l, rl) else { return r }
            return balanced(merged, rr)
        }
        return join(l, r)
    }

    static func split(_ n: RopeNode?, _ offset: Int) -> (RopeNode?, RopeNode?) {
        guard let n else { return (nil, nil) }
        if offset <= 0 { return (nil, n) }
        if offset >= n.byteCount { return (n, nil) }
        if let piece = n.piece {
            let (a, b) = piece.split(at: offset)
            return (RopeNode(piece: a), RopeNode(piece: b))
        }
        guard let l = n.left, let r = n.right else { return (n, nil) }
        if offset < l.byteCount {
            let (a, b) = split(l, offset)
            return (a, concat(b, r))
        }
        if offset > l.byteCount {
            let (a, b) = split(r, offset - l.byteCount)
            return (concat(l, a), b)
        }
        return (l, r)
    }

    // MARK: - Traversals

    private static func collect(_ n: RopeNode?, _ offset: Int, _ length: Int,
                                _ buffers: [[UInt8]], _ out: inout [UInt8]) {
        guard let n, length > 0 else { return }
        if let p = n.piece {
            let s = max(0, offset)
            let e = min(n.byteCount, offset + length)
            if s < e {
                out.append(contentsOf: buffers[p.bufferIndex][(p.start + s) ..< (p.start + e)])
            }
            return
        }
        guard let l = n.left, let r = n.right else { return }
        if offset < l.byteCount {
            collect(l, offset, min(length, l.byteCount - offset), buffers, &out)
        }
        if offset + length > l.byteCount {
            let ro = max(0, offset - l.byteCount)
            let rl = offset + length - l.byteCount - ro
            collect(r, ro, rl, buffers, &out)
        }
    }

    /// Byte offset of the k-th (0-based) `\n` in the subtree.
    private static func offsetOfNewline(_ n: RopeNode, _ k: Int) -> Int {
        var node = n
        var index = k
        var offset = 0
        while true {
            if let p = node.piece {
                return offset + p.newlines[index]
            }
            guard let l = node.left, let r = node.right else { return offset }
            if index < l.newlineCount {
                node = l
            } else {
                index -= l.newlineCount
                offset += l.byteCount
                node = r
            }
        }
    }

    /// Number of `\n` bytes strictly before `offset` in the subtree.
    private static func countNewlines(_ n: RopeNode, before offset: Int) -> Int {
        var node = n
        var local = offset
        var count = 0
        while true {
            if let p = node.piece {
                return count + lowerBound(p.newlines, local)
            }
            guard let l = node.left, let r = node.right else { return count }
            if local <= l.byteCount {
                node = l
            } else {
                count += l.newlineCount
                local -= l.byteCount
                node = r
            }
        }
    }

    // MARK: - Diagnostics (used by tests)

    /// Verifies AVL balance and metric consistency. O(n) — tests only.
    public func validate() -> Bool {
        func check(_ n: RopeNode?) -> Bool {
            guard let n else { return true }
            if let p = n.piece {
                return n.byteCount == p.length
                    && n.newlineCount == p.newlines.count
                    && n.height == 1
                    && p.length > 0
            }
            guard let l = n.left, let r = n.right else { return false }
            if abs(l.height - r.height) > 2 { return false }
            if n.byteCount != l.byteCount + r.byteCount { return false }
            if n.newlineCount != l.newlineCount + r.newlineCount { return false }
            if n.height != max(l.height, r.height) + 1 { return false }
            return check(l) && check(r)
        }
        return check(root)
    }

    public var treeHeight: Int { root?.height ?? 0 }
}
