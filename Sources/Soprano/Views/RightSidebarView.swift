import AppKit

/// Orca's right sidebar: a resizable column on the window's trailing edge with
/// a tab strip (Explorer, Source Control) and the active tab's panel.
///
/// Like the left sidebar it collapses to zero width rather than leaving the
/// hierarchy, so the panels keep their state and caches; a panel only reads
/// and watches the disk while the sidebar is open, in a window, and showing it.
final class RightSidebarView: NSView {
    enum Tab: String, CaseIterable {
        case explorer
        case sourceControl

        var title: String {
            switch self {
            case .explorer: "Explorer"
            case .sourceControl: "Source Control"
            }
        }

        var symbolName: String {
            switch self {
            case .explorer: "doc.on.doc"
            case .sourceControl: "arrow.triangle.branch"
            }
        }
    }

    /// Matches the window tab bar (32 pt) so both bottom rules run as one line.
    static let headerHeight = WindowTabBarView.height
    static let activeTabKey = "soprano-right-sidebar-tab"

    let explorerView: FileExplorerView
    let sourceControlView: SourceControlView
    var onCloseRequested: (() -> Void)?

    private let themeManager: ThemeManager
    private let defaults: UserDefaults
    private let contentContainer = NSView()
    private var contentWidthConstraint: NSLayoutConstraint!
    private let header = NSView()
    private let segmentTrack = RightSidebarSegmentTrack()
    private var tabButtons: [Tab: RightSidebarTabButton] = [:]
    private let headingView: ChromeEyebrowView
    private var closeButton: ChromeIconButton!
    private let headerRule = ChromeRuleView(axis: .horizontal)
    private let leadingBorder = ChromeRuleView(axis: .vertical)
    private var isResizeHighlighted = false
    private(set) var isOpen = false
    private(set) var activeTab: Tab

    init(agentManager: AgentManager, themeManager: ThemeManager, defaults: UserDefaults = .standard) {
        self.themeManager = themeManager
        self.defaults = defaults
        explorerView = FileExplorerView(
            agentManager: agentManager,
            themeManager: themeManager,
            defaults: defaults
        )
        sourceControlView = SourceControlView(agentManager: agentManager, themeManager: themeManager)
        let activeTab = defaults.string(forKey: Self.activeTabKey).flatMap(Tab.init(rawValue:)) ?? .explorer
        self.activeTab = activeTab
        headingView = ChromeEyebrowView(title: activeTab.title, theme: themeManager.currentTheme)
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("right-sidebar")
        wantsLayer = true
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        setupViews()
        updatePanelVisibility()
        refreshTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setupViews() {
        // Pinned to the trailing edge with its own width, so collapsing the
        // sidebar slides the content off to the right instead of squeezing it.
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentContainer)

        header.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(header)
        header.addSubview(headerRule)

        // The tabs are a segmented icon pair: a bgOverlay track with a raised
        // pill under the active icon.
        segmentTrack.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(segmentTrack)
        var previousTrailing = segmentTrack.leadingAnchor
        for tab in Tab.allCases {
            let button = RightSidebarTabButton(tab: tab, target: self, action: #selector(tabClicked(_:)))
            segmentTrack.addSubview(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(
                    equalTo: previousTrailing,
                    constant: tab == Tab.allCases.first ? RightSidebarSegmentTrack.padding : RightSidebarSegmentTrack.gap
                ),
                button.centerYAnchor.constraint(equalTo: segmentTrack.centerYAnchor),
            ])
            previousTrailing = button.trailingAnchor
            tabButtons[tab] = button
        }
        segmentTrack.trailingAnchor.constraint(
            equalTo: previousTrailing,
            constant: RightSidebarSegmentTrack.padding
        ).isActive = true

        header.addSubview(headingView)
        closeButton = ChromeIconButton(
            symbolName: "sidebar.right",
            accessibilityLabel: "Toggle Right Sidebar",
            target: self,
            action: #selector(closeClicked)
        )
        header.addSubview(closeButton)

        for panel in [explorerView, sourceControlView] as [NSView] {
            panel.translatesAutoresizingMaskIntoConstraints = false
            contentContainer.addSubview(panel)
            NSLayoutConstraint.activate([
                panel.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                panel.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                panel.topAnchor.constraint(equalTo: header.bottomAnchor),
                panel.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            ])
        }
        addSubview(leadingBorder)

        contentWidthConstraint = contentContainer.widthAnchor.constraint(
            equalToConstant: SidebarWidthStore.right.defaultWidth - Chrome.hairline
        )

        NSLayoutConstraint.activate([
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentWidthConstraint,

            header.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            header.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),

            segmentTrack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: Chrome.Space.s8),
            segmentTrack.heightAnchor.constraint(equalToConstant: Chrome.controlHeight),
            segmentTrack.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),

            headingView.leadingAnchor.constraint(equalTo: segmentTrack.trailingAnchor, constant: Chrome.Space.s8),
            headingView.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -Chrome.Space.s4),
            headingView.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -Chrome.Space.s8),
            closeButton.centerYAnchor.constraint(
                equalTo: header.topAnchor,
                constant: (Self.headerHeight - Chrome.hairline) / 2
            ),

            headerRule.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            headerRule.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            headerRule.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            headerRule.heightAnchor.constraint(equalToConstant: Chrome.hairline),

            leadingBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            leadingBorder.topAnchor.constraint(equalTo: topAnchor),
            leadingBorder.bottomAnchor.constraint(equalTo: bottomAnchor),
            leadingBorder.widthAnchor.constraint(equalToConstant: Chrome.hairline),
        ])
    }

    /// Width of the sidebar's content, kept in step with the dragged width.
    func setContentWidth(_ width: CGFloat) {
        contentWidthConstraint.constant = max(0, width - Chrome.hairline)
    }

    /// Accents the leading hairline while the resize handle is hovered or
    /// dragged, like the left sidebar's trailing edge.
    func setResizeHighlighted(_ isHighlighted: Bool) {
        isResizeHighlighted = isHighlighted
        leadingBorder.color = isHighlighted
            ? themeManager.currentTheme.colors.accent
            : themeManager.currentTheme.colors.borderSubtle
    }

    func setOpen(_ open: Bool) {
        isOpen = open
        updateActivity()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateActivity()
    }

    private func updateActivity() {
        let isShowing = isOpen && window != nil
        explorerView.setActive(isShowing && activeTab == .explorer)
        sourceControlView.setActive(isShowing && activeTab == .sourceControl)
    }

    private func updatePanelVisibility() {
        explorerView.isHidden = activeTab != .explorer
        sourceControlView.isHidden = activeTab != .sourceControl
    }

    /// Whether the keyboard is in either panel.
    var containsKeyboardFocus: Bool {
        explorerView.containsKeyboardFocus || sourceControlView.containsKeyboardFocus
    }

    /// Shows `tab`'s panel and remembers it for the next launch. The keyboard
    /// moves along when it was in the panel being hidden.
    func selectTab(_ tab: Tab) {
        guard tab != activeTab else { return }
        let hadFocus = containsKeyboardFocus
        activeTab = tab
        defaults.set(tab.rawValue, forKey: Self.activeTabKey)
        headingView.title = tab.title
        updatePanelVisibility()
        refreshTheme()
        updateActivity()
        if hadFocus {
            focusActivePanel()
        }
    }

    /// Moves the keyboard into the active panel's list.
    func focusActivePanel() {
        switch activeTab {
        case .explorer: explorerView.focusTree()
        case .sourceControl: sourceControlView.focusList()
        }
    }

    func refreshTheme() {
        let theme = themeManager.currentTheme
        let colors = theme.colors
        layer?.backgroundColor = colors.bgPanel.cgColor
        headingView.apply(theme: theme)
        headerRule.color = colors.borderSubtle
        setResizeHighlighted(isResizeHighlighted)
        closeButton.apply(theme: theme)
        segmentTrack.colors = colors
        for (tab, button) in tabButtons {
            button.apply(colors: colors, isActive: tab == activeTab)
        }
        explorerView.applyTheme()
        sourceControlView.applyTheme()
    }

    @objc private func tabClicked(_ sender: RightSidebarTabButton) {
        selectTab(sender.tab)
    }

    @objc private func closeClicked() {
        onCloseRequested?()
    }
}

/// The `.segmented` track behind the tab pair: a `bgOverlay` 24 pt capsule
/// with 2 pt padding.
final class RightSidebarSegmentTrack: NSView {
    static let padding: CGFloat = 2
    static let gap: CGFloat = 2

    var colors: ThemeColors? {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let colors else { return }
        colors.bgOverlay.setFill()
        NSBezierPath(
            roundedRect: bounds,
            xRadius: Chrome.Radius.control,
            yRadius: Chrome.Radius.control
        ).fill()
    }
}

/// One icon segment in the sidebar header. The active segment sits on a
/// raised pill with a `borderSubtle` ring and an ink glyph; the others are
/// muted, ink under the pointer. Never accent.
final class RightSidebarTabButton: NSButton {
    static let segmentSize = NSSize(width: 30, height: 20)

    let tab: RightSidebarView.Tab
    private var colors: ThemeColors?
    private(set) var isActiveTab = false
    private var isHovered = false
    private var hoverArea: NSTrackingArea?

    init(tab: RightSidebarView.Tab, target: AnyObject?, action: Selector?) {
        self.tab = tab
        super.init(frame: .zero)
        self.target = target
        self.action = action
        title = ""
        isBordered = false
        refusesFirstResponder = true
        imagePosition = .imageOnly
        image = NSImage(systemSymbolName: tab.symbolName, accessibilityDescription: tab.title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        toolTip = tab.title
        setAccessibilityLabel(tab.title)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.segmentSize.width),
            heightAnchor.constraint(equalToConstant: Self.segmentSize.height),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(colors: ThemeColors, isActive: Bool) {
        self.colors = colors
        isActiveTab = isActive
        setAccessibilityValue(isActive ? "selected" : nil)
        refreshTint()
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea {
            removeTrackingArea(hoverArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil else { return }
        setHovered(false)
    }

    private func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        refreshTint()
    }

    private func refreshTint() {
        guard let colors else { return }
        contentTintColor = isActiveTab || isHovered ? colors.textPrimary : colors.textMuted
    }

    override func draw(_ dirtyRect: NSRect) {
        if isActiveTab, let colors {
            let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = colors.textPrimary.withAlphaComponent(0.10)
            shadow.shadowOffset = NSSize(width: 0, height: isFlipped ? 1 : -1)
            shadow.shadowBlurRadius = 2
            shadow.set()
            colors.raised.setFill()
            pill.fill()
            NSGraphicsContext.restoreGraphicsState()
            colors.borderSubtle.setStroke()
            pill.lineWidth = Chrome.hairline
            pill.stroke()
        }
        super.draw(dirtyRect)
    }
}
