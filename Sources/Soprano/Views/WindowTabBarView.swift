import AppKit

/// The current session's windows, presented as a horizontal row above the terminals.
final class WindowTabBarView: NSView {
    static let height: CGFloat = 34

    private let agentManager: AgentManager
    private let themeManager: ThemeManager
    private let observerId = "WindowTabBarView-\(UUID().uuidString)"
    private let scrollView = NSScrollView()
    private let tabContainer = NSView()
    private let addButton = NSButton(title: "+", target: nil, action: nil)
    private let bottomRule = RetroRuleView(axis: .horizontal, style: .double)
    private var buttons: [WindowTabButton] = []
    private var activeWindowId: String?
    private var revealActiveTab = true
    private var previousViewportWidth: CGFloat = 0
    private let rightSidebarToggle = RetroIconButton(
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
        addButton.isBordered = false
        addButton.refusesFirstResponder = true
        addButton.target = self
        addButton.action = #selector(addWindow)
        addButton.toolTip = "New Window"
        addButton.setAccessibilityLabel("New Window")
        addSubview(addButton)

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
        bottomRule.color = theme.colors.borderStrong
        rightSidebarToggle.setTints(normal: theme.colors.textMuted, hover: theme.colors.accent)
        addButton.attributedTitle = RetroText.display(
            "+",
            color: theme.colors.textMuted,
            size: 22,
            alignment: .center
        )
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
        let rule = Retro.doubleRule
        let stripHeight = max(0, bounds.height - rule)
        let toggleWidth: CGFloat = showsRightSidebarToggle ? 30 : 0
        let viewportWidth = max(0, bounds.width - 38 - toggleWidth)
        scrollView.frame = NSRect(x: 0, y: rule, width: viewportWidth, height: stripHeight)
        addButton.frame = NSRect(
            x: max(0, bounds.width - 34 - toggleWidth),
            y: rule + floor((stripHeight - 28) / 2),
            width: 28,
            height: 28
        )
        rightSidebarToggle.frame = NSRect(
            x: max(0, bounds.width - 31),
            y: rule + floor((stripHeight - RetroIconButton.defaultSize) / 2),
            width: RetroIconButton.defaultSize,
            height: RetroIconButton.defaultSize
        )
        bottomRule.frame = NSRect(x: 0, y: 0, width: bounds.width, height: rule)

        var x: CGFloat = 0
        for button in buttons {
            button.frame = NSRect(x: x, y: 0, width: button.tabWidth, height: stripHeight)
            x += button.tabWidth
        }
        let documentWidth = max(viewportWidth, x)
        tabContainer.setFrameSize(NSSize(width: documentWidth, height: stripHeight))
        if viewportWidth != previousViewportWidth {
            previousViewportWidth = viewportWidth
            revealActiveTab = true
        }
        if revealActiveTab, viewportWidth > 0,
           let selected = buttons.first(where: { $0.windowId == activeWindowId }) {
            selected.scrollToVisible(selected.bounds)
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

private final class WindowTabButton: NSButton {
    let windowId: String
    private let onSelect: () -> Void
    private let separator = TabPlateView()
    private let badgeUnderlay = TabPlateView()
    private let agentBadge = LampCountBadgeView(identifier: "window-agent-badge")
    private let commandBadgeUnderlay = TabPlateView()
    private let commandBadge = LampCountBadgeView(identifier: "window-command-badge")
    private(set) var tabWidth: CGFloat = 80

    init(windowId: String, onSelect: @escaping () -> Void) {
        self.windowId = windowId
        self.onSelect = onSelect
        super.init(frame: .zero)
        cell = WindowTabButtonCell()
        identifier = NSUserInterfaceItemIdentifier("window-tab-\(windowId)")
        isBordered = false
        refusesFirstResponder = true
        wantsLayer = true
        layer?.cornerRadius = Retro.cornerRadius
        target = self
        action = #selector(selectWindow)
        setAccessibilityRole(.radioButton)
        addSubview(separator)
        addSubview(badgeUnderlay)
        addSubview(agentBadge)
        addSubview(commandBadgeUnderlay)
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
        let text = "\(number):\(title)"
        self.title = text
        attributedTitle = RetroText.display(
            text,
            color: isSelected ? theme.colors.bgPanel : theme.colors.textMuted,
            alignment: .left,
            lineBreakMode: .byTruncatingTail
        )
        agentBadge.configure(agents: agents, theme: theme)
        commandBadge.configure(runningCommands: runningCommands, theme: theme)
        badgeUnderlay.isHidden = agentBadge.isHidden
        commandBadgeUnderlay.isHidden = commandBadge.isHidden
        for underlay in [badgeUnderlay, commandBadgeUnderlay] {
            underlay.layer?.backgroundColor = theme.colors.bgPanel.cgColor
        }
        let badges = [agentBadge, commandBadge].filter { !$0.isHidden }
        let indicatorWidth = badges.isEmpty ? 0 : badges.reduce(4) { $0 + $1.badgeWidth + 4 }
        (cell as? WindowTabButtonCell)?.trailingInset = indicatorWidth
        tabWidth = min(200, max(72, ceil(attributedTitle.size().width) + 24)) + indicatorWidth
        layer?.backgroundColor = isSelected ? theme.colors.accent.cgColor : NSColor.clear.cgColor
        separator.isHidden = isSelected
        separator.layer?.backgroundColor = theme.colors.borderSubtle.cgColor
        var description = "Window \(number): \(title)"
        for summary in [
            LampCountBadgeView.summary(of: agents),
            LampCountBadgeView.summary(ofRunningCommands: runningCommands),
        ].compactMap({ $0 }) {
            description += " — \(summary)"
        }
        toolTip = description
        setAccessibilityLabel(description)
        setAccessibilityValue(isSelected)
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        // Agents sit at the trailing edge, running commands before them.
        var badgeEdge = bounds.maxX - 8
        for (badge, underlay) in [(agentBadge, badgeUnderlay), (commandBadge, commandBadgeUnderlay)]
            where !badge.isHidden {
            badge.frame = NSRect(
                x: badgeEdge - 4 - badge.badgeWidth,
                y: floor(bounds.midY - 8),
                width: badge.badgeWidth,
                height: 16
            )
            underlay.frame = badge.frame
            badgeEdge = badge.frame.minX
        }
        separator.frame = NSRect(
            x: bounds.maxX - Retro.hairline,
            y: 7,
            width: Retro.hairline,
            height: max(0, bounds.height - 14)
        )
    }

    @objc private func selectWindow() {
        onSelect()
    }
}

/// Draw the title in a fixed padded area so the badge never crowds or clips it.
private final class WindowTabButtonCell: NSButtonCell {
    var trailingInset: CGFloat = 0

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        let height = ceil(attributedTitle.size().height)
        return NSRect(
            x: rect.minX + 12,
            y: floor(rect.midY - height / 2),
            width: max(0, rect.width - 24 - trailingInset),
            height: height
        )
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        attributedTitle.draw(in: titleRect(forBounds: cellFrame))
    }
}
