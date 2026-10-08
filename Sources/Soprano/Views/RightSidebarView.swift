import AppKit

/// Orca's right sidebar: a resizable column on the window's trailing edge with
/// a tab strip and the active tab's panel. Explorer is the only tab so far.
///
/// Like the left sidebar it collapses to zero width rather than leaving the
/// hierarchy, so the explorer keeps its expanded folders and caches; it only
/// reads and watches the disk while open and in a window.
final class RightSidebarView: NSView {
    enum Tab: CaseIterable {
        case explorer

        var title: String {
            switch self {
            case .explorer: "Explorer"
            }
        }

        var symbolName: String {
            switch self {
            case .explorer: "doc.on.doc"
            }
        }
    }

    /// Matches the window tab bar so both bottom rules run as one line.
    static let headerHeight = WindowTabBarView.height

    let explorerView: FileExplorerView
    var onCloseRequested: (() -> Void)?

    private let themeManager: ThemeManager
    private let contentContainer = NSView()
    private var contentWidthConstraint: NSLayoutConstraint!
    private let header = NSView()
    private var tabButtons: [Tab: RightSidebarTabButton] = [:]
    private let headingView: RetroHeadingView
    private var closeButton: RetroIconButton!
    private let headerRule = RetroRuleView(axis: .horizontal, style: .double)
    private let leadingBorder = RetroRuleView(axis: .vertical, style: .double)
    private var isResizeHighlighted = false
    private(set) var isOpen = false
    private(set) var activeTab: Tab = .explorer

    init(agentManager: AgentManager, themeManager: ThemeManager, defaults: UserDefaults = .standard) {
        self.themeManager = themeManager
        explorerView = FileExplorerView(
            agentManager: agentManager,
            themeManager: themeManager,
            defaults: defaults
        )
        headingView = RetroHeadingView(title: Tab.explorer.title, theme: themeManager.currentTheme)
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("right-sidebar")
        wantsLayer = true
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        setupViews()
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

        var previousTrailing = header.leadingAnchor
        for tab in Tab.allCases {
            let button = RightSidebarTabButton(tab: tab, target: self, action: #selector(tabClicked(_:)))
            header.addSubview(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: previousTrailing, constant: tab == .explorer ? 4 : 0),
                button.topAnchor.constraint(equalTo: header.topAnchor),
                button.bottomAnchor.constraint(equalTo: headerRule.topAnchor),
            ])
            previousTrailing = button.trailingAnchor
            tabButtons[tab] = button
        }

        header.addSubview(headingView)
        closeButton = RetroIconButton(
            symbolName: "sidebar.right",
            accessibilityLabel: "Toggle Right Sidebar",
            target: self,
            action: #selector(closeClicked)
        )
        header.addSubview(closeButton)

        contentContainer.addSubview(explorerView)
        addSubview(leadingBorder)

        contentWidthConstraint = contentContainer.widthAnchor.constraint(
            equalToConstant: SidebarWidthStore.right.defaultWidth - Retro.doubleRule
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

            headingView.leadingAnchor.constraint(equalTo: previousTrailing, constant: 8),
            headingView.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6),
            headingView.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(
                equalTo: header.topAnchor,
                constant: (Self.headerHeight - Retro.doubleRule) / 2
            ),

            headerRule.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            headerRule.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            headerRule.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            headerRule.heightAnchor.constraint(equalToConstant: Retro.doubleRule),

            explorerView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            explorerView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            explorerView.topAnchor.constraint(equalTo: header.bottomAnchor),
            explorerView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),

            leadingBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            leadingBorder.topAnchor.constraint(equalTo: topAnchor),
            leadingBorder.bottomAnchor.constraint(equalTo: bottomAnchor),
            leadingBorder.widthAnchor.constraint(equalToConstant: Retro.doubleRule),
        ])
    }

    /// Width of the sidebar's content, kept in step with the dragged width.
    func setContentWidth(_ width: CGFloat) {
        contentWidthConstraint.constant = max(0, width - Retro.doubleRule)
    }

    /// Accents the leading border while the resize handle is hovered or dragged.
    func setResizeHighlighted(_ isHighlighted: Bool) {
        isResizeHighlighted = isHighlighted
        leadingBorder.color = isHighlighted
            ? themeManager.currentTheme.colors.accent
            : themeManager.currentTheme.colors.borderStrong
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
        explorerView.setActive(isOpen && window != nil && activeTab == .explorer)
    }

    func refreshTheme() {
        let theme = themeManager.currentTheme
        let colors = theme.colors
        layer?.backgroundColor = colors.bgPanel.cgColor
        headingView.apply(theme: theme)
        headerRule.color = colors.borderStrong
        setResizeHighlighted(isResizeHighlighted)
        closeButton.setTints(normal: colors.textMuted, hover: colors.accent)
        for (tab, button) in tabButtons {
            button.apply(colors: colors, isActive: tab == activeTab)
        }
        explorerView.applyTheme()
    }

    @objc private func tabClicked(_ sender: RightSidebarTabButton) {
        activeTab = sender.tab
        headingView.title = sender.tab.title
        refreshTheme()
        updateActivity()
    }

    @objc private func closeClicked() {
        onCloseRequested?()
    }
}

/// An icon tab in the sidebar header: muted until active, then lit with an
/// accent bar along its bottom edge, like Orca's activity bar.
final class RightSidebarTabButton: NSButton {
    let tab: RightSidebarView.Tab
    private var colors: ThemeColors?
    private var isActiveTab = false

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
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        toolTip = tab.title
        setAccessibilityLabel(tab.title)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 34).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(colors: ThemeColors, isActive: Bool) {
        self.colors = colors
        isActiveTab = isActive
        contentTintColor = isActive ? colors.textPrimary : colors.textMuted
        setAccessibilityValue(isActive ? "selected" : nil)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isActiveTab, let colors else { return }
        colors.accent.setFill()
        let y = isFlipped ? bounds.maxY - 2 : 0
        NSRect(x: bounds.width * 0.25, y: y, width: bounds.width * 0.5, height: 2).fill()
    }
}
