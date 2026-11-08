import AppKit

/// The active window's tabs, in a row between the window tabs and the panes,
/// in Soprano Agents' tab strip look. Each tab holds a split layout of its
/// own and is named after its focused pane; the active one is on screen.
/// With the window tabs hidden it is the top row (in the title bar strip,
/// clear of the traffic lights) and takes over the sidebar toggles.
final class LayoutTabBarView: NSView {
    static let height: CGFloat = TabPillButton.rowHeight

    private let agentManager: AgentManager
    private let themeManager: ThemeManager
    private let observerId = "LayoutTabBarView-\(UUID().uuidString)"
    private let scrollView = NSScrollView()
    private let tabContainer = ShellTitlebarDragView()
    private let addButton = ShellGhostButton(symbol: "plus", label: "New Tab", size: 24, symbolSize: 12)
    private let bottomRule = NSView()
    private let rightSidebarToggle = ShellGhostButton(symbol: Icon.panelRight, label: "Toggle Right Sidebar")
    private let sidebarToggle = ShellGhostButton(symbol: Icon.sidebarLeft, label: "Toggle Sidebar")
    private var buttons: [LayoutTabButton] = []
    private var activeLayoutTabId: String?
    private var revealActiveTab = true
    private var previousViewportWidth: CGFloat = 0

    /// The top row carries the right sidebar's toggle while it is closed.
    var showsRightSidebarToggle = false {
        didSet {
            rightSidebarToggle.isHidden = !showsRightSidebarToggle
            needsLayout = true
        }
    }
    var onRightSidebarToggle: (() -> Void)?

    /// The top row carries the sidebar's toggle while it is hidden.
    var showsSidebarToggle = false {
        didSet {
            sidebarToggle.isHidden = !showsSidebarToggle
            needsLayout = true
        }
    }
    var onSidebarToggle: (() -> Void)?

    init(agentManager: AgentManager, themeManager: ThemeManager) {
        self.agentManager = agentManager
        self.themeManager = themeManager
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("layout-tab-bar")
        wantsLayer = true

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        // Like the window tabs: too short for a scroller, still scrolls by trackpad/wheel.
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = tabContainer
        addSubview(scrollView)

        sidebarToggle.target = self
        sidebarToggle.action = #selector(toggleSidebar)
        sidebarToggle.isHidden = true
        addSubview(sidebarToggle)

        addButton.identifier = NSUserInterfaceItemIdentifier("new-layout-tab")
        addButton.refusesFirstResponder = true
        addButton.target = self
        addButton.action = #selector(addTab)
        addButton.translatesAutoresizingMaskIntoConstraints = true
        // A row subview above the strip, so it can stay put when tabs overflow.
        addSubview(addButton)

        rightSidebarToggle.identifier = NSUserInterfaceItemIdentifier("right-sidebar-toggle")
        rightSidebarToggle.refusesFirstResponder = true
        rightSidebarToggle.target = self
        rightSidebarToggle.action = #selector(toggleRightSidebar)
        rightSidebarToggle.isHidden = true
        rightSidebarToggle.translatesAutoresizingMaskIntoConstraints = true
        addSubview(rightSidebarToggle)

        bottomRule.wantsLayer = true
        addSubview(bottomRule)

        agentManager.addObserver(id: observerId) { [weak self] change in
            switch change {
            case .model:
                self?.refresh()
            case .tabTitle(let target), .document(let target):
                self?.refreshTitle(showing: target)
            case .tabWorkingDirectory, .browserURL:
                break
            }
        }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        agentManager.removeObserver(id: observerId)
    }

    func refreshTheme() {
        refresh()
    }

    override func mouseDown(with event: NSEvent) {
        ShellTitlebar.handleMouseDown(event, in: self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    private func refresh() {
        let terminalWindow = agentManager.windows[agentManager.activeWindowId]
        let tabs = terminalWindow?.tabs ?? []
        if buttons.map(\.layoutTabId) != tabs.map(\.id) {
            for button in buttons { button.removeFromSuperview() }
            buttons = tabs.map { tab in
                let button = LayoutTabButton(
                    layoutTabId: tab.id,
                    onSelect: { [weak self] in self?.agentManager.activateLayoutTab(tab.id) },
                    onClose: { [weak self] in self?.agentManager.closeLayoutTab(tab.id) }
                )
                tabContainer.addSubview(button)
                return button
            }
            revealActiveTab = true
        }
        if activeLayoutTabId != terminalWindow?.activeTab.id {
            activeLayoutTabId = terminalWindow?.activeTab.id
            revealActiveTab = true
        }

        let theme = themeManager.currentTheme
        let palette = PaletteCenter.shared.palette
        layer?.backgroundColor = palette.background.cgColor
        bottomRule.layer?.backgroundColor = palette.border.cgColor
        for (index, tab) in tabs.enumerated() {
            configure(buttons[index], for: tab, number: index + 1, theme: theme)
        }
        needsLayout = true
    }

    /// Busy agents retitle themselves several times a second, so a title
    /// change touches only the tab whose focused pane shows it.
    private func refreshTitle(showing target: TerminalTarget) {
        guard agentManager.panes[target.paneId]?.activeTab?.id == target.tabId,
              let tabs = agentManager.windows[agentManager.activeWindowId]?.tabs,
              let index = tabs.firstIndex(where: { $0.activePaneId == target.paneId }),
              buttons.indices.contains(index),
              buttons[index].layoutTabId == tabs[index].id
        else { return }
        configure(buttons[index], for: tabs[index], number: index + 1, theme: themeManager.currentTheme)
        needsLayout = true
    }

    private func configure(
        _ button: LayoutTabButton,
        for tab: LayoutTab,
        number: Int,
        theme: AppTheme
    ) {
        let panes = (tab.layout?.orderedLeafIds ?? []).compactMap { agentManager.panes[$0] }
        let agents = panes
            .flatMap(\.tabs)
            .compactMap(\.agent)
            .filter { $0.status != .stopped }
        let runningCommands = panes.reduce(0) { count, pane in
            count + pane.tabs.filter { agentManager.isRunningCommand($0, in: pane.id) }.count
        }
        button.configure(
            number: number,
            title: agentManager.panes[tab.activePaneId]?.activeTab?.title ?? "Tab",
            isSelected: tab.id == activeLayoutTabId,
            agents: agents,
            runningCommands: runningCommands,
            theme: theme
        )
    }

    override func layout() {
        super.layout()
        let rule: CGFloat = 1
        let stripHeight = max(0, bounds.height - rule)
        let iconSize = Metrics.titlebarControlSize
        let toggleWidth: CGFloat = showsRightSidebarToggle ? iconSize + 8 : 0
        let availableWidth = max(0, bounds.width - toggleWidth)
        rightSidebarToggle.frame = NSRect(
            x: max(0, bounds.width - 8 - iconSize),
            y: rule + floor((stripHeight - iconSize) / 2),
            width: iconSize,
            height: iconSize
        )
        var leadingInset = ShellTitlebar.trafficLightInset(for: self)
        if showsSidebarToggle {
            sidebarToggle.frame = NSRect(
                x: max(leadingInset, 6),
                y: rule + floor((stripHeight - iconSize) / 2),
                width: iconSize,
                height: iconSize
            )
            leadingInset = sidebarToggle.frame.maxX + 4
        }
        bottomRule.frame = NSRect(x: 0, y: 0, width: bounds.width, height: rule)
        let viewportWidth = TabRowLayout.layout(
            tabs: buttons.map { ($0, $0.tabWidth) },
            addButton: addButton,
            scrollView: scrollView,
            container: tabContainer,
            availableWidth: availableWidth,
            rule: rule,
            stripHeight: stripHeight,
            leadingInset: leadingInset
        )
        if viewportWidth != previousViewportWidth {
            previousViewportWidth = viewportWidth
            revealActiveTab = true
        }
        if revealActiveTab, viewportWidth > 0,
           let selected = buttons.first(where: { $0.layoutTabId == activeLayoutTabId }) {
            // Include the row's padding so the first tab reveals flush.
            selected.scrollToVisible(selected.bounds.insetBy(dx: -TabRowLayout.padding, dy: 0))
            revealActiveTab = false
        }
    }

    @objc private func addTab() {
        _ = agentManager.createLayoutTab()
    }

    @objc private func toggleRightSidebar() {
        onRightSidebarToggle?()
    }

    @objc private func toggleSidebar() {
        onSidebarToggle?()
    }
}

/// `Claude Code ● 3 ×`: the focused pane's title with no index, unboxed
/// badges, and a close button shown on the selected or hovered tab.
private final class LayoutTabButton: TabPillButton {
    private static let closeSize: CGFloat = 16
    private static let maxWidth: CGFloat = 240
    private static let minWidth: CGFloat = 96

    let layoutTabId: String
    private let onSelect: () -> Void
    private let onClose: () -> Void
    private let closeButton = ShellGhostButton(
        symbol: "xmark",
        label: "Close Tab",
        size: LayoutTabButton.closeSize,
        symbolSize: 8,
        weight: .semibold
    )
    private let agentBadge = StatusCountBadgeView(identifier: "layout-tab-agent-badge")
    private let commandBadge = StatusCountBadgeView(identifier: "layout-tab-command-badge")
    private(set) var tabWidth: CGFloat = 96

    init(layoutTabId: String, onSelect: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.layoutTabId = layoutTabId
        self.onSelect = onSelect
        self.onClose = onClose
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("layout-tab-\(layoutTabId)")
        target = self
        action = #selector(selectTab)

        closeButton.identifier = NSUserInterfaceItemIdentifier("close-layout-tab-\(layoutTabId)")
        closeButton.refusesFirstResponder = true
        closeButton.target = self
        closeButton.action = #selector(closeTab)
        closeButton.translatesAutoresizingMaskIntoConstraints = true

        addSubview(agentBadge)
        addSubview(commandBadge)
        addSubview(closeButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(
        number: Int,
        title: String,
        isSelected: Bool,
        agents: [AgentInstance],
        runningCommands: Int,
        theme: AppTheme
    ) {
        tabTitle = title
        agentBadge.configure(agents: agents, theme: theme)
        commandBadge.configure(runningCommands: runningCommands, theme: theme)
        isSelectedTab = isSelected
        renderTitle()
        let titleWidth = ceil(attributedTitle.size().width)
        let trailing = badgeAreaWidth + Self.contentGap + Self.closeSize
        tabWidth = min(Self.maxWidth, max(Self.minWidth, Self.chromeWidth + titleWidth + trailing))
        applyPill()

        var description = "Tab \(number): \(title)"
        for summary in [
            StatusCountBadgeView.summary(of: agents),
            StatusCountBadgeView.summary(ofRunningCommands: runningCommands),
        ].compactMap({ $0 }) {
            description += " — \(summary)"
        }
        toolTip = description
        setAccessibilityLabel(description)
        setAccessibilityValue(isSelected)
        needsLayout = true
        needsDisplay = true
    }

    private var visibleBadges: [StatusCountBadgeView] {
        // Agents sit next to the close button, running commands before them.
        [agentBadge, commandBadge].filter { !$0.isHidden }
    }

    private var badgeAreaWidth: CGFloat {
        visibleBadges.reduce(0) { $0 + Self.contentGap + $1.badgeWidth }
    }

    private var tabTitle = ""

    private func renderTitle() {
        attributedTitle = NSAttributedString(string: tabTitle, attributes: [
            .font: isSelectedTab ? Self.selectedTitleFont : Self.titleFont,
            .foregroundColor: titleColor,
        ])
    }

    /// The close button keeps its place on every tab so widths never jump,
    /// but shows only on the selected tab and under the pointer.
    override func hoverStateDidChange() {
        closeButton.alphaValue = isSelectedTab || isHovered ? 1 : 0
        renderTitle()
    }

    override func layout() {
        super.layout()
        let pill = pillRect
        // The glyph's right edge lines up with the pill's 8 pt padding.
        closeButton.frame = NSRect(
            x: pill.maxX - Self.trailingPadding + 4 - Self.closeSize,
            y: floor(bounds.midY - Self.closeSize / 2),
            width: Self.closeSize,
            height: Self.closeSize
        )
        var edge = closeButton.frame.minX - Self.contentGap + 4
        for badge in visibleBadges {
            badge.frame = NSRect(
                x: edge - badge.badgeWidth,
                y: floor(bounds.midY - StatusCountBadgeView.height / 2),
                width: badge.badgeWidth,
                height: StatusCountBadgeView.height
            )
            edge = badge.frame.minX - Self.contentGap
        }
        let titleMinX = pill.minX + Self.leadingPadding
        let titleMaxX = visibleBadges.isEmpty ? closeButton.frame.minX - Self.contentGap + 4 : edge
        (cell as? TabPillButtonCell)?.titleFrame = NSRect(
            x: titleMinX,
            y: 0,
            width: max(0, titleMaxX - titleMinX),
            height: bounds.height
        )
        hoverStateDidChange()
    }

    /// A middle click closes the tab, as in a browser.
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        onClose()
    }

    @objc private func selectTab() {
        onSelect()
    }

    @objc private func closeTab() {
        onClose()
    }
}
