import AppKit

/// Lays out a tab row: the tabs in a horizontally scrolling strip, then the
/// `+` button. `+` follows the last tab while everything fits; once the tabs
/// overflow it is pinned at the trailing edge and the strip shrinks by its
/// width, so it never scrolls out of view.
@MainActor
enum TabRowLayout {
    /// `padding: 0 4px` around the row; pills carry their own 2 pt gap.
    static let padding: CGFloat = 4

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
        stripHeight: CGFloat
    ) -> CGFloat {
        let addSize = addButton.frame.width > 0 ? addButton.frame.width : ChromeIconButton.defaultSize
        let addArea = padding + addSize + padding
        var x = padding
        for tab in tabs {
            tab.view.frame = NSRect(x: x, y: 0, width: tab.width, height: stripHeight)
            x += tab.width
        }
        let tabsEnd = x
        let fits = tabsEnd + addArea <= availableWidth
        let viewportWidth = max(0, fits ? availableWidth : availableWidth - addArea)
        scrollView.frame = NSRect(x: 0, y: rule, width: viewportWidth, height: stripHeight)
        container.setFrameSize(NSSize(width: max(viewportWidth, tabsEnd + padding), height: stripHeight))
        // Everything fits, so the strip is not scrolled and the inline
        // position is the same in the row's coordinates.
        addButton.frame = NSRect(
            x: fits ? tabsEnd + padding : viewportWidth + padding,
            y: rule + floor((stripHeight - addSize) / 2),
            width: addSize,
            height: addSize
        )
        return viewportWidth
    }
}

/// A tab in the window and layout tab rows: a muted label at rest, the hover
/// pill under the pointer, and the raised pill (`.raisedTab`) when selected.
/// Subclasses lay out their title and badges inside `pillRect`.
class TabPillButton: NSButton {
    /// Each tab row is 32 pt including its bottom hairline.
    static let rowHeight: CGFloat = 32
    static let pillHeight: CGFloat = 24
    /// Space between neighboring pills; each tab keeps half on either side.
    static let pillGap: CGFloat = 2
    static let leadingPadding: CGFloat = 10
    static let trailingPadding: CGFloat = 8
    /// Between the title, badges and close button.
    static let contentGap: CGFloat = 6
    /// Horizontal space a tab adds around its content.
    static let chromeWidth: CGFloat = pillGap + leadingPadding + trailingPadding

    var isSelectedTab = false {
        didSet {
            guard isSelectedTab != oldValue else { return }
            needsDisplay = true
            hoverStateDidChange()
        }
    }
    private(set) var isHovered = false
    private var colors: ThemeColors?
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Cell-backed properties below must follow the cell swap.
        cell = TabPillButtonCell()
        isBordered = false
        refusesFirstResponder = true
        wantsLayer = true
        setAccessibilityRole(.radioButton)
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

    func applyPill(colors: ThemeColors) {
        self.colors = colors
        needsDisplay = true
    }

    /// Called when the pointer enters or leaves the tab, or its selection
    /// changes.
    func hoverStateDidChange() {}

    override func draw(_ dirtyRect: NSRect) {
        if let colors {
            let style: ChromeSelectionPill.Style = isSelectedTab ? .raisedTab : (isHovered ? .hover : .none)
            ChromeSelectionPill.draw(style, in: pillRect, colors: colors, inset: 0)
        }
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
