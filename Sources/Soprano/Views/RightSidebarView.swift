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
    /// Soprano Agents' right-panel tab strip: one tab per panel, the panel
    /// close button at the end. It sits in the title bar strip, so its
    /// empty space moves the window.
    private let header = ShellTitlebarDragView()
    private let tabStack = NSStackView()
    private var tabButtons: [Tab: RightSidebarTabButton] = [:]
    private var closeButton: ShellGhostButton!
    private let headerRule = NSView()
    private let leadingBorder = NSView()
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
        header.wantsLayer = true
        contentContainer.addSubview(header)
        headerRule.wantsLayer = true
        headerRule.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerRule)

        tabStack.orientation = .horizontal
        tabStack.alignment = .centerY
        tabStack.spacing = 4
        tabStack.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(tabStack)
        for tab in Tab.allCases {
            let button = RightSidebarTabButton(tab: tab, target: self, action: #selector(tabClicked(_:)))
            tabStack.addArrangedSubview(button)
            tabButtons[tab] = button
        }

        closeButton = ShellGhostButton(
            symbol: Icon.panelRight,
            label: "Toggle Right Sidebar",
            target: self,
            action: #selector(closeClicked)
        )
        closeButton.translatesAutoresizingMaskIntoConstraints = false
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
        leadingBorder.wantsLayer = true
        leadingBorder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(leadingBorder)

        contentWidthConstraint = contentContainer.widthAnchor.constraint(
            equalToConstant: SidebarWidthStore.right.defaultWidth - 1
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

            tabStack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 8),
            tabStack.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            tabStack.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -8),

            closeButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(
                equalTo: header.topAnchor,
                constant: (Self.headerHeight - 1) / 2
            ),

            headerRule.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            headerRule.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            headerRule.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            headerRule.heightAnchor.constraint(equalToConstant: 1),

            leadingBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            leadingBorder.topAnchor.constraint(equalTo: topAnchor),
            leadingBorder.bottomAnchor.constraint(equalTo: bottomAnchor),
            leadingBorder.widthAnchor.constraint(equalToConstant: 1),
        ])
    }

    /// Width of the sidebar's content, kept in step with the dragged width.
    func setContentWidth(_ width: CGFloat) {
        contentWidthConstraint.constant = max(0, width - 1)
    }

    /// Darkens the leading hairline while the resize handle is hovered or
    /// dragged, like the left sidebar's trailing edge.
    func setResizeHighlighted(_ isHighlighted: Bool) {
        isResizeHighlighted = isHighlighted
        let palette = PaletteCenter.shared.palette
        leadingBorder.layer?.backgroundColor = (isHighlighted ? palette.input : palette.border).cgColor
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
        let palette = PaletteCenter.shared.palette
        layer?.backgroundColor = palette.background.cgColor
        header.layer?.backgroundColor = palette.background.cgColor
        headerRule.layer?.backgroundColor = palette.border.cgColor
        setResizeHighlighted(isResizeHighlighted)
        for (tab, button) in tabButtons {
            button.isActiveTab = tab == activeTab
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

/// One panel tab in Agents' right-panel strip (`h-6 rounded-md pl-1.5 pr-2
/// text-xs`): an 11 pt glyph and the title, `accent` when active,
/// `accent/60` under the pointer, muted otherwise.
final class RightSidebarTabButton: NSButton {
    let tab: RightSidebarView.Tab
    var isActiveTab = false {
        didSet {
            setAccessibilityValue(isActiveTab ? "selected" : nil)
            refresh()
        }
    }
    private var isHovered = false
    private var hoverArea: NSTrackingArea?

    init(tab: RightSidebarView.Tab, target: AnyObject?, action: Selector?) {
        self.tab = tab
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        refusesFirstResponder = true
        imagePosition = .imageLeading
        imageHugsTitle = true
        imageScaling = .scaleNone
        image = NSImage.symbol(tab.symbolName, size: 11)
        toolTip = tab.title
        setAccessibilityLabel(tab.title)
        setAccessibilityRole(.radioButton)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: ShellTabStyle.height).isActive = true
        PaletteCenter.shared.addObserver(self) { [weak self] _ in self?.refresh() }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        let titleWidth = ceil(attributedTitle.size().width)
        return NSSize(width: 6 + 12 + 4 + titleWidth + 8, height: ShellTabStyle.height)
    }

    private func refresh() {
        let color = ShellTabStyle.textColor(isActive: isActiveTab, isHovered: isHovered)
        attributedTitle = NSAttributedString(string: " " + tab.title, attributes: [
            .font: Typography.ui(Typography.smallSize, weight: isActiveTab ? .medium : .regular),
            .foregroundColor: color,
        ])
        contentTintColor = color
        invalidateIntrinsicContentSize()
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
        refresh()
    }

    override func draw(_ dirtyRect: NSRect) {
        ShellTabStyle.draw(isActive: isActiveTab, isHovered: isHovered, in: bounds)
        super.draw(dirtyRect)
    }
}
