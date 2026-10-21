import AppKit

/// The active window's tabs, in a row between the window tabs and the panes.
/// Each tab holds a split layout of its own and is named after its focused
/// pane; the active one is on screen. With the window tabs hidden it is the
/// top row and takes over the right sidebar toggle.
final class LayoutTabBarView: NSView {
    static let height: CGFloat = TabPillButton.rowHeight

    private let agentManager: AgentManager
    private let themeManager: ThemeManager
    private let observerId = "LayoutTabBarView-\(UUID().uuidString)"
    private let scrollView = NSScrollView()
    private let tabContainer = NSView()
    private let addButton = ChromeIconButton(
        symbolName: "plus",
        accessibilityLabel: "New Tab",
        pointSize: 12,
        target: nil,
        action: nil
    )
    private let bottomRule = ChromeRuleView(axis: .horizontal)
    private let rightSidebarToggle = ChromeIconButton(
        symbolName: "sidebar.right",
        accessibilityLabel: "Toggle Right Sidebar",
        target: nil,
        action: nil
    )
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

        addButton.identifier = NSUserInterfaceItemIdentifier("new-layout-tab")
        addButton.refusesFirstResponder = true
        addButton.target = self
        addButton.action = #selector(addTab)
        addButton.translatesAutoresizingMaskIntoConstraints = true
        tabContainer.addSubview(addButton)

        rightSidebarToggle.identifier = NSUserInterfaceItemIdentifier("right-sidebar-toggle")
        rightSidebarToggle.refusesFirstResponder = true
        rightSidebarToggle.target = self
        rightSidebarToggle.action = #selector(toggleRightSidebar)
        rightSidebarToggle.isHidden = true
        rightSidebarToggle.translatesAutoresizingMaskIntoConstraints = true
        addSubview(rightSidebarToggle)

        bottomRule.translatesAutoresizingMaskIntoConstraints = true
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
        layer?.backgroundColor = theme.colors.bgPanel.cgColor
        bottomRule.color = theme.colors.borderSubtle
        rightSidebarToggle.apply(theme: theme)
        addButton.apply(theme: theme)
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
        let previousWidth = button.tabWidth
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
        if button.tabWidth != previousWidth {
            revealActiveTab = true
        }
    }

    override func layout() {
        super.layout()
        let rule = bottomRule.thickness
        let stripHeight = max(0, bounds.height - rule)
        let iconSize = ChromeIconButton.defaultSize
        let toggleWidth: CGFloat = showsRightSidebarToggle ? iconSize + 8 : 0
        let viewportWidth = max(0, bounds.width - toggleWidth)
        scrollView.frame = NSRect(x: 0, y: rule, width: viewportWidth, height: stripHeight)
        rightSidebarToggle.frame = NSRect(
            x: max(0, bounds.width - 8 - iconSize),
            y: rule + floor((stripHeight - iconSize) / 2),
            width: iconSize,
            height: iconSize
        )
        bottomRule.frame = NSRect(x: 0, y: 0, width: bounds.width, height: rule)

        // `padding: 0 4px` around the row; pills carry their own 2 pt gap.
        var x: CGFloat = 4
        for button in buttons {
            button.frame = NSRect(x: x, y: 0, width: button.tabWidth, height: stripHeight)
            x += button.tabWidth
        }
        x += 4
        addButton.frame = NSRect(
            x: x,
            y: floor((stripHeight - iconSize) / 2),
            width: iconSize,
            height: iconSize
        )
        x += iconSize + 4
        tabContainer.setFrameSize(NSSize(width: max(viewportWidth, x), height: stripHeight))
        if viewportWidth != previousViewportWidth {
            previousViewportWidth = viewportWidth
            revealActiveTab = true
        }
        if revealActiveTab, viewportWidth > 0,
           let selected = buttons.first(where: { $0.layoutTabId == activeLayoutTabId }) {
            // Include the row's 4 pt padding so the first tab reveals flush.
            selected.scrollToVisible(selected.bounds.insetBy(dx: -4, dy: 0))
            revealActiveTab = false
        }
    }

    @objc private func addTab() {
        _ = agentManager.createLayoutTab()
    }

    @objc private func toggleRightSidebar() {
        onRightSidebarToggle?()
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
    private let closeButton = ChromeIconButton(
        symbolName: "xmark",
        accessibilityLabel: "Close Tab",
        pointSize: 9,
        size: LayoutTabButton.closeSize,
        target: nil,
        action: nil
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
        let colors = theme.colors
        attributedTitle = ChromeText.attributed(
            title,
            font: isSelected ? ChromeFont.labelStrong : ChromeFont.label,
            color: isSelected ? colors.textPrimary : colors.textMuted
        )
        agentBadge.configure(agents: agents, theme: theme)
        commandBadge.configure(runningCommands: runningCommands, theme: theme)
        closeButton.apply(theme: theme)
        let titleWidth = ceil(attributedTitle.size().width)
        let trailing = badgeAreaWidth + Self.contentGap + Self.closeSize
        tabWidth = min(Self.maxWidth, max(Self.minWidth, Self.chromeWidth + titleWidth + trailing))
        isSelectedTab = isSelected
        applyPill(colors: colors)

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

    /// The close button keeps its place on every tab so widths never jump,
    /// but shows only on the selected tab and under the pointer.
    override func hoverStateDidChange() {
        closeButton.alphaValue = isSelectedTab || isHovered ? 1 : 0
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
