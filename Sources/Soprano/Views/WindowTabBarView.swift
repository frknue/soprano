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
            case .model, .tabTitle, .tabWorkingDirectory:
                self?.refresh()
            case .browserURL, .markdownDocument:
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
            let agents = agentManager.orderedPanes(in: terminalWindow.id)
                .flatMap(\.tabs)
                .compactMap(\.agent)
                .filter { $0.status != .stopped }
            buttons[index].configure(
                number: index + 1,
                title: terminalWindow.title,
                isSelected: terminalWindow.id == activeWindowId,
                agents: agents,
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
    private let separator = WindowTabPlateView()
    private let badgeUnderlay = WindowTabPlateView()
    private let agentBadge = WindowAgentBadgeView()
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
        let statuses: [AgentStatus] = [.error, .waiting, .running, .starting, .idle]
        let status = statuses.first { status in agents.contains { $0.status == status } }
        let color: NSColor = switch status {
        case .error: theme.colors.danger
        case .waiting, .starting: theme.colors.yellow
        case .running: theme.colors.success
        default: theme.colors.blue
        }
        agentBadge.configure(count: agents.count, color: color)
        badgeUnderlay.isHidden = agentBadge.isHidden
        badgeUnderlay.layer?.backgroundColor = theme.colors.bgPanel.cgColor
        let indicatorWidth = agents.isEmpty ? 0 : agentBadge.badgeWidth + 8
        (cell as? WindowTabButtonCell)?.trailingInset = indicatorWidth
        tabWidth = min(200, max(72, ceil(attributedTitle.size().width) + 24)) + indicatorWidth
        layer?.backgroundColor = isSelected ? theme.colors.accent.cgColor : NSColor.clear.cgColor
        separator.isHidden = isSelected
        separator.layer?.backgroundColor = theme.colors.borderSubtle.cgColor
        var description = "Window \(number): \(title)"
        if !agents.isEmpty {
            let noun = agents.count == 1 ? "agent" : "agents"
            let counts = statuses.compactMap { status -> String? in
                let count = agents.filter { $0.status == status }.count
                return count > 0 ? "\(count) \(status.displayLabel.lowercased())" : nil
            }
            description += " — \(agents.count) \(noun): \(counts.joined(separator: ", "))"
        }
        toolTip = description
        setAccessibilityLabel(description)
        setAccessibilityValue(isSelected)
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        agentBadge.frame = NSRect(
            x: bounds.maxX - 12 - agentBadge.badgeWidth,
            y: floor(bounds.midY - 8),
            width: agentBadge.badgeWidth,
            height: 16
        )
        badgeUnderlay.frame = agentBadge.frame
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

private final class WindowAgentBadgeView: NSView {
    private static let lampSize: CGFloat = 6

    private let lamp = NSView()
    private let countLabel = NSTextField(labelWithString: "")
    private(set) var badgeWidth: CGFloat = 28

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("window-agent-badge")
        wantsLayer = true
        layer?.cornerRadius = Retro.cornerRadius
        layer?.borderWidth = Retro.hairline
        lamp.wantsLayer = true
        lamp.layer?.cornerRadius = Self.lampSize / 2
        addSubview(lamp)
        addSubview(countLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(count: Int, color: NSColor) {
        isHidden = count == 0
        countLabel.setRetroText("\(count)", color: color)
        RetroLamp.light(lamp, color: color)
        layer?.backgroundColor = color.withAlphaComponent(0.14).cgColor
        layer?.borderColor = color.cgColor
        badgeWidth = 20 + ceil(countLabel.intrinsicContentSize.width)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        lamp.frame = NSRect(
            x: 5,
            y: floor((bounds.height - Self.lampSize) / 2),
            width: Self.lampSize,
            height: Self.lampSize
        )
        let size = countLabel.intrinsicContentSize
        countLabel.frame = NSRect(
            x: 15,
            y: floor((bounds.height - size.height) / 2),
            width: ceil(size.width),
            height: size.height
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A flat colored plate inside a tab that never takes clicks from it.
private final class WindowTabPlateView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
