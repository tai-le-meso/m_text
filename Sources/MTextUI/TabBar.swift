import AppKit

/// The row of document tabs above the editor, Sublime-style: click to switch, click the
/// × to close, drag to reorder, a trailing **+** to open a new tab. Owns no document
/// state — it only draws `items` and reports intent through `delegate`.
public protocol TabBarDelegate: AnyObject {
    func tabBar(_ bar: TabBar, didSelectTabAt index: Int)
    func tabBar(_ bar: TabBar, didCloseTabAt index: Int)
    func tabBar(_ bar: TabBar, didMoveTabAt index: Int, to newIndex: Int)
    func tabBarDidRequestNewTab(_ bar: TabBar)
}

public final class TabBar: NSView {

    public struct Item {
        public var title: String
        public var isDirty: Bool
        public init(title: String, isDirty: Bool) {
            self.title = title
            self.isDirty = isDirty
        }
    }

    public weak var delegate: TabBarDelegate?

    public var items: [Item] = [] { didSet { rebuildLayout() } }
    public var selectedIndex: Int = 0 { didSet { needsDisplay = true } }

    public static let preferredHeight: CGFloat = 32

    private let minTabWidth: CGFloat = 110
    private let maxTabWidth: CGFloat = 220
    private let closeButtonSize: CGFloat = 14
    private let newTabButtonWidth: CGFloat = 28

    /// Frame of each tab (in the bar's own bounds), rebuilt whenever `items` or the
    /// bar's width changes. Index-parallel with `items`.
    private var tabFrames: [NSRect] = []
    private var newTabButtonFrame: NSRect = .zero

    private var hoveredIndex: Int?
    private var hoveredCloseIndex: Int?
    private var trackingAreas_: [NSTrackingArea] = []

    // Drag-to-reorder state.
    private var draggingIndex: Int?
    private var dragOriginX: CGFloat = 0

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public override var isFlipped: Bool { true }

    /// Same opt-out, same reason as `EditorView` — see the comment there.
    public override class var isCompatibleWithResponsiveScrolling: Bool { false }
    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: TabBar.preferredHeight)
    }

    /// `TabBar` is hosted as a horizontal scroll view's `documentView` (so a tab row
    /// wider than the window can scroll rather than clip), which means its size is set
    /// directly by `rebuildLayout` rather than by Auto Layout constraints on itself. The
    /// available width to shrink-to-fit against has to come from the *clip view*'s
    /// bounds — the viewport — not from this view's own (self-determined) frame, or the
    /// computation would feed back into itself. `resize(withOldSuperviewSize:)` only
    /// fires for autoresizing-mask-based superviews, which a scroll view's clip view is
    /// not, so the clip view's bounds-change notification is used instead, the same
    /// pattern `EditorView` uses for its own scroll view.
    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard let clip = superview as? NSClipView else { return }
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: clip)
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(clipBoundsChanged),
                                               name: NSView.boundsDidChangeNotification,
                                               object: clip)
        rebuildLayout()
    }

    @objc private func clipBoundsChanged() {
        rebuildLayout()
    }

    // MARK: - Layout

    /// Tabs shrink to fit the available width down to `minTabWidth`; once every tab is
    /// already at the minimum, the bar grows wider than its superview and relies on
    /// being hosted in a horizontal scroll view for overflow.
    private func rebuildLayout() {
        // Tab frames are about to be recomputed (a tab closed, reordered, or the row
        // resized) — a hover/close-hover index left over from the old layout could keep
        // highlighting the wrong tab until the pointer next moves, so drop it now.
        hoveredIndex = nil
        hoveredCloseIndex = nil
        defer { needsDisplay = true; updateTrackingRects() }
        guard !items.isEmpty else {
            tabFrames = []
            newTabButtonFrame = NSRect(x: 4, y: 4, width: newTabButtonWidth, height: bounds.height - 8)
            setFrameSizeIfNeeded(NSSize(width: max(bounds.width, newTabButtonWidth + 8), height: TabBar.preferredHeight))
            return
        }

        let available = max(superview?.bounds.width ?? bounds.width, minTabWidth)
        let usableForTabs = max(minTabWidth, available - newTabButtonWidth - 8)
        let fitWidth = usableForTabs / CGFloat(items.count)
        let width = min(maxTabWidth, max(minTabWidth, fitWidth))

        var frames: [NSRect] = []
        var x: CGFloat = 0
        for _ in items {
            frames.append(NSRect(x: x, y: 0, width: width, height: TabBar.preferredHeight))
            x += width
        }
        tabFrames = frames
        newTabButtonFrame = NSRect(x: x + 4, y: 4, width: newTabButtonWidth, height: TabBar.preferredHeight - 8)

        let totalWidth = max(available, x + newTabButtonWidth + 8)
        setFrameSizeIfNeeded(NSSize(width: totalWidth, height: TabBar.preferredHeight))
    }

    private func setFrameSizeIfNeeded(_ size: NSSize) {
        if frame.size != size { setFrameSize(size) }
    }

    // MARK: - Hit testing helpers

    private func closeRect(for tabFrame: NSRect) -> NSRect {
        NSRect(x: tabFrame.maxX - closeButtonSize - 8,
              y: tabFrame.midY - closeButtonSize / 2,
              width: closeButtonSize,
              height: closeButtonSize)
    }

    private func index(at point: NSPoint) -> Int? {
        tabFrames.firstIndex { $0.contains(point) }
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()

        for (index, item) in items.enumerated() where index < tabFrames.count {
            drawTab(item, frame: tabFrames[index], index: index)
        }

        drawNewTabButton()

        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    private func drawTab(_ item: Item, frame: NSRect, index: Int) {
        let isSelected = index == selectedIndex
        let isHovered = index == hoveredIndex

        let background: NSColor = isSelected ? .textBackgroundColor
            : (isHovered ? NSColor.textBackgroundColor.withAlphaComponent(0.5) : .windowBackgroundColor)
        background.setFill()
        frame.fill()

        NSColor.separatorColor.setFill()
        NSRect(x: frame.maxX - 1, y: 0, width: 1, height: frame.height).fill()
        if isSelected {
            (NSColor.controlAccentColor).setFill()
            NSRect(x: frame.minX, y: frame.height - 2, width: frame.width, height: 2).fill()
        }

        let showsCloseButton = isSelected || isHovered
        let trailingReserved: CGFloat = closeButtonSize + 12
        let titleRect = NSRect(x: frame.minX + 10, y: 0,
                               width: max(0, frame.width - 10 - trailingReserved),
                               height: frame.height)

        let titleColor: NSColor = isSelected ? .labelColor : .secondaryLabelColor
        // A paragraph style with tail-truncation, rather than NSString's
        // `.truncatesLastVisibleLine` option, which only engages line-breaking together
        // with `.usesLineFragmentOrigin` — without it the title would draw unclipped
        // and bleed past the tab's edge instead of ellipsising.
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: isSelected ? .medium : .regular),
            .foregroundColor: titleColor,
            .paragraphStyle: paragraphStyle,
        ]
        let title = NSAttributedString(string: item.title, attributes: attributes)
        let size = title.size()
        let textRect = NSRect(x: titleRect.minX,
                              y: (frame.height - size.height) / 2,
                              width: titleRect.width,
                              height: size.height)
        title.draw(in: textRect)

        if showsCloseButton {
            drawCloseButton(in: closeRect(for: frame), hovered: index == hoveredCloseIndex)
        } else if item.isDirty {
            drawDirtyDot(in: closeRect(for: frame))
        }
    }

    private func drawCloseButton(in rect: NSRect, hovered: Bool) {
        if hovered {
            NSColor.tertiaryLabelColor.withAlphaComponent(0.3).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: -2, dy: -2)).fill()
        }
        let path = NSBezierPath()
        let inset = rect.insetBy(dx: 3, dy: 3)
        path.move(to: NSPoint(x: inset.minX, y: inset.minY))
        path.line(to: NSPoint(x: inset.maxX, y: inset.maxY))
        path.move(to: NSPoint(x: inset.maxX, y: inset.minY))
        path.line(to: NSPoint(x: inset.minX, y: inset.maxY))
        path.lineWidth = 1.2
        NSColor.secondaryLabelColor.setStroke()
        path.stroke()
    }

    private func drawDirtyDot(in rect: NSRect) {
        let size: CGFloat = 7
        let dot = NSRect(x: rect.midX - size / 2, y: rect.midY - size / 2, width: size, height: size)
        NSColor.secondaryLabelColor.setFill()
        NSBezierPath(ovalIn: dot).fill()
    }

    private func drawNewTabButton() {
        let frame = newTabButtonFrame
        guard frame.width > 0 else { return }
        let hovered = hoveredIndex == TabBar.newTabSentinel
        if hovered {
            NSColor.tertiaryLabelColor.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: frame, xRadius: 4, yRadius: 4).fill()
        }
        let path = NSBezierPath()
        let inset = frame.insetBy(dx: 5, dy: 5)
        path.move(to: NSPoint(x: inset.midX, y: inset.minY))
        path.line(to: NSPoint(x: inset.midX, y: inset.maxY))
        path.move(to: NSPoint(x: inset.minX, y: inset.midY))
        path.line(to: NSPoint(x: inset.maxX, y: inset.midY))
        path.lineWidth = 1.4
        NSColor.secondaryLabelColor.setStroke()
        path.stroke()
    }

    /// Not a real tab index — reuses `hoveredIndex` to track the **+** button's hover
    /// state too, since only one of a tab/the button can be hovered at a time.
    private static let newTabSentinel = -2

    // MARK: - Mouse

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if newTabButtonFrame.contains(point) {
            delegate?.tabBarDidRequestNewTab(self)
            return
        }
        guard let index = index(at: point) else { return }

        if closeRect(for: tabFrames[index]).contains(point), index == selectedIndex || index == hoveredIndex {
            delegate?.tabBar(self, didCloseTabAt: index)
            return
        }

        selectedIndex = index
        delegate?.tabBar(self, didSelectTabAt: index)
        draggingIndex = index
        dragOriginX = point.x
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let dragging = draggingIndex, tabFrames.indices.contains(dragging) else { return }
        let point = convert(event.locationInWindow, from: nil)

        // Only reorder once the pointer crosses into a neighbouring tab's midpoint, so a
        // small jitter while clicking doesn't shuffle tabs.
        if point.x < dragOriginX, dragging > 0 {
            let target = dragging - 1
            if point.x < tabFrames[target].midX {
                delegate?.tabBar(self, didMoveTabAt: dragging, to: target)
                items.swapAt(dragging, target)
                selectedIndex = target
                draggingIndex = target
                dragOriginX = point.x
            }
        } else if point.x > dragOriginX, dragging < items.count - 1 {
            let target = dragging + 1
            if point.x > tabFrames[target].midX {
                delegate?.tabBar(self, didMoveTabAt: dragging, to: target)
                items.swapAt(dragging, target)
                selectedIndex = target
                draggingIndex = target
                dragOriginX = point.x
            }
        }
    }

    public override func mouseUp(with event: NSEvent) {
        draggingIndex = nil
    }

    // MARK: - Hover tracking

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateTrackingRects()
    }

    private func updateTrackingRects() {
        for area in trackingAreas_ { removeTrackingArea(area) }
        trackingAreas_.removeAll()

        var rects = tabFrames
        if newTabButtonFrame.width > 0 { rects.append(newTabButtonFrame) }
        for rect in rects {
            let area = NSTrackingArea(rect: rect,
                                      options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
                                      owner: self,
                                      userInfo: nil)
            addTrackingArea(area)
            trackingAreas_.append(area)
        }
    }

    public override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let newHover: Int? = newTabButtonFrame.contains(point) ? TabBar.newTabSentinel : index(at: point)
        let newCloseHover: Int?
        if let newHover, newHover >= 0, closeRect(for: tabFrames[newHover]).contains(point) {
            newCloseHover = newHover
        } else {
            newCloseHover = nil
        }
        if newHover != hoveredIndex || newCloseHover != hoveredCloseIndex {
            hoveredIndex = newHover
            hoveredCloseIndex = newCloseHover
            needsDisplay = true
        }
    }

    public override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
        hoveredCloseIndex = nil
        needsDisplay = true
    }
}
