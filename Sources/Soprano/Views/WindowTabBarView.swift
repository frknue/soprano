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
    private let bottomBorder = NSView()
    private var buttons: [WindowTabButton] = []
    private var activeWindowId: String?
    private var revealActiveTab = true
    private var previousViewportWidth: CGFloat = 0

    init(agentManager: AgentManager, themeManager: ThemeManager) {
        self.agentManager = agentManager
        self.themeManager = themeManager
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("window-tab-bar")
        wantsLayer = true

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = tabContainer
        addSubview(scrollView)

        addButton.identifier = NSUserInterfaceItemIdentifier("new-window-tab")
        addButton.isBordered = false
        addButton.refusesFirstResponder = true
        addButton.font = .systemFont(ofSize: 18, weight: .regular)
        addButton.target = self
        addButton.action = #selector(addWindow)
        addButton.toolTip = "New Window"
        addButton.setAccessibilityLabel("New Window")
        addSubview(addButton)

        bottomBorder.wantsLayer = true
        addSubview(bottomBorder)

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
        bottomBorder.layer?.backgroundColor = theme.colors.borderSubtle.cgColor
        addButton.contentTintColor = theme.colors.textMuted
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
        let viewportWidth = max(0, bounds.width - 44)
        scrollView.frame = NSRect(x: 6, y: 1, width: viewportWidth, height: max(0, bounds.height - 2))
        addButton.frame = NSRect(x: max(0, bounds.width - 34), y: 3, width: 28, height: 28)
        bottomBorder.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)

        var x: CGFloat = 0
        for button in buttons {
            button.frame = NSRect(x: x, y: 3, width: button.tabWidth, height: 26)
            x += button.tabWidth + 4
        }
        let documentWidth = max(viewportWidth, max(0, x - 4))
        tabContainer.setFrameSize(NSSize(width: documentWidth, height: max(0, bounds.height - 2)))
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
}

private final class WindowTabButton: NSButton {
    let windowId: String
    private let onSelect: () -> Void
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
        layer?.cornerRadius = 4
        target = self
        action = #selector(selectWindow)
        setAccessibilityRole(.radioButton)
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
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = .left
        attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: isSelected ? .bold : .medium),
                .foregroundColor: isSelected ? theme.colors.accent : theme.colors.textMuted,
                .paragraphStyle: paragraph,
            ]
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
        let indicatorWidth = agents.isEmpty ? 0 : agentBadge.badgeWidth + 8
        (cell as? WindowTabButtonCell)?.trailingInset = indicatorWidth
        tabWidth = min(200, max(72, ceil(attributedTitle.size().width) + 24)) + indicatorWidth
        layer?.backgroundColor = isSelected ? theme.colors.bgSelectedStrong.cgColor : NSColor.clear.cgColor
        layer?.borderWidth = isSelected ? 1 : 0
        layer?.borderColor = theme.colors.railMuted.cgColor
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
    private let icon = NSImageView()
    private let countLabel = NSTextField(labelWithString: "")
    private(set) var badgeWidth: CGFloat = 28

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("window-agent-badge")
        wantsLayer = true
        layer?.cornerRadius = 4
        icon.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 9, weight: .medium)
        addSubview(icon)
        countLabel.font = .monospacedSystemFont(ofSize: 9, weight: .semibold)
        addSubview(countLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(count: Int, color: NSColor) {
        isHidden = count == 0
        countLabel.stringValue = "\(count)"
        countLabel.textColor = color
        icon.contentTintColor = color
        layer?.backgroundColor = color.withAlphaComponent(0.14).cgColor
        badgeWidth = 22 + ceil(countLabel.intrinsicContentSize.width)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 5, y: 3, width: 10, height: 10)
        let size = countLabel.intrinsicContentSize
        countLabel.frame = NSRect(
            x: 17,
            y: floor((bounds.height - size.height) / 2),
            width: ceil(size.width),
            height: size.height
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
