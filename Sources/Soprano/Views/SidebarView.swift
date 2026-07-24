import AppKit

/// Persistent sidebar showing collapsible logical windows and their panes.
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
    private var plusButton: NSButton!
    private var sessionsButton: NSButton!
    private var collapsedWindowIds: Set<String> = []
    private var expandedPaneDepthIds: Set<String> = []
    private var isControlKeyHeld = false

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
        gitBranchMonitor.onChange = nil
    }

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false

        // Fixed-width container pinned to the leading edge: the outer width
        // constraint can animate to 0 and clip instead of fighting content
        // constraints (masksToBounds is set above).
        contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentContainer)

        headerLabel = NSTextField(labelWithString: "WINDOWS")
        headerLabel.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(headerLabel)

        plusButton = makeIconButton(
            symbolName: "plus",
            accessibilityLabel: "New Window or Pane",
            action: #selector(plusClicked)
        )
        contentContainer.addSubview(plusButton)

        scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(scrollView)

        listContentView = FlippedView()
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

        sessionsButton = makeIconButton(
            symbolName: "clock.arrow.trianglehead.counterclockwise.rotate.90",
            accessibilityLabel: "Sessions",
            action: #selector(sessionsClicked)
        )
        footerView.addSubview(sessionsButton)

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
            listContentView.bottomAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.bottomAnchor),
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

            plusButton.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -8),
            plusButton.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),

            sessionsButton.leadingAnchor.constraint(equalTo: footerView.leadingAnchor, constant: 8),
            sessionsButton.centerYAnchor.constraint(equalTo: footerView.centerYAnchor),

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

    func setControlKeyHeld(_ isHeld: Bool) {
        guard isControlKeyHeld != isHeld else { return }
        isControlKeyHeld = isHeld
        rebuildRows(theme: themeManager.currentTheme)
    }

    @objc private func settingsClicked() {
        onSettingsRequested?()
    }

    // MARK: - Menus

    @objc private func plusClicked() {
        let menu = NSMenu()
        let windowItem = NSMenuItem(
            title: "New Window",
            action: #selector(newWindowClicked),
            keyEquivalent: ""
        )
        windowItem.target = self
        menu.addItem(windowItem)
        menu.addItem(.separator())
        for profile in DefaultAgents.all where profile.id != "terminal" {
            let item = NSMenuItem(
                title: "New \(profile.name) Pane",
                action: #selector(spawnMenuItemClicked(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = profile.id
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let terminalItem = NSMenuItem(
            title: "New Terminal Pane",
            action: #selector(spawnMenuItemClicked(_:)),
            keyEquivalent: ""
        )
        terminalItem.target = self
        terminalItem.representedObject = "terminal"
        menu.addItem(terminalItem)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -2), in: plusButton)
    }

    @objc private func newWindowClicked() {
        _ = agentManager.createWindow()
    }

    @objc private func spawnMenuItemClicked(_ sender: NSMenuItem) {
        guard let profileId = sender.representedObject as? String else { return }
        _ = agentManager.spawnAgent(profileId)
    }

    @objc private func sessionsClicked() {
        let menu = NSMenu()
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .short
        if sessionManager.sessions.isEmpty {
            menu.addItem(NSMenuItem(title: "No Saved Sessions", action: nil, keyEquivalent: ""))
        }
        for session in sessionManager.sessions {
            let item = NSMenuItem(
                title: "\(session.name) — \(dateFormatter.string(from: session.savedAt))",
                action: #selector(loadSessionItemClicked(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = session.id
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let saveItem = NSMenuItem(
            title: "Save Session As…",
            action: #selector(saveSessionClicked),
            keyEquivalent: ""
        )
        saveItem.target = self
        menu.addItem(saveItem)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -2), in: sessionsButton)
    }

    @objc private func loadSessionItemClicked(_ sender: NSMenuItem) {
        guard let sessionId = sender.representedObject as? String else { return }
        sessionManager.loadSession(sessionId)
    }

    @objc private func saveSessionClicked() {
        saveSessionAs()
    }

    func saveSessionAs() {
        let alert = NSAlert()
        alert.messageText = "Save Session"
        alert.informativeText = "Name this workspace session:"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "Session name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        sessionManager.saveSession(name: name)
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
        plusButton.contentTintColor = theme.colors.textMuted
        sessionsButton.contentTintColor = theme.colors.textMuted

        // Reconcile watchers first so rows read freshly-invalidated caches.
        gitBranchMonitor.setWatchedPaths(watchedCwds())
        rebuildRows(theme: theme)
    }

    private func rebuildRows(theme: AppTheme) {
        let paneShortcutKeysById = Dictionary(
            uniqueKeysWithValues: agentManager.paneShortcutAssignments.map {
                ($0.paneId, $0.key)
            }
        )
        for view in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, terminalWindow) in agentManager.orderedWindows.enumerated() {
            let isExpanded = isControlKeyHeld
                || !collapsedWindowIds.contains(terminalWindow.id)
            let windowRow = SidebarWindowRowView(theme: theme)
            windowRow.configure(
                title: terminalWindow.title,
                paneCount: terminalWindow.paneIds.count,
                attentionCount: terminalWindow.paneIds.reduce(into: 0) { count, paneId in
                    count += agentManager.panes[paneId]?.tabs.filter {
                        $0.agent?.needsAttention == true
                    }.count ?? 0
                },
                shortcutNumber: index < 9 ? index + 1 : nil,
                showShortcutHint: isControlKeyHeld,
                expanded: isExpanded,
                highlighted: terminalWindow.id == agentManager.activeWindowId,
                isTitleCustom: terminalWindow.isTitleCustom,
                onToggle: { [weak self] in
                    guard let self else { return }
                    if self.collapsedWindowIds.contains(terminalWindow.id) {
                        self.collapsedWindowIds.remove(terminalWindow.id)
                    } else {
                        self.collapsedWindowIds.insert(terminalWindow.id)
                    }
                    self.refresh()
                },
                onSelect: { [weak self] in
                    self?.agentManager.activateWindow(terminalWindow.id)
                },
                onRename: { [weak self] in
                    self?.promptToRenameWindow(terminalWindow.id)
                },
                onResetTitle: { [weak self] in
                    self?.agentManager.resetWindowTitle(terminalWindow.id)
                },
                onClose: { [weak self] in
                    self?.collapsedWindowIds.remove(terminalWindow.id)
                    self?.agentManager.closeWindow(terminalWindow.id)
                }
            )
            rowsStack.addArrangedSubview(windowRow)
            windowRow.widthAnchor.constraint(
                equalTo: rowsStack.widthAnchor,
                constant: -20
            ).isActive = true

            guard isExpanded else { continue }
            for pane in agentManager.orderedPanes(in: terminalWindow.id) {
                let depthBranch = pane.activeDepthBranch
                let maximumDepth = max(0, depthBranch.count - 1)
                let hasDepth = maximumDepth > 0
                let isDepthExpanded = hasDepth && expandedPaneDepthIds.contains(pane.id)
                let row = SidebarPaneRowView(theme: theme, hierarchyIndent: 12)
                row.configure(
                    title: sidebarTitle(for: pane),
                    branch: branchForPane(pane),
                    dotColor: paneStatusColor(for: pane, theme: theme),
                    agentStatus: pane.activeTab?.agent?.status,
                    tabCount: pane.rootTabs.count,
                    depthLevel: hasDepth ? pane.activeDepth : nil,
                    maximumDepth: hasDepth ? maximumDepth : nil,
                    shortcutKey: paneShortcutKeysById[pane.id],
                    showShortcutHint: isControlKeyHeld,
                    showsDisclosure: hasDepth,
                    expanded: isDepthExpanded,
                    highlighted: pane.id == agentManager.activePaneId,
                    onToggle: { [weak self] in
                        guard let self else { return }
                        if self.expandedPaneDepthIds.contains(pane.id) {
                            self.expandedPaneDepthIds.remove(pane.id)
                        } else {
                            self.expandedPaneDepthIds.insert(pane.id)
                        }
                        self.refresh()
                    },
                    onSelect: { [weak self] in
                        self?.agentManager.focusPane(pane.id)
                    },
                    onClose: { [weak self] in
                        self?.agentManager.closePane(pane.id)
                    }
                )
                rowsStack.addArrangedSubview(row)
                row.widthAnchor.constraint(
                    equalTo: rowsStack.widthAnchor,
                    constant: -20
                ).isActive = true

                guard isDepthExpanded else { continue }
                for (depth, tab) in depthBranch.enumerated() {
                    let depthRow = SidebarPaneRowView(
                        theme: theme,
                        hierarchyIndent: 30 + CGFloat(min(depth, 4) * 6)
                    )
                    depthRow.configure(
                        title: sidebarTitle(for: tab),
                        branch: branchForTab(tab),
                        dotColor: tabStatusColor(for: tab, theme: theme),
                        agentStatus: tab.agent?.status,
                        tabCount: 1,
                        depthLevel: depth,
                        maximumDepth: maximumDepth,
                        shortcutKey: nil,
                        showShortcutHint: false,
                        showsDisclosure: false,
                        expanded: false,
                        showsClose: depth > 0,
                        highlighted: pane.id == agentManager.activePaneId
                            && pane.activeTab?.id == tab.id,
                        onToggle: {},
                        onSelect: { [weak self] in
                            self?.agentManager.focusTab(paneId: pane.id, tabId: tab.id)
                        },
                        onClose: { [weak self] in
                            self?.agentManager.removeTabFromPane(pane.id, tabId: tab.id)
                        }
                    )
                    rowsStack.addArrangedSubview(depthRow)
                    depthRow.widthAnchor.constraint(
                        equalTo: rowsStack.widthAnchor,
                        constant: -20
                    ).isActive = true
                }
            }
        }
    }

    func promptToRenameActiveWindow() {
        promptToRenameWindow(agentManager.activeWindowId)
    }

    private func promptToRenameWindow(_ windowId: String) {
        guard let terminalWindow = agentManager.windows[windowId] else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Window"
        alert.informativeText = "Choose a stable name for this window."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = terminalWindow.title
        field.selectText(nil)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        agentManager.renameWindow(windowId, to: field.stringValue)
    }

    // MARK: - Branch Resolution

    private func sidebarTitle(for pane: PaneState) -> String {
        guard let tab = pane.activeTab else { return "Pane" }
        return sidebarTitle(for: tab)
    }

    private func sidebarTitle(for tab: PaneTab) -> String {
        guard tab.type == .terminal,
              let agent = tab.agent,
              let profile = DefaultAgents.profile(for: agent.profileId)
        else { return tab.title }
        return profile.name
    }

    private func branchForPane(_ pane: PaneState) -> String? {
        guard let tab = pane.activeTab else { return nil }
        return branchForTab(tab)
    }

    private func branchForTab(_ tab: PaneTab) -> String? {
        guard let cwd = effectiveCwd(for: tab) else { return nil }
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
        agentManager.panes.values.flatMap { pane in
            pane.tabs.compactMap { effectiveCwd(for: $0) }
        }
    }

    // MARK: - Status & Sorting

    private func paneStatusColor(for pane: PaneState, theme: AppTheme) -> NSColor {
        if pane.tabs.contains(where: { $0.agent?.needsAttention == true }) {
            return theme.colors.blue
        }
        guard let tab = pane.activeTab else { return theme.colors.gray }
        return tabStatusColor(for: tab, theme: theme)
    }

    private func tabStatusColor(for tab: PaneTab, theme: AppTheme) -> NSColor {
        if let agent = tab.agent {
            switch agent.status {
            case .idle:
                return theme.colors.blue
            case .starting:
                return theme.colors.yellow
            case .running:
                return theme.colors.success
            case .waiting:
                return theme.colors.yellow
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

}

// MARK: - Window Row

private final class SidebarWindowRowView: NSView {
    private let disclosureButton = NSButton(title: "", target: nil, action: nil)
    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton(title: "×", target: nil, action: nil)
    private var onToggle: (() -> Void)?
    private var onSelect: (() -> Void)?
    private var onRename: (() -> Void)?
    private var onResetTitle: (() -> Void)?
    private var onClose: (() -> Void)?
    private let theme: AppTheme
    private var paneCount = 0
    private var attentionCount = 0
    private var shortcutNumber: Int?
    private var showShortcutHint = false

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
        disclosureButton.target = self
        disclosureButton.action = #selector(handleToggle)
        disclosureButton.isBordered = false
        disclosureButton.imagePosition = .imageOnly
        disclosureButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(disclosureButton)

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        countLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        countLabel.alignment = .right
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(countLabel)

        closeButton.target = self
        closeButton.action = #selector(handleClose)
        closeButton.isBordered = false
        closeButton.font = .systemFont(ofSize: 14, weight: .regular)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
            disclosureButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            disclosureButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosureButton.widthAnchor.constraint(equalToConstant: 24),
            disclosureButton.heightAnchor.constraint(equalToConstant: 24),

            titleLabel.leadingAnchor.constraint(equalTo: disclosureButton.trailingAnchor, constant: 2),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -6),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),

            countLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(
        title: String,
        paneCount: Int,
        attentionCount: Int,
        shortcutNumber: Int?,
        showShortcutHint: Bool,
        expanded: Bool,
        highlighted: Bool,
        isTitleCustom: Bool,
        onToggle: @escaping () -> Void,
        onSelect: @escaping () -> Void,
        onRename: @escaping () -> Void,
        onResetTitle: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.onToggle = onToggle
        self.onSelect = onSelect
        self.onRename = onRename
        self.onResetTitle = onResetTitle
        self.onClose = onClose
        self.paneCount = paneCount
        self.attentionCount = attentionCount
        self.shortcutNumber = shortcutNumber
        self.showShortcutHint = showShortcutHint
        titleLabel.stringValue = title
        updateTrailingLabel()
        let symbolName = expanded ? "chevron.down" : "chevron.right"
        disclosureButton.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: expanded ? "Collapse Window" : "Expand Window"
        )?.withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        titleLabel.textColor = highlighted ? theme.colors.textPrimary : theme.colors.textMuted
        disclosureButton.contentTintColor = theme.colors.textMuted
        closeButton.contentTintColor = highlighted
            ? theme.colors.textPrimary
            : theme.colors.textMuted
        layer?.backgroundColor = highlighted
            ? theme.colors.bgRaised.cgColor
            : NSColor.clear.cgColor

        let contextMenu = NSMenu()
        let renameItem = NSMenuItem(
            title: "Rename Window…",
            action: #selector(handleRename),
            keyEquivalent: ""
        )
        renameItem.target = self
        contextMenu.addItem(renameItem)
        if isTitleCustom {
            let resetItem = NSMenuItem(
                title: "Reset to Automatic Name",
                action: #selector(handleResetTitle),
                keyEquivalent: ""
            )
            resetItem.target = self
            contextMenu.addItem(resetItem)
        }
        menu = contextMenu
    }

    private func updateTrailingLabel() {
        if showShortcutHint {
            countLabel.stringValue = shortcutNumber.map(String.init) ?? ""
            countLabel.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
            countLabel.textColor = theme.colors.accent
            countLabel.toolTip = shortcutNumber.map { "Ctrl+\($0)" }
        } else {
            countLabel.stringValue = attentionCount > 0
                ? "\(paneCount) · \(attentionCount)!"
                : "\(paneCount)"
            countLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
            countLabel.textColor = attentionCount > 0 ? theme.colors.blue : theme.colors.textMuted
            let panes = "\(paneCount) pane\(paneCount == 1 ? "" : "s")"
            countLabel.toolTip = attentionCount > 0
                ? "\(panes), \(attentionCount) agent\(attentionCount == 1 ? "" : "s") ready"
                : panes
        }
    }

    @objc private func handleToggle() {
        onToggle?()
    }

    @objc private func handleClose() {
        onClose?()
    }

    @objc private func handleRename() {
        onRename?()
    }

    @objc private func handleResetTitle() {
        onResetTitle?()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isInteractiveSubview(hitTest(point)) {
            super.mouseDown(with: event)
            return
        }
        if event.clickCount == 2 {
            onToggle?()
        } else {
            onSelect?()
        }
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

// MARK: - Pane Row

private final class SidebarPaneRowView: NSView {
    private let disclosureButton = NSButton(title: "", target: nil, action: nil)
    private let dotView = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let badgeContainer = NSView()
    private let badgeLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton(title: "×", target: nil, action: nil)
    private let branchLabel = NSTextField(labelWithString: "")
    private var titleBottomConstraint: NSLayoutConstraint!
    private var branchConstraints: [NSLayoutConstraint] = []
    private var onToggle: (() -> Void)?
    private var onSelect: (() -> Void)?
    private var onClose: (() -> Void)?
    private let theme: AppTheme
    private let hierarchyIndent: CGFloat

    init(theme: AppTheme, hierarchyIndent: CGFloat = 0) {
        self.theme = theme
        self.hierarchyIndent = hierarchyIndent
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
        disclosureButton.target = self
        disclosureButton.action = #selector(handleToggle)
        disclosureButton.isBordered = false
        disclosureButton.imagePosition = .imageOnly
        disclosureButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(disclosureButton)

        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 3
        dotView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dotView)

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = theme.colors.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
        badgeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
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
            disclosureButton.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: 2 + hierarchyIndent
            ),
            disclosureButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            disclosureButton.widthAnchor.constraint(equalToConstant: 18),
            disclosureButton.heightAnchor.constraint(equalToConstant: 24),

            dotView.leadingAnchor.constraint(
                equalTo: disclosureButton.trailingAnchor,
                constant: 2
            ),
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
        agentStatus: AgentStatus?,
        tabCount: Int,
        depthLevel: Int?,
        maximumDepth: Int?,
        shortcutKey: String?,
        showShortcutHint: Bool,
        showsDisclosure: Bool,
        expanded: Bool,
        showsClose: Bool = true,
        highlighted: Bool,
        onToggle: @escaping () -> Void,
        onSelect: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.onToggle = onToggle
        self.onSelect = onSelect
        self.onClose = onClose
        titleLabel.stringValue = title
        dotView.layer?.backgroundColor = dotColor.cgColor

        disclosureButton.isHidden = !showsDisclosure
        disclosureButton.identifier = showsDisclosure
            ? NSUserInterfaceItemIdentifier("pane-depth-disclosure")
            : nil
        if showsDisclosure {
            let symbolName = expanded ? "chevron.down" : "chevron.right"
            disclosureButton.image = NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: expanded
                    ? "Collapse Pane Depth"
                    : "Expand Pane Depth"
            )?.withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        }
        disclosureButton.contentTintColor = theme.colors.textMuted
        closeButton.isHidden = !showsClose

        let depthText = depthLevel.flatMap { depth in
            maximumDepth.map { "Z\(depth)/\($0)" }
        }
        badgeLabel.identifier = maximumDepth == nil
            ? nil
            : NSUserInterfaceItemIdentifier("pane-depth-badge")
        if showShortcutHint, let shortcutKey {
            badgeContainer.isHidden = false
            badgeContainer.layer?.backgroundColor = theme.colors.accent.withAlphaComponent(0.2).cgColor
            badgeLabel.stringValue = "⇧\(shortcutKey.uppercased())"
            badgeLabel.textColor = theme.colors.accent
            badgeContainer.toolTip = "Ctrl+Shift+\(shortcutKey.uppercased())"
        } else {
            var badgeParts: [String] = []
            if let agentStatus {
                badgeParts.append(agentStatus.displayLabel)
            }
            if tabCount > 1 {
                badgeParts.append("\(tabCount)T")
            }
            if let depthText {
                badgeParts.append(depthText)
            }
            badgeContainer.isHidden = badgeParts.isEmpty
            badgeContainer.layer?.backgroundColor = agentStatus == nil
                ? theme.colors.bgRaised.cgColor
                : dotColor.withAlphaComponent(0.16).cgColor
            badgeLabel.stringValue = badgeParts.joined(separator: " · ")
            badgeLabel.textColor = agentStatus == nil ? theme.colors.textMuted : dotColor
            badgeContainer.toolTip = maximumDepth.map {
                "Pane depth Z\(depthLevel ?? 0) of Z\($0)"
            }
        }
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

    @objc private func handleToggle() {
        onToggle?()
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
        if event.clickCount == 2, !disclosureButton.isHidden {
            onToggle?()
        } else {
            onSelect?()
        }
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

// MARK: - Flipped Document View

/// Document view for the pane list's NSScrollView. Flipping the coordinate
/// system anchors content to the top and lets the view grow taller than the
/// viewport (via a `>=` bottom pin) so the scroller engages on overflow
/// instead of Auto Layout forcing document height to equal viewport height.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }
}
