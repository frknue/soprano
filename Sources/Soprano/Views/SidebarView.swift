import AppKit

/// cmux-style persistent sidebar: PANES header, rich pane rows, footer.
final class SidebarView: NSView {
    let agentManager: AgentManager
    let sessionManager: SessionManager
    let themeManager: ThemeManager
    let gitBranchMonitor: GitBranchMonitor

    var onSettingsRequested: (() -> Void)?

    static let width: CGFloat = 220

    private var contentContainer: NSView!
    private var headerLabel: NSTextField!
    private var scrollView: NSScrollView!
    private var listContentView: NSView!
    private var rowsStack: NSStackView!
    private var footerView: NSView!
    private var footerSeparator: NSView!
    private var trailingBorder: NSView!
    private var settingsButton: NSButton!

    init(
        agentManager: AgentManager,
        sessionManager: SessionManager,
        themeManager: ThemeManager,
        gitBranchMonitor: GitBranchMonitor
    ) {
        self.agentManager = agentManager
        self.sessionManager = sessionManager
        self.themeManager = themeManager
        self.gitBranchMonitor = gitBranchMonitor
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        setupViews()
        agentManager.addObserver(id: "SidebarView") { [weak self] in
            self?.refresh()
        }
        sessionManager.addObserver(id: "SidebarView-sessions") { [weak self] in
            self?.refresh()
        }
        gitBranchMonitor.onChange = { [weak self] in
            self?.refresh()
        }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        agentManager.removeObserver(id: "SidebarView")
        sessionManager.removeObserver(id: "SidebarView-sessions")
    }

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false

        // Fixed-width container pinned to the leading edge: the outer width
        // constraint can animate to 0 and clip instead of fighting content
        // constraints (masksToBounds is set above).
        contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentContainer)

        headerLabel = NSTextField(labelWithString: "PANES")
        headerLabel.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(headerLabel)

        scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(scrollView)

        listContentView = NSView()
        listContentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = listContentView

        rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 4
        rowsStack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 10, right: 10)
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        listContentView.addSubview(rowsStack)

        footerView = NSView()
        footerView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(footerView)

        footerSeparator = NSView()
        footerSeparator.wantsLayer = true
        footerSeparator.translatesAutoresizingMaskIntoConstraints = false
        footerView.addSubview(footerSeparator)

        settingsButton = makeIconButton(
            symbolName: "gearshape",
            accessibilityLabel: "Settings",
            action: #selector(settingsClicked)
        )
        footerView.addSubview(settingsButton)

        trailingBorder = NSView()
        trailingBorder.wantsLayer = true
        trailingBorder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(trailingBorder)

        NSLayoutConstraint.activate([
            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.topAnchor.constraint(equalTo: topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentContainer.widthAnchor.constraint(equalToConstant: Self.width),

            headerLabel.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: 14),
            headerLabel.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: 14),

            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footerView.topAnchor),

            listContentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            listContentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            listContentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            listContentView.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            listContentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            rowsStack.leadingAnchor.constraint(equalTo: listContentView.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: listContentView.trailingAnchor),
            rowsStack.topAnchor.constraint(equalTo: listContentView.topAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: listContentView.bottomAnchor),

            footerView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            footerView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            footerView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            footerView.heightAnchor.constraint(equalToConstant: 36),

            footerSeparator.topAnchor.constraint(equalTo: footerView.topAnchor),
            footerSeparator.leadingAnchor.constraint(equalTo: footerView.leadingAnchor),
            footerSeparator.trailingAnchor.constraint(equalTo: footerView.trailingAnchor),
            footerSeparator.heightAnchor.constraint(equalToConstant: 1),

            settingsButton.trailingAnchor.constraint(equalTo: footerView.trailingAnchor, constant: -8),
            settingsButton.centerYAnchor.constraint(equalTo: footerView.centerYAnchor),

            trailingBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            trailingBorder.topAnchor.constraint(equalTo: topAnchor),
            trailingBorder.bottomAnchor.constraint(equalTo: bottomAnchor),
            trailingBorder.widthAnchor.constraint(equalToConstant: 1),
        ])
    }

    private func makeIconButton(
        symbolName: String,
        accessibilityLabel: String,
        action: Selector
    ) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.isBordered = false
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        button.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: accessibilityLabel
        )?.withSymbolConfiguration(configuration)
        button.imagePosition = .imageOnly
        button.toolTip = accessibilityLabel
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 26),
            button.heightAnchor.constraint(equalToConstant: 26),
        ])
        return button
    }

    @objc private func settingsClicked() {
        onSettingsRequested?()
    }

    // MARK: - Refresh

    func refreshTheme() {
        refresh()
    }

    private func refresh() {
        let theme = themeManager.currentTheme
        layer?.backgroundColor = theme.colors.bgPanel.cgColor
        headerLabel.textColor = theme.colors.textMuted
        footerSeparator.layer?.backgroundColor = theme.colors.borderSubtle.cgColor
        trailingBorder.layer?.backgroundColor = theme.colors.borderSubtle.cgColor
        settingsButton.contentTintColor = theme.colors.textMuted

        // Reconcile watchers first so rows read freshly-invalidated caches.
        gitBranchMonitor.setWatchedPaths(watchedCwds())
        rebuildRows(theme: theme)
    }

    private func rebuildRows(theme: AppTheme) {
        for view in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for pane in sortedPanes() {
            let row = SidebarPaneRowView(theme: theme)
            row.configure(
                title: pane.activeTab?.title ?? "Pane",
                branch: branchForPane(pane),
                dotColor: paneStatusColor(for: pane, theme: theme),
                tabCount: pane.tabs.count,
                highlighted: pane.id == agentManager.activePaneId,
                onSelect: { [weak self] in
                    self?.agentManager.focusPane(pane.id)
                },
                onClose: { [weak self] in
                    self?.agentManager.closePane(pane.id)
                }
            )
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor, constant: -20).isActive = true
        }
    }

    // MARK: - Branch Resolution

    private func branchForPane(_ pane: PaneState) -> String? {
        guard let tab = pane.activeTab, let cwd = effectiveCwd(for: tab) else { return nil }
        return gitBranchMonitor.branch(for: cwd)
    }

    /// The directory the pane's process actually started in: explicit tab cwd,
    /// else the profile's cwd, else the app process's cwd (ghostty inherits it
    /// when workingDirectory is unset).
    private func effectiveCwd(for tab: PaneTab) -> String? {
        if let cwd = tab.cwd {
            return cwd
        }
        if let agent = tab.agent,
           let profileCwd = DefaultAgents.profile(for: agent.profileId)?.cwd
        {
            return profileCwd
        }
        return FileManager.default.currentDirectoryPath
    }

    private func watchedCwds() -> [String] {
        agentManager.panes.values.compactMap { pane in
            pane.activeTab.flatMap { effectiveCwd(for: $0) }
        }
    }

    // MARK: - Status & Sorting

    private func paneStatusColor(for pane: PaneState, theme: AppTheme) -> NSColor {
        guard let tab = pane.activeTab else { return theme.colors.gray }
        if let agent = tab.agent {
            switch agent.status {
            case .idle:
                return theme.colors.textMuted
            case .starting:
                return theme.colors.yellow
            case .running:
                return theme.colors.success
            case .error:
                return theme.colors.danger
            case .stopped:
                return theme.colors.gray
            }
        }
        switch tab.type {
        case .terminal:
            return theme.colors.accent
        case .agent:
            return theme.colors.textMuted
        }
    }

    private func sortedPanes() -> [PaneState] {
        agentManager.panes.values.sorted { lhs, rhs in
            paneSortKey(lhs.id) < paneSortKey(rhs.id)
        }
    }

    private func paneSortKey(_ paneId: String) -> Int {
        let numberPart = paneId.split(separator: "-").last
        if let numberPart, let number = Int(numberPart) {
            return number
        }
        return Int.max
    }
}

// MARK: - Pane Row

private final class SidebarPaneRowView: NSView {
    private let dotView = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let badgeContainer = NSView()
    private let badgeLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton(title: "×", target: nil, action: nil)
    private let branchLabel = NSTextField(labelWithString: "")
    private var titleBottomConstraint: NSLayoutConstraint!
    private var branchConstraints: [NSLayoutConstraint] = []
    private var onSelect: (() -> Void)?
    private var onClose: (() -> Void)?
    private let theme: AppTheme

    init(theme: AppTheme) {
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        translatesAutoresizingMaskIntoConstraints = false
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setup() {
        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 3
        dotView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dotView)

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = theme.colors.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        badgeContainer.wantsLayer = true
        badgeContainer.layer?.cornerRadius = 8
        badgeContainer.layer?.backgroundColor = theme.colors.bgRaised.cgColor
        badgeContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badgeContainer)

        badgeLabel.font = .monospacedSystemFont(ofSize: 9, weight: .bold)
        badgeLabel.textColor = theme.colors.textMuted
        badgeLabel.alignment = .center
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeContainer.addSubview(badgeLabel)

        closeButton.target = self
        closeButton.action = #selector(handleClose)
        closeButton.isBordered = false
        closeButton.font = .systemFont(ofSize: 14, weight: .regular)
        closeButton.contentTintColor = theme.colors.textMuted
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        branchLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        branchLabel.textColor = theme.colors.textMuted
        branchLabel.lineBreakMode = .byTruncatingTail
        branchLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(branchLabel)

        titleBottomConstraint = titleLabel.bottomAnchor.constraint(
            equalTo: bottomAnchor, constant: -7
        )
        branchConstraints = [
            branchLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            branchLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            branchLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            branchLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ]

        NSLayoutConstraint.activate([
            dotView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            dotView.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            dotView.widthAnchor.constraint(equalToConstant: 6),
            dotView.heightAnchor.constraint(equalToConstant: 6),

            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            titleLabel.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: badgeContainer.leadingAnchor, constant: -6
            ),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),

            badgeContainer.trailingAnchor.constraint(
                equalTo: closeButton.leadingAnchor, constant: -4
            ),
            badgeContainer.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            badgeContainer.heightAnchor.constraint(equalToConstant: 16),

            badgeLabel.leadingAnchor.constraint(
                equalTo: badgeContainer.leadingAnchor, constant: 5
            ),
            badgeLabel.trailingAnchor.constraint(
                equalTo: badgeContainer.trailingAnchor, constant: -5
            ),
            badgeLabel.centerYAnchor.constraint(equalTo: badgeContainer.centerYAnchor),
        ])
    }

    func configure(
        title: String,
        branch: String?,
        dotColor: NSColor,
        tabCount: Int,
        highlighted: Bool,
        onSelect: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.onSelect = onSelect
        self.onClose = onClose
        titleLabel.stringValue = title
        dotView.layer?.backgroundColor = dotColor.cgColor
        badgeContainer.isHidden = tabCount <= 1
        badgeLabel.stringValue = "\(tabCount)"
        closeButton.contentTintColor = highlighted
            ? theme.colors.textPrimary
            : theme.colors.textMuted
        layer?.backgroundColor = highlighted
            ? theme.colors.bgRaised.cgColor
            : NSColor.clear.cgColor

        if let branch {
            branchLabel.stringValue = "⎇ \(branch)"
            branchLabel.isHidden = false
            titleBottomConstraint.isActive = false
            NSLayoutConstraint.activate(branchConstraints)
        } else {
            branchLabel.stringValue = ""
            branchLabel.isHidden = true
            NSLayoutConstraint.deactivate(branchConstraints)
            titleBottomConstraint.isActive = true
        }
    }

    @objc private func handleClose() {
        onClose?()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isInteractiveSubview(hitTest(point)) {
            super.mouseDown(with: event)
            return
        }
        onSelect?()
    }

    private func isInteractiveSubview(_ view: NSView?) -> Bool {
        var current = view
        while let candidate = current, candidate !== self {
            if candidate is NSControl {
                return true
            }
            current = candidate.superview
        }
        return false
    }
}
