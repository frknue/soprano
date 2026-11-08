import AppKit

/// Lays out a tab row: the tabs in a horizontally scrolling strip, then the
/// `+` button. `+` follows the last tab while everything fits; once the tabs
/// overflow it is pinned at the trailing edge and the strip shrinks by its
/// width, so it never scrolls out of view.
@MainActor
enum TabRowLayout {
    /// `padding: 0 8px` around the row (Agents' tab strip); pills carry their
    /// own 4 pt gap.
    static let padding: CGFloat = 6

    /// Frames `tabs`, `addButton` (a direct subview of the row) and
    /// `scrollView` (whose document view is `container`) within the first
    /// `availableWidth` points of a row with a `rule`-high bottom hairline.
    /// Returns the strip's viewport width.
    static func layout(
        tabs: [(view: NSView, width: CGFloat)],
        addButton: NSView,
        scrollView: NSScrollView,
        container: NSView,
        availableWidth: CGFloat,
        rule: CGFloat,
        stripHeight: CGFloat,
        leadingInset: CGFloat = 0
    ) -> CGFloat {
        let addSize = addButton.frame.width > 0 ? addButton.frame.width : ShellTabStyle.height
        let addArea = padding + addSize + padding
        var x = padding
        for tab in tabs {
            tab.view.frame = NSRect(x: x, y: 0, width: tab.width, height: stripHeight)
            x += tab.width
        }
        let tabsEnd = x
        let room = max(0, availableWidth - leadingInset)
        let fits = tabsEnd + addArea <= room
        let viewportWidth = max(0, fits ? room : room - addArea)
        scrollView.frame = NSRect(x: leadingInset, y: rule, width: viewportWidth, height: stripHeight)
        container.setFrameSize(NSSize(width: max(viewportWidth, tabsEnd + padding), height: stripHeight))
        // Everything fits, so the strip is not scrolled and the inline
        // position is the same in the row's coordinates.
        addButton.frame = NSRect(
            x: leadingInset + (fits ? tabsEnd + padding - 2 : viewportWidth + padding),
            y: rule + floor((stripHeight - addSize) / 2),
            width: addSize,
            height: addSize
        )
        return viewportWidth
    }
}

/// A tab in the window and layout tab rows, in Soprano Agents' tab strip
/// look: a 24 pt `Radius.md` pill, `accent` when selected, `accent/60` under
/// the pointer, muted 12 pt text at rest.
/// Subclasses lay out their title and badges inside `pillRect`.
class TabPillButton: NSButton {
    /// Each tab row is 32 pt including its bottom hairline.
    static let rowHeight: CGFloat = 32
    static let pillHeight: CGFloat = ShellTabStyle.height
    /// Space between neighboring pills; each tab keeps half on either side.
    static let pillGap: CGFloat = 4
    static let leadingPadding: CGFloat = 8
    static let trailingPadding: CGFloat = 6
    /// Between the title, badges and close button.
    static let contentGap: CGFloat = 6
    /// Horizontal space a tab adds around its content.
    static let chromeWidth: CGFloat = pillGap + leadingPadding + trailingPadding
    /// Tab titles: Agents' `text-xs`.
    static let titleFont = Typography.ui(Typography.smallSize)
    static let selectedTitleFont = Typography.ui(Typography.smallSize, weight: .medium)
    var isSelectedTab = false {
        didSet {
            guard isSelectedTab != oldValue else { return }
            needsDisplay = true
            hoverStateDidChange()
        }
    }
    private(set) var isHovered = false
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Cell-backed properties below must follow the cell swap.
        cell = TabPillButtonCell()
        isBordered = false
        refusesFirstResponder = true
        wantsLayer = true
        setAccessibilityRole(.radioButton)
        PaletteCenter.shared.addObserver(self) { [weak self] _ in
            self?.needsDisplay = true
            self?.hoverStateDidChange()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The 24 pt pill, centered in the tab.
    var pillRect: NSRect {
        let height = min(Self.pillHeight, bounds.height)
        return NSRect(
            x: bounds.minX + Self.pillGap / 2,
            y: floor(bounds.midY - height / 2),
            width: max(0, bounds.width - Self.pillGap),
            height: height
        )
    }

    /// The title color for the tab's current state.
    var titleColor: NSColor {
        ShellTabStyle.textColor(isActive: isSelectedTab, isHovered: isHovered)
    }

    func applyPill() {
        needsDisplay = true
    }

    /// Called when the pointer enters or leaves the tab, or its selection
    /// changes.
    func hoverStateDidChange() {}

    override func draw(_ dirtyRect: NSRect) {
        ShellTabStyle.draw(isActive: isSelectedTab, isHovered: isHovered, in: pillRect)
        super.draw(dirtyRect)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { setHovered(false) }
    }

    private func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        needsDisplay = true
        hoverStateDidChange()
    }
}

/// Draws a tab's title in the rect its button computed, so badges and the
/// close button never crowd or clip it.
final class TabPillButtonCell: NSButtonCell {
    var titleFrame: NSRect = .zero

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        let height = ceil(attributedTitle.size().height)
        return NSRect(
            x: titleFrame.minX,
            y: floor(rect.midY - height / 2),
            width: max(0, titleFrame.width),
            height: height
        )
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        attributedTitle.draw(in: titleRect(forBounds: cellFrame))
    }
}
