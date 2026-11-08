import AppKit

/// The current session's windows, presented as a horizontal row above the
/// terminals, in Soprano Agents' tab strip look. The row sits in the window's
/// title bar strip: it keeps clear of the traffic lights when nothing is to
/// its left, and its empty space moves the window.
final class WindowTabBarView: NSView {
    static let height: CGFloat = TabPillButton.rowHeight

    private let agentManager: AgentManager
    private let themeManager: ThemeManager
    private let observerId = "WindowTabBarView-\(UUID().uuidString)"
    private let scrollView = NSScrollView()
    private let tabContainer = ShellTitlebarDragView()
    private let addButton = ShellGhostButton(symbol: "plus", label: "New Window", size: 24, symbolSize: 12)
    private let bottomRule = NSView()
    private var buttons: [WindowTabButton] = []
    private var activeWindowId: String?
    private var revealActiveTab = true
    private var previousViewportWidth: CGFloat = 0
    private let rightSidebarToggle = ShellGhostButton(symbol: Icon.panelRight, label: "Toggle Right Sidebar")
    private let sidebarToggle = ShellGhostButton(symbol: Icon.sidebarLeft, label: "Toggle Sidebar")

    /// Orca shows a toggle at the top right while the right sidebar is closed;
    /// it lives at the end of this strip so it never covers a tab.
    var showsRightSidebarToggle = false {
        didSet {
            rightSidebarToggle.isHidden = !showsRightSidebarToggle
            needsLayout = true
        }
    }
    var onRightSidebarToggle: (() -> Void)?

    /// Agents' header shows the sidebar toggle while the sidebar is hidden.
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
        identifier = NSUserInterfaceItemIdentifier("window-tab-bar")
        wantsLayer = true

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        // The strip is too short for a scroller to be useful; it still scrolls by trackpad/wheel.
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

        addButton.identifier = NSUserInterfaceItemIdentifier("new-window-tab")
        addButton.refusesFirstResponder = true
        addButton.target = self
        addButton.action = #selector(addWindow)
        addButton.translatesAutoresizingMaskIntoConstraints = true
        // A row subview above the strip, so it can stay put when tabs overflow.
        addSubview(addButton)

        rightSidebarToggle.identifier = NSUserInterfaceItemIdentifier("right-sidebar-toggle")
        rightSidebarToggle.refusesFirstResponder = true
        rightSidebarToggle.target = self
        rightSidebarToggle.action = #selector(toggleRightSidebar)
        rightSidebarToggle.isHidden = true
        // Positioned by frame like the rest of the strip.
        rightSidebarToggle.translatesAutoresizingMaskIntoConstraints = true
        addSubview(rightSidebarToggle)

        bottomRule.wantsLayer = true
        addSubview(bottomRule)

        agentManager.addObserver(id: observerId) { [weak self] change in
            switch change {
            case .model:
                self?.refresh()
            case .tabTitle, .tabWorkingDirectory, .browserURL, .document:
                // Window tabs show window titles and agent counts, never a
                // tab's own title or directory. Busy agents retitle their tabs
                // several times a second, so redrawing here kept the main
                // thread saturated.
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

    /// Hidden by the `hideWindowTabs` setting, the row ignores model changes,
    /// which busy agents send many times a second, and catches up when shown.
    override var isHidden: Bool {
        didSet {
            if oldValue, !isHidden { refresh() }
        }
    }

    func refreshTheme() {
        refresh()
    }

    override func mouseDown(with event: NSEvent) {
        ShellTitlebar.handleMouseDown(event, in: self)
    }

    private func refresh() {
        guard !isHidden else { return }
        let windows = agentManager.activeSessionWindows
        if buttons.map(\.windowId) != windows.map(\.id) {
            for button in buttons { button.removeFromSuperview() }
            buttons = windows.map { terminalWindow in
                let button = WindowTabButton(windowId: terminalWindow.id) { [weak self] in
                    self?.agentManager.activateWindow(terminalWindow.id)
                }
                tabContainer.addSubview(button)
                return button
            }
            revealActiveTab = true
        }
        if activeWindowId != agentManager.activeWindowId {
            activeWindowId = agentManager.activeWindowId
            revealActiveTab = true
        }

        let theme = themeManager.currentTheme
        let palette = PaletteCenter.shared.palette
        layer?.backgroundColor = palette.background.cgColor
        bottomRule.layer?.backgroundColor = palette.border.cgColor
        for (index, terminalWindow) in windows.enumerated() {
            let previousWidth = buttons[index].tabWidth
            let panes = agentManager.orderedPanes(in: terminalWindow.id)
            let agents = panes
                .flatMap(\.tabs)
                .compactMap(\.agent)
                .filter { $0.status != .stopped }
            let runningCommands = panes.reduce(0) { count, pane in
                count + pane.tabs.filter { agentManager.isRunningCommand($0, in: pane.id) }.count
            }
            buttons[index].configure(
                number: index + 1,
                title: terminalWindow.title,
                isSelected: terminalWindow.id == activeWindowId,
                agents: agents,
                runningCommands: runningCommands,
                theme: theme
            )
            if buttons[index].tabWidth != previousWidth {
                revealActiveTab = true
            }
        }
        needsLayout = true
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
           let selected = buttons.first(where: { $0.windowId == activeWindowId }) {
            // Include the row's padding so the first tab reveals flush.
            selected.scrollToVisible(selected.bounds.insetBy(dx: -TabRowLayout.padding, dy: 0))
            revealActiveTab = false
        }
    }

    @objc private func addWindow() {
        _ = agentManager.createWindow()
    }

    @objc private func toggleRightSidebar() {
        onRightSidebarToggle?()
    }

    @objc private func toggleSidebar() {
        onSidebarToggle?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }
}

/// `1  storefront ● 3`: a muted index, the window title, then unboxed badges
/// for its running commands and agents.
private final class WindowTabButton: TabPillButton {
    private static let maxTitleWidth: CGFloat = 200
    private static let minWidth: CGFloat = 64

    let windowId: String
    private let onSelect: () -> Void
    private let agentBadge = StatusCountBadgeView(identifier: "window-agent-badge")
    private let commandBadge = StatusCountBadgeView(identifier: "window-command-badge")
    private(set) var tabWidth: CGFloat = 80

    init(windowId: String, onSelect: @escaping () -> Void) {
        self.windowId = windowId
        self.onSelect = onSelect
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("window-tab-\(windowId)")
        target = self
        action = #selector(selectWindow)
        addSubview(agentBadge)
        addSubview(commandBadge)
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
        self.number = number
        windowTitle = title
        agentBadge.configure(agents: agents, theme: theme)
        commandBadge.configure(runningCommands: runningCommands, theme: theme)
        isSelectedTab = isSelected
        renderTitle()
        let titleWidth = min(Self.maxTitleWidth, ceil(attributedTitle.size().width))
        tabWidth = max(Self.minWidth, Self.chromeWidth + titleWidth + badgeAreaWidth)
        applyPill()

        var description = "Window \(number): \(title)"
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

    private var number = 0
    private var windowTitle = ""

    /// Agents' tab text: the muted index, then the title in the tab's state
    /// color (medium while selected).
    private func renderTitle() {
        let palette = PaletteCenter.shared.palette
        let text = NSMutableAttributedString(string: "\(number)  ", attributes: [
            .font: Typography.tabular(Typography.smallSize),
            .foregroundColor: palette.mutedForeground.shellScaled(by: 0.8),
        ])
        text.append(NSAttributedString(string: windowTitle, attributes: [
            .font: isSelectedTab ? Self.selectedTitleFont : Self.titleFont,
            .foregroundColor: titleColor,
        ]))
        attributedTitle = text
    }

    override func hoverStateDidChange() {
        renderTitle()
    }

    private var visibleBadges: [StatusCountBadgeView] {
        // Agents sit at the trailing edge, running commands before them.
        [agentBadge, commandBadge].filter { !$0.isHidden }
    }

    /// The badges plus the gap that separates them from the title.
    private var badgeAreaWidth: CGFloat {
        visibleBadges.reduce(0) { $0 + Self.contentGap + $1.badgeWidth }
    }

    override func layout() {
        super.layout()
        let pill = pillRect
        var edge = pill.maxX - Self.trailingPadding
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
        let titleMaxX = visibleBadges.isEmpty ? pill.maxX - Self.trailingPadding : edge
        (cell as? TabPillButtonCell)?.titleFrame = NSRect(
            x: titleMinX,
            y: 0,
            width: max(0, titleMaxX - titleMinX),
            height: bounds.height
        )
    }

    @objc private func selectWindow() {
        onSelect()
    }
}
