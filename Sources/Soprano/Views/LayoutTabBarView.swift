import AppKit

/// The active window's tabs, in a row between the window tabs and the panes.
/// Each tab holds a split layout of its own and is named after its focused
/// pane; the active one is on screen. With the window tabs hidden it is the
/// top row and takes over their height, double rule, and right sidebar toggle.
final class LayoutTabBarView: NSView {
    /// The row's height under the window tabs.
    static let height: CGFloat = 30

    /// As the top row it matches the window tabs, so its bottom rule runs on
    /// into the right sidebar's header.
    static func height(isTopRow: Bool) -> CGFloat {
        isTopRow ? WindowTabBarView.height : height
    }

    private let agentManager: AgentManager
    private let themeManager: ThemeManager
    private let observerId = "LayoutTabBarView-\(UUID().uuidString)"
    private let scrollView = NSScrollView()
    private let tabContainer = NSView()
    private let addButton = NSButton(title: "+", target: nil, action: nil)
    private var bottomRule = RetroRuleView(axis: .horizontal, style: .single)
    private let rightSidebarToggle = RetroIconButton(
        symbolName: "sidebar.right",
        accessibilityLabel: "Toggle Right Sidebar",
        target: nil,
        action: nil
    )
    private var buttons: [LayoutTabButton] = []
    private var activeLayoutTabId: String?
    private var revealActiveTab = true
    private var previousViewportWidth: CGFloat = 0

    /// Set while the window tabs are hidden.
    var isTopRow = false {
        didSet {
            guard isTopRow != oldValue else { return }
            // A rule's style is fixed when it is made, so swap in a new one.
            bottomRule.removeFromSuperview()
            bottomRule = RetroRuleView(axis: .horizontal, style: isTopRow ? .double : .single)
            bottomRule.translatesAutoresizingMaskIntoConstraints = true
            addSubview(bottomRule)
            refresh()
        }
    }

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
        addButton.isBordered = false
        addButton.refusesFirstResponder = true
        addButton.target = self
        addButton.action = #selector(addTab)
        addButton.toolTip = "New Tab"
        addButton.setAccessibilityLabel("New Tab")
        addSubview(addButton)

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
        bottomRule.color = theme.colors.borderStrong
        rightSidebarToggle.setTints(normal: theme.colors.textMuted, hover: theme.colors.accent)
        addButton.attributedTitle = RetroText.display(
            "+",
            color: theme.colors.textMuted,
            size: 22,
            alignment: .center
        )
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
        let rule = bottomRule.style.thickness
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
        tabContainer.setFrameSize(NSSize(width: max(viewportWidth, x), height: stripHeight))
        if viewportWidth != previousViewportWidth {
            previousViewportWidth = viewportWidth
            revealActiveTab = true
        }
        if revealActiveTab, viewportWidth > 0,
           let selected = buttons.first(where: { $0.layoutTabId == activeLayoutTabId }) {
            selected.scrollToVisible(selected.bounds)
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

private final class LayoutTabButton: NSButton {
    private static let closeSize: CGFloat = 20
    /// The close button and the margin after it.
    private static let closeArea: CGFloat = closeSize + 6

    let layoutTabId: String
    private let onSelect: () -> Void
    private let onClose: () -> Void
    private let closeButton = NSButton(title: "×", target: nil, action: nil)
    private let separator = TabPlateView()
    private let activeMarker = TabPlateView()
    private let agentBadge = LampCountBadgeView(identifier: "layout-tab-agent-badge")
    private let commandBadge = LampCountBadgeView(identifier: "layout-tab-command-badge")
    private(set) var tabWidth: CGFloat = 96

    init(layoutTabId: String, onSelect: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.layoutTabId = layoutTabId
        self.onSelect = onSelect
        self.onClose = onClose
        super.init(frame: .zero)
        cell = LayoutTabButtonCell()
        identifier = NSUserInterfaceItemIdentifier("layout-tab-\(layoutTabId)")
        isBordered = false
        refusesFirstResponder = true
        wantsLayer = true
        layer?.cornerRadius = Retro.cornerRadius
        target = self
        action = #selector(selectTab)
        setAccessibilityRole(.radioButton)

        closeButton.identifier = NSUserInterfaceItemIdentifier("close-layout-tab-\(layoutTabId)")
        closeButton.isBordered = false
        closeButton.refusesFirstResponder = true
        closeButton.target = self
        closeButton.action = #selector(closeTab)
        closeButton.toolTip = "Close Tab"
        closeButton.setAccessibilityLabel("Close Tab")

        addSubview(separator)
        addSubview(activeMarker)
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
        self.title = title
        attributedTitle = RetroText.display(
            title,
            color: isSelected ? theme.colors.textPrimary : theme.colors.textMuted,
            alignment: .left,
            lineBreakMode: .byTruncatingTail
        )
        agentBadge.configure(agents: agents, theme: theme)
        commandBadge.configure(runningCommands: runningCommands, theme: theme)
        let badgeArea = [agentBadge, commandBadge]
            .filter { !$0.isHidden }
            .reduce(0) { $0 + $1.badgeWidth + 4 }
        let trailingInset = badgeArea + Self.closeArea
        (cell as? LayoutTabButtonCell)?.trailingInset = trailingInset
        let titleWidth = ceil(attributedTitle.size().width)
        tabWidth = min(240, max(96, LayoutTabButtonCell.leadingInset + titleWidth + 6 + trailingInset))

        layer?.backgroundColor = isSelected ? theme.colors.bgRaised.cgColor : NSColor.clear.cgColor
        activeMarker.isHidden = !isSelected
        activeMarker.layer?.backgroundColor = theme.colors.accent.cgColor
        separator.isHidden = isSelected
        separator.layer?.backgroundColor = theme.colors.borderSubtle.cgColor
        closeButton.attributedTitle = RetroText.display(
            "×",
            color: theme.colors.textMuted,
            alignment: .center
        )

        var description = "Tab \(number): \(title)"
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
        closeButton.frame = NSRect(
            x: bounds.maxX - Self.closeArea,
            y: floor(bounds.midY - Self.closeSize / 2),
            width: Self.closeSize,
            height: Self.closeSize
        )
        // Agents sit next to the close button, running commands before them.
        var badgeEdge = closeButton.frame.minX
        for badge in [agentBadge, commandBadge] where !badge.isHidden {
            badge.frame = NSRect(
                x: badgeEdge - 4 - badge.badgeWidth,
                y: floor(bounds.midY - 8),
                width: badge.badgeWidth,
                height: 16
            )
            badgeEdge = badge.frame.minX
        }
        // An underline like the pane header's tab strip, on the edge facing
        // the panes.
        activeMarker.frame = NSRect(
            x: 0,
            y: isFlipped ? bounds.maxY - 2 : 0,
            width: bounds.width,
            height: 2
        )
        separator.frame = NSRect(
            x: bounds.maxX - Retro.hairline,
            y: 7,
            width: Retro.hairline,
            height: max(0, bounds.height - 14)
        )
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

/// Draws the title in a padded area that leaves room for the badges and the
/// close button.
private final class LayoutTabButtonCell: NSButtonCell {
    static let leadingInset: CGFloat = 12
    var trailingInset: CGFloat = 0

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        let height = ceil(attributedTitle.size().height)
        return NSRect(
            x: rect.minX + Self.leadingInset,
            y: floor(rect.midY - height / 2),
            width: max(0, rect.width - Self.leadingInset - 6 - trailingInset),
            height: height
        )
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        attributedTitle.draw(in: titleRect(forBounds: cellFrame))
    }
}
