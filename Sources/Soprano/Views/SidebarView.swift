import AppKit

/// Left sidebar with section icons and expandable panels.
final class SidebarView: NSView {
    let agentManager: AgentManager
    let sessionManager: SessionManager
    let themeManager: ThemeManager

    /// Currently active sidebar section (nil = collapsed).
    var activeSection: SidebarSection? {
        didSet {
            if oldValue != activeSection {
                onExpandedChanged?(activeSection != nil)
            }
            refresh()
        }
    }

    var onExpandedChanged: ((Bool) -> Void)?
    var onSettingsRequested: (() -> Void)?

    private static let activityBarWidth: CGFloat = 48
    private static let detailPanelWidth: CGFloat = 200

    private var activityBar: NSView!
    private var topButtonStack: NSStackView!
    private var bottomButtonStack: NSStackView!
    private var detailPanel: NSView!
    private var detailHeaderLabel: NSTextField!
    private var detailScrollView: NSScrollView!
    private var detailContentView: NSView!
    private var detailStack: NSStackView!

    private var sectionButtons: [SidebarSection: NSButton] = [:]

    init(agentManager: AgentManager, sessionManager: SessionManager, themeManager: ThemeManager) {
        self.agentManager = agentManager
        self.sessionManager = sessionManager
        self.themeManager = themeManager
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

        activityBar = NSView()
        activityBar.wantsLayer = true
        activityBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(activityBar)

        topButtonStack = NSStackView()
        topButtonStack.orientation = .vertical
        topButtonStack.alignment = .centerX
        topButtonStack.spacing = 6
        topButtonStack.translatesAutoresizingMaskIntoConstraints = false
        activityBar.addSubview(topButtonStack)

        for section in SidebarSection.activitySections {
            let button = makeSectionButton(section)
            sectionButtons[section] = button
            topButtonStack.addArrangedSubview(button)
        }

        bottomButtonStack = NSStackView()
        bottomButtonStack.orientation = .vertical
        bottomButtonStack.alignment = .centerX
        bottomButtonStack.translatesAutoresizingMaskIntoConstraints = false
        activityBar.addSubview(bottomButtonStack)

        let settingsButton = makeSectionButton(.settings)
        sectionButtons[.settings] = settingsButton
        bottomButtonStack.addArrangedSubview(settingsButton)

        detailPanel = NSView()
        detailPanel.wantsLayer = true
        detailPanel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(detailPanel)

        detailHeaderLabel = NSTextField(labelWithString: "")
        detailHeaderLabel.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        detailHeaderLabel.translatesAutoresizingMaskIntoConstraints = false
        detailPanel.addSubview(detailHeaderLabel)

        detailScrollView = NSScrollView()
        detailScrollView.drawsBackground = false
        detailScrollView.hasVerticalScroller = true
        detailScrollView.hasHorizontalScroller = false
        detailScrollView.translatesAutoresizingMaskIntoConstraints = false
        detailPanel.addSubview(detailScrollView)

        detailContentView = NSView()
        detailContentView.translatesAutoresizingMaskIntoConstraints = false
        detailScrollView.documentView = detailContentView

        detailStack = NSStackView()
        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 6
        detailStack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 10, right: 10)
        detailStack.translatesAutoresizingMaskIntoConstraints = false
        detailContentView.addSubview(detailStack)

        NSLayoutConstraint.activate([
            activityBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            activityBar.topAnchor.constraint(equalTo: topAnchor),
            activityBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            activityBar.widthAnchor.constraint(equalToConstant: Self.activityBarWidth),

            topButtonStack.topAnchor.constraint(equalTo: activityBar.topAnchor, constant: 14),
            topButtonStack.centerXAnchor.constraint(equalTo: activityBar.centerXAnchor),

            bottomButtonStack.bottomAnchor.constraint(equalTo: activityBar.bottomAnchor, constant: -12),
            bottomButtonStack.centerXAnchor.constraint(equalTo: activityBar.centerXAnchor),

            detailPanel.leadingAnchor.constraint(equalTo: activityBar.trailingAnchor),
            detailPanel.topAnchor.constraint(equalTo: topAnchor),
            detailPanel.bottomAnchor.constraint(equalTo: bottomAnchor),
            detailPanel.widthAnchor.constraint(equalToConstant: Self.detailPanelWidth),

            detailHeaderLabel.topAnchor.constraint(equalTo: detailPanel.topAnchor, constant: 12),
            detailHeaderLabel.leadingAnchor.constraint(equalTo: detailPanel.leadingAnchor, constant: 12),
            detailHeaderLabel.trailingAnchor.constraint(equalTo: detailPanel.trailingAnchor, constant: -12),

            detailScrollView.topAnchor.constraint(equalTo: detailHeaderLabel.bottomAnchor, constant: 10),
            detailScrollView.leadingAnchor.constraint(equalTo: detailPanel.leadingAnchor),
            detailScrollView.trailingAnchor.constraint(equalTo: detailPanel.trailingAnchor),
            detailScrollView.bottomAnchor.constraint(equalTo: detailPanel.bottomAnchor),

            detailContentView.leadingAnchor.constraint(equalTo: detailScrollView.contentView.leadingAnchor),
            detailContentView.trailingAnchor.constraint(equalTo: detailScrollView.contentView.trailingAnchor),
            detailContentView.topAnchor.constraint(equalTo: detailScrollView.contentView.topAnchor),
            detailContentView.bottomAnchor.constraint(equalTo: detailScrollView.contentView.bottomAnchor),
            detailContentView.widthAnchor.constraint(equalTo: detailScrollView.contentView.widthAnchor),

            detailStack.leadingAnchor.constraint(equalTo: detailContentView.leadingAnchor),
            detailStack.trailingAnchor.constraint(equalTo: detailContentView.trailingAnchor),
            detailStack.topAnchor.constraint(equalTo: detailContentView.topAnchor),
            detailStack.bottomAnchor.constraint(equalTo: detailContentView.bottomAnchor),
        ])
    }

    private func makeSectionButton(_ section: SidebarSection) -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(sectionClicked(_:)))
        button.tag = section.rawValue
        button.isBordered = false
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        button.image = NSImage(
            systemSymbolName: section.symbolName,
            accessibilityDescription: section.label
        )?.withSymbolConfiguration(configuration)
        button.imageScaling = .scaleProportionallyDown
        button.imagePosition = .imageOnly
        button.contentTintColor = themeManager.currentTheme.colors.textMuted
        button.toolTip = section.label
        button.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 36),
            button.heightAnchor.constraint(equalToConstant: 36),
        ])

        return button
    }

    @objc private func sectionClicked(_ sender: NSButton) {
        guard let section = SidebarSection(rawValue: sender.tag) else { return }
        if section == .settings {
            activeSection = nil
            onSettingsRequested?()
            return
        }
        activeSection = activeSection == section ? nil : section
    }

    private func refresh() {
        let theme = themeManager.currentTheme

        layer?.backgroundColor = theme.colors.bgPanel.cgColor
        activityBar.layer?.backgroundColor = theme.colors.bgPanel.cgColor
        detailPanel.layer?.backgroundColor = theme.colors.bgBase.cgColor

        for section in SidebarSection.activitySections {
            let isActive = activeSection == section
            sectionButtons[section]?.contentTintColor = isActive ? theme.colors.accent : theme.colors.textMuted
        }
        sectionButtons[.settings]?.contentTintColor = theme.colors.textMuted

        detailPanel.isHidden = activeSection == nil
        guard let section = activeSection else {
            clearDetailContent()
            return
        }

        detailHeaderLabel.textColor = theme.colors.textMuted
        detailHeaderLabel.stringValue = section.label.uppercased()
        rebuildDetailContent(for: section)
    }

    func refreshTheme() {
        refresh()
    }

    private func rebuildDetailContent(for section: SidebarSection) {
        clearDetailContent()
        switch section {
        case .agents:
            buildAgentsPanel()
        case .panes:
            buildPanesPanel()
        case .sessions:
            buildSessionsPanel()
        case .settings:
            break
        }
    }

    private func clearDetailContent() {
        for view in detailStack.arrangedSubviews {
            detailStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func buildAgentsPanel() {
        addDetailSectionHeader("AI Agents")
        let profiles = DefaultAgents.all.filter { $0.id != "terminal" }
        for profile in profiles {
            let row = makeAgentRow(profile)
            detailStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: detailStack.widthAnchor, constant: -20).isActive = true
        }

        detailStack.addArrangedSubview(makeSpacer(height: 8))
        addDetailSectionHeader("Tools")

        let terminalRow = makeToolRow(
            title: "Terminal",
            subtitle: "Open shell pane"
        ) { [weak self] in
            _ = self?.agentManager.spawnTerminal()
        }
        detailStack.addArrangedSubview(terminalRow)
        terminalRow.widthAnchor.constraint(equalTo: detailStack.widthAnchor, constant: -20).isActive = true
    }

    private func buildPanesPanel() {
        addDetailSectionHeader("Open Panes (\(agentManager.paneCount))")

        let panes = sortedPanes()
        if panes.isEmpty {
            buildStubPanel(message: "No open panes")
            return
        }

        let theme = themeManager.currentTheme
        for pane in panes {
            let row = makePaneRow(pane, theme: theme)
            detailStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: detailStack.widthAnchor, constant: -20).isActive = true
        }
    }

    private func buildSessionsPanel() {
        let sessions = sessionManager.sessions
        addDetailSectionHeader("Saved Sessions (\(sessions.count))")

        if sessions.isEmpty {
            buildStubPanel(message: "No saved sessions")
            return
        }

        let theme = themeManager.currentTheme
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .short

        for session in sessions {
            let dateString = dateFormatter.string(from: session.savedAt)
            let row = SidebarActionRowView(theme: theme)
            row.configure(
                title: session.name,
                subtitle: dateString,
                dotColor: nil,
                highlighted: false,
                onClick: { [weak self] in
                    self?.sessionManager.loadSession(session.id)
                }
            )
            detailStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: detailStack.widthAnchor, constant: -20).isActive = true
        }
    }

    private func buildStubPanel(message: String) {
        let theme = themeManager.currentTheme
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: 12, weight: .regular)
        label.textColor = theme.colors.textMuted
        label.maximumNumberOfLines = 0
        detailStack.addArrangedSubview(label)
    }

    private func addDetailSectionHeader(_ text: String) {
        let theme = themeManager.currentTheme
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
        label.textColor = theme.colors.textMuted
        label.alignment = .left
        label.setContentHuggingPriority(.required, for: .vertical)
        detailStack.addArrangedSubview(label)
    }

    private func makeAgentRow(_ profile: AgentProfile) -> NSView {
        makeRow(
            title: profile.name,
            subtitle: profile.description,
            dotColor: profile.nsColor
        ) { [weak self] in
            _ = self?.agentManager.spawnAgent(profile.id)
        }
    }

    private func makeToolRow(title: String, subtitle: String, onClick: @escaping () -> Void) -> NSView {
        makeRow(title: title, subtitle: subtitle, dotColor: nil, onClick: onClick)
    }

    private func makePaneRow(_ pane: PaneState, theme: AppTheme) -> NSView {
        let activeTab = pane.activeTab
        let title = activeTab?.title ?? "Pane"
        let statusColor = paneStatusColor(for: pane, theme: theme)
        let isActive = pane.id == agentManager.activePaneId
        let row = SidebarPaneRowView(theme: theme)

        row.configure(
            title: title,
            dotColor: statusColor,
            tabCount: pane.tabs.count,
            highlighted: isActive,
            onSelect: { [weak self] in
                self?.agentManager.focusPane(pane.id)
            },
            onClose: { [weak self] in
                self?.agentManager.closePane(pane.id)
            }
        )

        return row
    }

    private func makeRow(
        title: String,
        subtitle: String,
        dotColor: NSColor?,
        onClick: @escaping () -> Void
    ) -> NSView {
        let theme = themeManager.currentTheme
        let row = SidebarActionRowView(theme: theme)
        row.configure(
            title: title,
            subtitle: subtitle,
            dotColor: dotColor,
            highlighted: false,
            onClick: onClick
        )
        return row
    }

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

    private func makeSpacer(height: CGFloat) -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: height).isActive = true
        return spacer
    }
}

private final class SidebarActionRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let dotView = NSView()
    private let theme: AppTheme
    private var clickHandler: (() -> Void)?

    init(theme: AppTheme) {
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.clear.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        setup(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setup(theme: AppTheme) {
        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 3
        dotView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dotView)

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = theme.colors.textPrimary
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        subtitleLabel.font = .systemFont(ofSize: 10, weight: .regular)
        subtitleLabel.textColor = theme.colors.textMuted
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 38),

            dotView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            dotView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotView.widthAnchor.constraint(equalToConstant: 6),
            dotView.heightAnchor.constraint(equalToConstant: 6),

            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            titleLabel.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            subtitleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])

        let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        addGestureRecognizer(clickGesture)
    }

    func configure(
        title: String,
        subtitle: String,
        dotColor: NSColor?,
        highlighted: Bool,
        onClick: @escaping () -> Void
    ) {
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        dotView.isHidden = dotColor == nil
        dotView.layer?.backgroundColor = dotColor?.cgColor
        clickHandler = onClick
        layer?.backgroundColor = highlighted ? theme.colors.bgRaised.cgColor : NSColor.clear.cgColor
    }

    @objc private func handleClick() {
        clickHandler?()
    }
}

private final class SidebarPaneRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let dotView = NSView()
    private let badgeLabel = NSTextField(labelWithString: "")
    private let badgeContainer = NSView()
    private let closeButton = NSButton(title: "×", target: nil, action: nil)
    private var onSelect: (() -> Void)?
    private var onClose: (() -> Void)?
    private var theme: AppTheme

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

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),

            dotView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            dotView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotView.widthAnchor.constraint(equalToConstant: 6),
            dotView.heightAnchor.constraint(equalToConstant: 6),

            titleLabel.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),

            badgeContainer.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            badgeContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeContainer.heightAnchor.constraint(equalToConstant: 16),

            badgeLabel.leadingAnchor.constraint(equalTo: badgeContainer.leadingAnchor, constant: 5),
            badgeLabel.trailingAnchor.constraint(equalTo: badgeContainer.trailingAnchor, constant: -5),
            badgeLabel.centerYAnchor.constraint(equalTo: badgeContainer.centerYAnchor),

            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: badgeContainer.leadingAnchor, constant: -6),
        ])

    }

    func configure(
        title: String,
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

        badgeContainer.layer?.backgroundColor = theme.colors.bgRaised.cgColor
        closeButton.contentTintColor = highlighted ? theme.colors.textPrimary : theme.colors.textMuted
        layer?.backgroundColor = highlighted
            ? theme.colors.bgRaised.cgColor
            : NSColor.clear.cgColor
    }

    @objc private func handleSelect() {
        onSelect?()
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

// MARK: - Sidebar Section

enum SidebarSection: Int, CaseIterable {
    case agents = 0
    case panes
    case sessions
    case settings

    static var activitySections: [SidebarSection] {
        [.agents, .panes, .sessions]
    }

    var label: String {
        switch self {
        case .agents: return "Agents"
        case .panes: return "Panes"
        case .sessions: return "Sessions"
        case .settings: return "Settings"
        }
    }

    var symbolName: String {
        switch self {
        case .agents: return "command.square"
        case .panes: return "square.split.2x2"
        case .sessions: return "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .settings: return "gearshape"
        }
    }
}
