import AppKit

/// The current session's windows, presented as a horizontal row above the terminals.
final class WindowTabBarView: NSView {
    static let height: CGFloat = TabPillButton.rowHeight

    private let agentManager: AgentManager
    private let themeManager: ThemeManager
    private let observerId = "WindowTabBarView-\(UUID().uuidString)"
    private let scrollView = NSScrollView()
    private let tabContainer = NSView()
    private let addButton = ChromeIconButton(
        symbolName: "plus",
        accessibilityLabel: "New Window",
        pointSize: 12,
        target: nil,
        action: nil
    )
    private let bottomRule = ChromeRuleView(axis: .horizontal)
    private var buttons: [WindowTabButton] = []
    private var activeWindowId: String?
    private var revealActiveTab = true
    private var previousViewportWidth: CGFloat = 0
    private let rightSidebarToggle = ChromeIconButton(
        symbolName: "sidebar.right",
        accessibilityLabel: "Toggle Right Sidebar",
        target: nil,
        action: nil
    )

    /// Orca shows a toggle at the top right while the right sidebar is closed;
    /// it lives at the end of this strip so it never covers a tab.
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

        addButton.identifier = NSUserInterfaceItemIdentifier("new-window-tab")
        addButton.refusesFirstResponder = true
        addButton.target = self
        addButton.action = #selector(addWindow)
        addButton.translatesAutoresizingMaskIntoConstraints = true
        tabContainer.addSubview(addButton)

        rightSidebarToggle.identifier = NSUserInterfaceItemIdentifier("right-sidebar-toggle")
        rightSidebarToggle.refusesFirstResponder = true
        rightSidebarToggle.target = self
        rightSidebarToggle.action = #selector(toggleRightSidebar)
        rightSidebarToggle.isHidden = true
        // Positioned by frame like the rest of the strip.
        rightSidebarToggle.translatesAutoresizingMaskIntoConstraints = true
        addSubview(rightSidebarToggle)

        bottomRule.translatesAutoresizingMaskIntoConstraints = true
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
        layer?.backgroundColor = theme.colors.bgPanel.cgColor
        bottomRule.color = theme.colors.borderSubtle
        rightSidebarToggle.apply(theme: theme)
        addButton.apply(theme: theme)
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
        let rule = Chrome.hairline
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
        let documentWidth = max(viewportWidth, x)
        tabContainer.setFrameSize(NSSize(width: documentWidth, height: stripHeight))
        if viewportWidth != previousViewportWidth {
            previousViewportWidth = viewportWidth
            revealActiveTab = true
        }
        if revealActiveTab, viewportWidth > 0,
           let selected = buttons.first(where: { $0.windowId == activeWindowId }) {
            // Include the row's 4 pt padding so the first tab reveals flush.
            selected.scrollToVisible(selected.bounds.insetBy(dx: -4, dy: 0))
            revealActiveTab = false
        }
    }

    @objc private func addWindow() {
        _ = agentManager.createWindow()
    }

    @objc private func toggleRightSidebar() {
        onRightSidebarToggle?()
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
        let colors = theme.colors
        let text = NSMutableAttributedString(attributedString: ChromeText.attributed(
            "\(number)  ",
            font: ChromeFont.label,
            color: colors.textMuted
        ))
        text.append(ChromeText.attributed(
            title,
            font: isSelected ? ChromeFont.labelStrong : ChromeFont.label,
            color: isSelected ? colors.textPrimary : colors.textMuted
        ))
        attributedTitle = text
        agentBadge.configure(agents: agents, theme: theme)
        commandBadge.configure(runningCommands: runningCommands, theme: theme)
        let titleWidth = min(Self.maxTitleWidth, ceil(text.size().width))
        tabWidth = max(Self.minWidth, Self.chromeWidth + titleWidth + badgeAreaWidth)
        isSelectedTab = isSelected
        applyPill(colors: colors)

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
