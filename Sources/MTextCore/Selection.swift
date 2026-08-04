import Foundation

/// One selection range. `anchor` is where the drag started, `head` is the caret —
/// keeping them distinct (rather than start/end) is what makes shift-arrow extend
/// in the direction the user is moving.
public struct Region: Hashable {
    public var anchor: Position
    public var head: Position
    /// Remembered column for vertical movement, so moving down through a short
    /// line and back out returns to the original column.
    public var goalColumn: Int?

    public init(anchor: Position, head: Position, goalColumn: Int? = nil) {
        self.anchor = anchor
        self.head = head
        self.goalColumn = goalColumn
    }

    public init(caret: Position) {
        self.init(anchor: caret, head: caret)
    }

    public var start: Position { min(anchor, head) }
    public var end: Position { max(anchor, head) }
    public var isEmpty: Bool { anchor == head }
    public var isReversed: Bool { head < anchor }

    public func contains(_ position: Position) -> Bool {
        position >= start && position <= end
    }

    /// Sublime's rule: ranges that genuinely overlap merge, and a bare caret
    /// touching a selection merges into it, but two adjacent selections do not.
    public func shouldMerge(with other: Region) -> Bool {
        if start < other.end && other.start < end { return true }
        if end == other.start || other.end == start {
            return isEmpty || other.isEmpty
        }
        return false
    }

    /// Union, keeping this region's direction.
    public func merged(with other: Region) -> Region {
        let lo = min(start, other.start)
        let hi = max(end, other.end)
        return isReversed
            ? Region(anchor: hi, head: lo)
            : Region(anchor: lo, head: hi)
    }

    /// Equality ignores `goalColumn` — it is a movement hint, not part of identity.
    public static func == (a: Region, b: Region) -> Bool {
        a.anchor == b.anchor && a.head == b.head
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(anchor)
        hasher.combine(head)
    }
}

/// An ordered set of non-overlapping regions. Always contains at least one.
///
/// Every editing command maps over `regions`; the invariants here (sorted,
/// disjoint) are what let edits be applied back-to-front without offset fixups.
public struct Selection: Equatable {

    public private(set) var regions: [Region]
    /// Index of the region that drives single-caret behaviour (scroll-to, find start).
    public private(set) var primaryIndex: Int

    public init(_ region: Region) {
        regions = [region]
        primaryIndex = 0
    }

    public init(caret: Position) {
        self.init(Region(caret: caret))
    }

    public init(regions: [Region], primaryIndex: Int = 0) {
        let source = regions.isEmpty ? [Region(caret: .zero)] : regions
        self.regions = source
        self.primaryIndex = max(0, min(primaryIndex, source.count - 1))
        normalize()
    }

    public var count: Int { regions.count }
    public var isMultiple: Bool { regions.count > 1 }
    public var hasSelectedText: Bool { regions.contains { !$0.isEmpty } }

    public var primary: Region {
        get { regions[max(0, min(primaryIndex, regions.count - 1))] }
        set {
            regions[max(0, min(primaryIndex, regions.count - 1))] = newValue
            normalize(keeping: newValue)
        }
    }

    public subscript(index: Int) -> Region { regions[index] }

    /// Collapses to a single caret at the primary head.
    public mutating func collapseToPrimary() {
        let head = primary.head
        regions = [Region(caret: head)]
        primaryIndex = 0
    }

    public mutating func add(_ region: Region) {
        regions.append(region)
        primaryIndex = regions.count - 1
        normalize(keeping: region)
    }

    public mutating func replaceAll(with newRegions: [Region], primary: Region? = nil) {
        regions = newRegions.isEmpty ? [Region(caret: .zero)] : newRegions
        primaryIndex = regions.count - 1
        normalize(keeping: primary)
    }

    /// Applies `transform` to every region, then re-sorts and merges.
    public mutating func map(_ transform: (Region) -> Region) {
        let mapped = regions.map(transform)
        let primaryRegion = mapped[max(0, min(primaryIndex, mapped.count - 1))]
        regions = mapped
        normalize(keeping: primaryRegion)
    }

    /// Sorts by start position and merges overlapping regions. `keeping` names the
    /// region that should remain primary once indices shift.
    public mutating func normalize(keeping preferred: Region? = nil) {
        guard !regions.isEmpty else {
            regions = [Region(caret: .zero)]
            primaryIndex = 0
            return
        }
        let target = preferred ?? regions[max(0, min(primaryIndex, regions.count - 1))]
        let targetWasReversed = target.isReversed

        let sorted = regions.sorted {
            $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end
        }
        var merged: [Region] = []
        for region in sorted {
            if let last = merged.last, last.shouldMerge(with: region) {
                merged[merged.count - 1] = last.merged(with: region)
            } else {
                merged.append(region)
            }
        }
        regions = merged
        // Identity first: `contains` is inclusive at both ends, so a reversed region
        // whose head touches its neighbour would otherwise hand the primary away.
        primaryIndex = merged.firstIndex(of: target)
            ?? merged.firstIndex { $0.contains(target.head) && $0.isReversed == targetWasReversed }
            ?? merged.firstIndex { $0.contains(target.head) }
            ?? merged.count - 1
    }
}
