import AppKit

/// Persistent sidebar showing collapsible logical windows and their panes,
/// drawn in Soprano Agents' sidebar language: a title row with the sidebar
/// toggle and the session switcher (in the title bar strip, clear of the
/// traffic lights), the Search row with ghost icon buttons, Automations,
/// windows as collapsible section headers ("soprano 2 ⌄"), agent panes as
/// cards (project monogram and folder, status pill, title, meta line) and
/// other panes as slim rows, and a footer of ghost icon buttons.
final class SidebarView: NSView {
    /// The title row: as tall as the window tab row beside it, or the title
    /// bar strip when that is taller.
    static let headerHeight: CGFloat = 32
    /// The Search row and the Automations entry.
    static let searchRowHeight: CGFloat = 32
    static let navRowHeight: CGFloat = 32
    static let footerHeight: CGFloat = 40
    /// Rows sit 1 pt apart. Panes that share a tab stay that close, a new tab
    /// starts a little further down, and a new window further still, so the
    /// list groups itself without a label on every row.
    static let rowGap: CGFloat = 1
    static let tabGap: CGFloat = 5
    static let windowGap: CGFloat = 10
    /// Pane rows sit this far right of their window's title, fill included,
    /// with a hairline guide in the gutter running from the title down to the
    /// window's last pane, so each pane reads as part of the window above it.
    static let paneIndent: CGFloat = 14

    let agentManager: AgentManager
    let sessionManager: SessionManager
    let themeManager: ThemeManager
    let gitBranchMonitor: GitBranchMonitor

    var onSettingsRequested: (() -> Void)?
    var onDashboardRequested: (() -> Void)?
    /// The Automations entry was clicked; the page opens, or closes when it
    /// is open.
    var onAutomationsRequested: (() -> Void)?
    /// A window or pane row was clicked, so whatever page covers the
    /// workspace makes way.
    var onWorkspaceRowSelected: (() -> Void)?
    /// The title row's sidebar toggle was clicked.
    var onToggleSidebarRequested: (() -> Void)?

    private var contentWidthConstraint: NSLayoutConstraint!
    private var titleRowHeightConstraint: NSLayoutConstraint!
    private var toggleLeadingConstraint: NSLayoutConstraint!
    private var contentContainer: NSView!
    private var titleRow: SidebarTitleRowView!
    private var toggleButton: ShellGhostButton!
    private var sessionButton: SidebarSessionButton!
    private var searchButton: SidebarSearchButton!
    private var automationsRow: SidebarNavRowView!
    private var scrollView: NSScrollView!
    private var listContentView: SidebarListView!
    private var rowsStack: NSStackView!
    private var footerView: NSView!
    private var trailingBorder: NSView!
    private var settingsButton: ShellGhostButton!
    private var dashboardButton: ShellGhostButton!
    private var plusButton: ShellGhostButton!
    private var collapseAllButton: ShellGhostButton!
    private var sessionsButton: ShellGhostButton!
    private var isResizeHighlighted = false
    private var isControlKeyHeld = false
    private var typedPaneHint = ""
    private var windowRows: [String: SidebarWindowRowView] = [:]
    private var paneRows: [String: SidebarPaneRowView] = [:]
    private var displayedWindowId: String?
    private var needsActiveWindowReveal = false
    private var clockTimer: Timer?

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
        agentManager.addObserver(id: "SidebarView") { [weak self] change in
            self?.handleAgentChange(change)
        }
        sessionManager.addObserver(id: "SidebarView-sessions") { [weak self] in
            self?.refresh()
        }
        gitBranchMonitor.onChange = { [weak self] in
            self?.refresh()
        }
        PaletteCenter.shared.addObserver(self) { [weak self] _ in
            self?.refreshTheme()
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

    override func layout() {
        super.layout()
        updateTitleRowGeometry()
        guard needsActiveWindowReveal,
              scrollView.contentSize.height > 0,
              let row = windowRows[agentManager.activeWindowId]
        else { return }
        // Reconciled rows need their final frames before AppKit can reveal one.
        listContentView.layoutSubtreeIfNeeded()
        needsActiveWindowReveal = false
        row.scrollToVisible(row.bounds)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateClock()
        needsLayout = true
    }

    /// The title row fills the title bar strip (when the window has one) and
    /// starts right of the traffic lights.
    private func updateTitleRowGeometry() {
        let height = max(Self.headerHeight, ShellTitlebar.stripHeight(for: self))
        if titleRowHeightConstraint.constant != height {
            titleRowHeightConstraint.constant = height
        }
        // The sidebar's own frame is final here; its title row's may not be yet.
        let inset = ShellTitlebar.trafficLightInset(for: self)
        let leading = inset > 0 ? inset : ShellSidebarMetrics.contentInset
        if toggleLeadingConstraint.constant != leading {
            toggleLeadingConstraint.constant = leading
        }
    }

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false

        // Explicit-width container pinned to the leading edge: the outer width
        // constraint can animate to 0 and clip instead of fighting content
        // constraints (masksToBounds is set above). Resizing drives both widths,
        // so this constant tracks the chosen width rather than a fixed default.
        contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentContainer)

        // Title row: sidebar toggle and the session switcher.
        titleRow = SidebarTitleRowView()
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(titleRow)

        toggleButton = ShellGhostButton(
            symbol: Icon.sidebarLeft,
            label: "Toggle Sidebar",
            target: self,
            action: #selector(toggleSidebarClicked)
        )
        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        titleRow.addSubview(toggleButton)

        sessionButton = SidebarSessionButton()
        sessionButton.identifier = NSUserInterfaceItemIdentifier("session-selector")
        sessionButton.translatesAutoresizingMaskIntoConstraints = false
        sessionButton.onClick = { [weak self] in
            self?.showSessionMenu()
        }
        titleRow.addSubview(sessionButton)

        // Search row: Search opens the command palette; Collapse All and New
        // sit at its end like Agents' filter / add project / new thread.
        searchButton = SidebarSearchButton()
        searchButton.translatesAutoresizingMaskIntoConstraints = false
        searchButton.onClick = { [weak self] in
            self?.openCommandPalette()
        }
        contentContainer.addSubview(searchButton)

        collapseAllButton = ShellGhostButton(
            symbol: "rectangle.compress.vertical",
            label: "Collapse All Windows",
            variant: .sidebar,
            target: self,
            action: #selector(collapseAllClicked)
        )
        collapseAllButton.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(collapseAllButton)

        plusButton = ShellGhostButton(
            symbol: Icon.squarePen,
            label: "New Window or Pane",
            variant: .sidebar,
            target: self,
            action: #selector(plusClicked)
        )
        plusButton.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(plusButton)

        automationsRow = SidebarNavRowView(title: "Automations", symbolName: "calendar.badge.clock")
        automationsRow.identifier = NSUserInterfaceItemIdentifier("sidebar-automations")
        automationsRow.onClick = { [weak self] in
            self?.onAutomationsRequested?()
        }
        contentContainer.addSubview(automationsRow)

        scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(scrollView)

        listContentView = SidebarListView()
        listContentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = listContentView

        rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 1
        rowsStack.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 8, right: 0)
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        listContentView.addSubview(rowsStack)
        listContentView.rowsStack = rowsStack

        footerView = NSView()
        footerView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(footerView)

        settingsButton = makeFooterButton(symbol: Icon.settings, label: "Settings", action: #selector(settingsClicked))
        dashboardButton = makeFooterButton(symbol: Icon.statistics, label: "Agent Dashboard", action: #selector(dashboardClicked))
        sessionsButton = makeFooterButton(
            symbol: "clock.arrow.trianglehead.counterclockwise.rotate.90",
            label: "Saved Workspaces",
            action: #selector(sessionsClicked)
        )

        trailingBorder = NSView()
        trailingBorder.wantsLayer = true
        trailingBorder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(trailingBorder)

        contentWidthConstraint = contentContainer.widthAnchor.constraint(
            equalToConstant: SidebarWidthStore.left.defaultWidth
        )
        titleRowHeightConstraint = titleRow.heightAnchor.constraint(equalToConstant: Self.headerHeight)
        toggleLeadingConstraint = toggleButton.leadingAnchor.constraint(
            equalTo: titleRow.leadingAnchor,
            constant: ShellSidebarMetrics.contentInset
        )
        let inset = ShellSidebarMetrics.contentInset

        NSLayoutConstraint.activate([
            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.topAnchor.constraint(equalTo: topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentWidthConstraint,

            titleRow.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            titleRow.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            titleRow.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            titleRowHeightConstraint,

            toggleLeadingConstraint,
            toggleButton.centerYAnchor.constraint(equalTo: titleRow.centerYAnchor),
            sessionButton.leadingAnchor.constraint(equalTo: toggleButton.trailingAnchor, constant: 6),
            sessionButton.centerYAnchor.constraint(equalTo: titleRow.centerYAnchor),
            sessionButton.trailingAnchor.constraint(lessThanOrEqualTo: titleRow.trailingAnchor, constant: -inset),

            searchButton.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: inset),
            searchButton.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: inset),
            searchButton.heightAnchor.constraint(equalToConstant: Self.searchRowHeight),
            searchButton.trailingAnchor.constraint(equalTo: collapseAllButton.leadingAnchor, constant: -4),
            collapseAllButton.centerYAnchor.constraint(equalTo: searchButton.centerYAnchor),
            collapseAllButton.trailingAnchor.constraint(equalTo: plusButton.leadingAnchor),
            plusButton.centerYAnchor.constraint(equalTo: searchButton.centerYAnchor),
            plusButton.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -inset),

            automationsRow.topAnchor.constraint(equalTo: searchButton.bottomAnchor, constant: 2),
            automationsRow.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            automationsRow.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            automationsRow.heightAnchor.constraint(equalToConstant: Self.navRowHeight),

            scrollView.topAnchor.constraint(equalTo: automationsRow.bottomAnchor, constant: 4),
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
            footerView.heightAnchor.constraint(equalToConstant: Self.footerHeight),

            // Agents' footer: Settings, then the board toggle, then the rest.
            settingsButton.leadingAnchor.constraint(equalTo: footerView.leadingAnchor, constant: inset),
            settingsButton.centerYAnchor.constraint(equalTo: footerView.centerYAnchor),
            dashboardButton.leadingAnchor.constraint(equalTo: settingsButton.trailingAnchor, constant: 2),
            dashboardButton.centerYAnchor.constraint(equalTo: footerView.centerYAnchor),
            sessionsButton.leadingAnchor.constraint(equalTo: dashboardButton.trailingAnchor, constant: 2),
            sessionsButton.centerYAnchor.constraint(equalTo: footerView.centerYAnchor),

            trailingBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            trailingBorder.topAnchor.constraint(equalTo: topAnchor),
            trailingBorder.bottomAnchor.constraint(equalTo: bottomAnchor),
            trailingBorder.widthAnchor.constraint(equalToConstant: 1),
        ])
    }

    private func makeFooterButton(symbol: String, label: String, action: Selector) -> ShellGhostButton {
        let button = ShellGhostButton(
            symbol: symbol,
            label: label,
            size: 32,
            symbolSize: 15,
            variant: .sidebar,
            target: self,
            action: action
        )
        button.translatesAutoresizingMaskIntoConstraints = false
        footerView.addSubview(button)
        return button
    }

    /// Width of the sidebar's content. Kept in step with the view's own width so
    /// rows lay out at the dragged size instead of being clipped at the default.
    func setContentWidth(_ width: CGFloat) {
        contentWidthConstraint.constant = width
    }

    /// Darkens the trailing border while the resize handle is hovered or
    /// dragged, so the draggable edge is visible before the mouse goes down.
    func setResizeHighlighted(_ isHighlighted: Bool) {
        isResizeHighlighted = isHighlighted
        applyTrailingBorderColor()
    }

    private func applyTrailingBorderColor() {
        let palette = PaletteCenter.shared.palette
        trailingBorder.layer?.backgroundColor = (isResizeHighlighted ? palette.input : palette.sidebarBorder).cgColor
    }

    func setControlKeyHeld(_ isHeld: Bool) {
        guard isControlKeyHeld != isHeld else { return }
        isControlKeyHeld = isHeld
        rebuildRows()
    }

    /// Letters of a longer pane hint typed so far. The hints stay up, even
    /// once ⌃ is released, narrowed to the panes the letters still reach.
    func setTypedPaneHint(_ typed: String) {
        guard typedPaneHint != typed else { return }
        typedPaneHint = typed
        rebuildRows()
    }

    @objc private func toggleSidebarClicked() {
        onToggleSidebarRequested?()
    }

    @objc private func settingsClicked() {
        onSettingsRequested?()
    }

    @objc private func dashboardClicked() {
        onDashboardRequested?()
    }

    /// Shows the Automations entry selected while its page is open.
    func setAutomationsSelected(_ selected: Bool) {
        automationsRow.isSelected = selected
    }

    @objc private func collapseAllClicked() {
        agentManager.collapseAllSidebarWindows()
    }

    /// The window controller's command palette, through the responder chain.
    private func openCommandPalette() {
        NSApp.sendAction(Selector(("commandPaletteMenuItemSelected")), to: nil, from: self)
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
        for profile in AgentCatalog.all where profile.id != "terminal" {
            let item = NSMenuItem(
                title: "New \(profile.name) Pane",
                action: #selector(spawnMenuItemClicked(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = profile.id
            menu.addItem(item)
        }
        for profile in AgentChatLaunch.chatProfiles {
            let item = NSMenuItem(
                title: "New \(profile.name) Chat Pane",
                action: #selector(spawnChatMenuItemClicked(_:)),
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
        let browserItem = NSMenuItem(
            title: "New Browser Pane",
            action: #selector(spawnBrowserMenuItemClicked),
            keyEquivalent: ""
        )
        browserItem.target = self
        menu.addItem(browserItem)
        let markdownItem = NSMenuItem(
            title: "Open Markdown…",
            action: #selector(openMarkdownMenuItemClicked),
            keyEquivalent: ""
        )
        markdownItem.target = self
        menu.addItem(markdownItem)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: plusButton.bounds.maxY + 4), in: plusButton)
    }

    @objc private func newWindowClicked() {
        _ = agentManager.createWindow()
    }

    @objc private func spawnMenuItemClicked(_ sender: NSMenuItem) {
        guard let profileId = sender.representedObject as? String else { return }
        _ = agentManager.spawnAgent(profileId)
    }

    @objc private func spawnChatMenuItemClicked(_ sender: NSMenuItem) {
        guard let profileId = sender.representedObject as? String else { return }
        _ = agentManager.spawnAgent(profileId, chat: true)
    }

    @objc private func spawnBrowserMenuItemClicked() {
        _ = agentManager.spawnBrowser()
    }

    @objc private func openMarkdownMenuItemClicked() {
        guard let window else { return }
        MarkdownFilePicker.begin(relativeTo: window) { [weak self] fileURL in
            _ = self?.agentManager.spawnMarkdown(fileURL: fileURL)
        }
    }

    @objc private func sessionsClicked() {
        let menu = NSMenu()
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .short
        if sessionManager.sessions.isEmpty {
            menu.addItem(NSMenuItem(title: "No Saved Workspaces", action: nil, keyEquivalent: ""))
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
            title: "Save Workspace As…",
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
        ShellDialogs.prompt(
            title: "Save Workspace",
            message: "Save a snapshot of all sessions and their window layouts:",
            placeholder: "Workspace name",
            confirmTitle: "Save",
            in: window
        ) { [weak self] name in
            guard let self, let name else { return }
            sessionManager.saveSession(name: name)
        }
    }

    /// The session switcher: every session (the active one checked), then
    /// New / Rename / Close.
    func makeSessionMenu() -> NSMenu {
        let menu = NSMenu()
        for session in agentManager.orderedSessions {
            let item = NSMenuItem(title: session.name, action: #selector(sessionMenuItemSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = session.id
            item.state = session.id == agentManager.activeSessionId ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (title, action) in [
            ("New Session…", #selector(promptToCreateSession)),
            ("Rename Session…", #selector(promptToRenameSession)),
            ("Close Session…", #selector(promptToCloseSession)),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    private func showSessionMenu() {
        makeSessionMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sessionButton.bounds.maxY + 4), in: sessionButton)
    }

    @objc private func sessionMenuItemSelected(_ sender: NSMenuItem) {
        guard let sessionId = sender.representedObject as? String else { return }
        agentManager.activateSession(sessionId)
    }

    // MARK: - Refresh

    func refreshTheme() {
        refresh()
    }

    private func refresh() {
        let palette = PaletteCenter.shared.palette
        layer?.backgroundColor = palette.sidebar.cgColor
        applyTrailingBorderColor()
        sessionButton.title = agentManager.activeSession?.name ?? "Session"
        collapseAllButton.isEnabled = agentManager.activeSessionWindows.contains { !$0.isSidebarCollapsed }

        // Reconcile watchers first so rows read freshly-invalidated caches.
        gitBranchMonitor.setWatchedPaths(watchedCwds())
        rebuildRows()
    }

    private func handleAgentChange(_ change: AgentManagerChange) {
        switch change {
        case .model:
            refresh()

        case .tabTitle(let target):
            guard let pane = agentManager.panes[target.paneId],
                  pane.activeTab?.id == target.tabId
            else { return }
            let title = sidebarTitle(for: pane)
            paneRows[target.paneId]?.setTitle(title)
            paneRows[target.paneId]?.setMeta(meta(for: pane, title: title))

        case .tabWorkingDirectory(let target):
            gitBranchMonitor.setWatchedPaths(watchedCwds())
            guard let pane = agentManager.panes[target.paneId],
                  pane.activeTab?.id == target.tabId
            else { return }
            let title = sidebarTitle(for: pane)
            paneRows[target.paneId]?.setTitle(title)
            paneRows[target.paneId]?.setMeta(meta(for: pane, title: title))
            paneRows[target.paneId]?.setProject(projectName(for: pane))

        case .browserURL:
            break

        case .document(let target):
            guard let pane = agentManager.panes[target.paneId],
                  pane.activeTab?.id == target.tabId
            else { return }
            paneRows[target.paneId]?.setTitle(sidebarTitle(for: pane))
        }
    }

    /// Brings the rows up to date with the workspace. This runs on every model
    /// change, so rows that stay are reconfigured in place: building a row's
    /// buttons costs far more than configuring one.
    private func rebuildRows() {
        let paneShortcutKeysById = Dictionary(
            uniqueKeysWithValues: agentManager.paneShortcutAssignments.map {
                ($0.paneId, $0.key)
            }
        )
        let now = Date()
        // Holding ⌃ shows the hints; a started hint keeps them up.
        let showsHints = isControlKeyHeld || !typedPaneHint.isEmpty
        var rows: [NSView] = []
        // The gap under each row, by index into `rows`.
        var gaps: [CGFloat] = []
        var nextWindowRows: [String: SidebarWindowRowView] = [:]
        var nextPaneRows: [String: SidebarPaneRowView] = [:]
        var guides: [SidebarListView.Guide] = []
        for (index, terminalWindow) in agentManager.activeSessionWindows.enumerated() {
            let isActiveWindow = terminalWindow.id == agentManager.activeWindowId
            let isExpanded = showsHints
                || !terminalWindow.isSidebarCollapsed
            let paneIds = terminalWindow.paneIds
            let windowRow = windowRows[terminalWindow.id] ?? {
                let row = SidebarWindowRowView()
                row.identifier = NSUserInterfaceItemIdentifier("sidebar-window-\(terminalWindow.id)")
                return row
            }()
            windowRow.configure(
                title: terminalWindow.title,
                paneCount: paneIds.count,
                attentionCount: paneIds.reduce(into: 0) { count, paneId in
                    count += agentManager.panes[paneId]?.tabs.filter {
                        $0.agent?.needsAttention == true
                    }.count ?? 0
                },
                shortcutNumber: index < 9 ? index + 1 : nil,
                showShortcutHint: isControlKeyHeld && typedPaneHint.isEmpty,
                expanded: isExpanded,
                highlighted: isActiveWindow,
                isTitleCustom: terminalWindow.isTitleCustom,
                onToggle: { [weak self] in
                    self?.agentManager.toggleSidebarWindowCollapsed(terminalWindow.id)
                },
                onSelect: { [weak self] in
                    self?.onWorkspaceRowSelected?()
                    self?.agentManager.activateWindow(terminalWindow.id)
                },
                onRename: { [weak self] in
                    self?.promptToRenameWindow(terminalWindow.id)
                },
                onResetTitle: { [weak self] in
                    self?.agentManager.resetWindowTitle(terminalWindow.id)
                },
                onClose: { [weak self] in
                    self?.agentManager.closeWindow(terminalWindow.id)
                }
            )
            if !rows.isEmpty {
                gaps[gaps.count - 1] = Self.windowGap
            }
            rows.append(windowRow)
            gaps.append(Self.rowGap)
            nextWindowRows[terminalWindow.id] = windowRow

            guard isExpanded else { continue }
            for layoutTab in terminalWindow.tabs {
                let paneIds = layoutTab.layout?.orderedLeafIds ?? []
                if paneIds.contains(where: { agentManager.panes[$0] != nil }), rows.last is SidebarPaneRowView {
                    gaps[gaps.count - 1] = Self.tabGap
                }
                for paneId in paneIds {
                    guard let pane = agentManager.panes[paneId] else { continue }
                    let row = paneRows[pane.id] ?? {
                        let row = SidebarPaneRowView()
                        row.identifier = NSUserInterfaceItemIdentifier("sidebar-pane-\(pane.id)")
                        return row
                    }()
                    let title = sidebarTitle(for: pane)
                    let tab = pane.activeTab
                    let agent = tab?.agent
                    let pill = ShellStatusPill.of(agent: agent, runsCommand: paneRunsCommand(pane), now: now)
                    row.configure(
                        kind: Self.rowKind(for: tab),
                        title: title,
                        project: projectName(for: pane),
                        meta: meta(for: pane, title: title),
                        pill: pill,
                        idleSince: agent.map { ShellStatusClock.shared.since($0, now: now) },
                        recedes: agent.map { [.running, .starting, .idle, .stopped].contains($0.status) } ?? false,
                        shortcutCaps: paneShortcutKeysById[pane.id].flatMap {
                            Self.paneHintCaps(for: $0, typed: typedPaneHint)
                        },
                        showShortcutHint: showsHints,
                        highlighted: isActiveWindow && pane.id == agentManager.activePaneId,
                        inActiveWindow: isActiveWindow,
                        now: now,
                        onSelect: { [weak self] in
                            self?.onWorkspaceRowSelected?()
                            self?.agentManager.focusPane(pane.id)
                        },
                        onClose: { [weak self] in
                            self?.agentManager.closePane(pane.id)
                        }
                    )
                    rows.append(row)
                    gaps.append(Self.rowGap)
                    nextPaneRows[pane.id] = row
                }
            }
            // An expanded window with panes ends on its last pane row.
            if let lastPane = rows.last as? SidebarPaneRowView {
                guides.append(.init(window: windowRow, lastPane: lastPane))
            }
        }
        windowRows = nextWindowRows
        paneRows = nextPaneRows
        rowsStack.setArrangedSubviews(rows) { row in
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }
        listContentView.guides = guides
        // Reused rows keep the gap they had; every row's is set each time.
        for (row, gap) in zip(rows, gaps) {
            rowsStack.setCustomSpacing(gap, after: row)
        }
        if displayedWindowId != agentManager.activeWindowId {
            displayedWindowId = agentManager.activeWindowId
            needsActiveWindowReveal = true
            needsLayout = true
        }
        // Rows that moved under a resting pointer hand the hover on.
        listContentView.needsLayout = true
        updateClock()
    }

    /// Ticks live durations ("Working 2m", "5m") once a second while a row
    /// shows one and the sidebar is in a window.
    private func updateClock() {
        let needsClock = window != nil && paneRows.values.contains { $0.hasLiveTime }
        if !needsClock {
            clockTimer?.invalidate()
            clockTimer = nil
            return
        }
        guard clockTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated {
                let now = Date()
                for row in self.paneRows.values { row.refreshTime(now) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    /// Agent and chat panes are cards; shells, browsers and documents slim
    /// rows with their kind's symbol (Agents' tab symbols: a diff's
    /// `plus.forwardslash.minus`, a file's or Markdown file's `doc.text`).
    /// Documents are browser-type tabs, so they are told apart first.
    private static func rowKind(for tab: PaneTab?) -> SidebarPaneRowView.Kind {
        guard let tab else { return .slim(symbol: Icon.terminal) }
        if tab.agent != nil || tab.isChat { return .card }
        if tab.isDiff { return .slim(symbol: "plus.forwardslash.minus") }
        if tab.isMarkdown || tab.isEditor || tab.isFilePreview { return .slim(symbol: Icon.fileText) }
        if tab.type == .browser { return .slim(symbol: Icon.globe) }
        return .slim(symbol: Icon.terminal)
    }

    /// K1 caps for what is left of a pane hint after `typed`, or nil when the
    /// hint does not go on from it: `⌃⇧B`, or `⌃⇧Z` `B`, which reads `B` once
    /// `Z` is typed.
    private static func paneHintCaps(for hint: String, typed: String) -> [String]? {
        guard hint.count > typed.count, hint.hasPrefix(typed) else { return nil }
        let letters = hint.dropFirst(typed.count).map { $0.uppercased() }
        return typed.isEmpty ? ["⌃⇧\(letters[0])"] + letters.dropFirst() : letters
    }

    func promptToRenameActiveWindow() {
        promptToRenameWindow(agentManager.activeWindowId)
    }

    @objc func promptToCreateSession() {
        promptForSessionName(title: "New Session", initialName: "") { [weak self] name in
            _ = self?.agentManager.createSession(name: name)
        }
    }

    @objc func promptToRenameSession() {
        guard let session = agentManager.activeSession else { return }
        let sessionId = session.id
        promptForSessionName(title: "Rename Session", initialName: session.name) { [weak self] name in
            self?.agentManager.renameSession(sessionId, to: name)
        }
    }

    private func promptForSessionName(title: String, initialName: String, completion: @escaping (String) -> Void) {
        ShellDialogs.prompt(
            title: title,
            message: "Name this group of windows.",
            placeholder: "Session name",
            initialValue: initialName,
            confirmTitle: initialName.isEmpty ? "Create" : "Rename",
            in: window
        ) { name in
            guard let name else { return }
            completion(name)
        }
    }

    @objc func promptToCloseSession() {
        guard let session = agentManager.activeSession else { return }
        let sessionId = session.id
        ShellDialogs.confirm(
            title: "Close \"\(session.name)\"?",
            message: "All windows and running terminals in this session will close.",
            confirmTitle: "Close Session",
            isDestructive: true,
            in: window
        ) { [weak self] confirmed in
            guard confirmed else { return }
            self?.agentManager.closeSession(sessionId)
        }
    }

    private func promptToRenameWindow(_ windowId: String) {
        guard let terminalWindow = agentManager.windows[windowId] else { return }
        ShellDialogs.prompt(
            title: "Rename Window",
            message: "Choose a stable name for this window.",
            initialValue: terminalWindow.title,
            confirmTitle: "Rename",
            in: window
        ) { [weak self] name in
            guard let name else { return }
            self?.agentManager.renameWindow(windowId, to: name)
        }
    }

    // MARK: - Row Content

    private func sidebarTitle(for pane: PaneState) -> String {
        guard let tab = pane.activeTab else { return "Pane" }
        return sidebarTitle(for: tab)
    }

    /// Browser, Markdown, editor and diff tabs are named after their page or
    /// file already; a terminal's or agent's title is tidied by `TerminalTitle`.
    private func sidebarTitle(for tab: PaneTab) -> String {
        guard tab.type != .browser else { return tab.title }
        return TerminalTitle.display(
            tab.title,
            workingDirectory: tab.effectiveWorkingDirectory,
            agentName: tab.agent.flatMap { AgentCatalog.profile(for: $0.profileId)?.name }
        )
    }

    /// A card's project line: the folder its agent works in.
    private func projectName(for pane: PaneState) -> String? {
        pane.activeTab?.effectiveWorkingDirectory.map { TerminalTitle.folderName($0) }
    }

    /// The meta line under `title`; see `PaneContextLine`. A card names its
    /// folder on the project line, so its meta line leaves the folder out.
    private func meta(for pane: PaneState, title: String) -> PaneContextLine {
        guard let tab = pane.activeTab else { return PaneContextLine() }
        let cwd = tab.effectiveWorkingDirectory
        let agentName = tab.agent.flatMap { AgentCatalog.profile(for: $0.profileId)?.name }
        let branch = cwd.flatMap { gitBranchMonitor.notableBranch(for: $0) }
        if case .card = Self.rowKind(for: tab) {
            return PaneContextLine(
                context: agentName.map { $0 == title ? [] : [$0] } ?? [],
                branch: branch,
                tabCount: pane.tabs.count
            )
        }
        return PaneContextLine(
            title: title,
            agentName: agentName,
            workingDirectory: cwd,
            branch: branch,
            tabCount: pane.tabs.count
        )
    }

    private func watchedCwds() -> [String] {
        agentManager.panes.values.flatMap { pane in
            pane.tabs.compactMap(\.effectiveWorkingDirectory)
        }
    }

    private func paneRunsCommand(_ pane: PaneState) -> Bool {
        pane.tabs.contains { agentManager.isRunningCommand($0, in: pane.id) }
    }
}

// MARK: - Title Row

/// The title row lives in the title bar strip: its empty space moves the
/// window like a title bar.
private final class SidebarTitleRowView: NSView {
    override func mouseDown(with event: NSEvent) {
        ShellTitlebar.handleMouseDown(event, in: self)
    }
}

/// The session name in Agents' brand style (14 medium) with a chevron; a
/// click opens the session switcher.
private final class SidebarSessionButton: InteractiveView {
    private let label = NSTextField.label("", size: Typography.bodySize, weight: .medium)
    private let chevron = NSImageView()

    var title = "" {
        didSet {
            guard title != oldValue else { return }
            label.stringValue = title
            setAccessibilityValue(title)
            invalidateIntrinsicContentSize()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = Radius.md
        chevron.image = NSImage.symbol(Icon.chevronDown, size: 9, weight: .semibold)
        chevron.imageScaling = .scaleNone
        for view in [label, chevron] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 4),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel("Current Session")
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = (isHovered ? palette.sidebarRowHover : .clear).cgColor
        label.textColor = palette.sidebarForeground
        chevron.contentTintColor = isHovered ? palette.sidebarForeground : palette.sidebarMutedForeground
        setAccessibilityValue(label.stringValue)
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

/// Agents' sidebar search row (`h-8 rounded-md px-2 text-sm font-medium`,
/// magnifier, "Search"). Soprano searches through the command palette, so the
/// row opens it.
private final class SidebarSearchButton: InteractiveView {
    private let icon = NSImageView()
    private let label = NSTextField.label("Search", size: Typography.bodySize, weight: .medium)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = Radius.md
        icon.image = NSImage.symbol(Icon.search, size: 13)
        icon.imageScaling = .scaleNone
        for view in [icon, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
        toolTip = "Search panes and commands"
        setAccessibilityRole(.button)
        setAccessibilityLabel("Search")
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = (isHovered ? palette.sidebarRowHover : .clear).cgColor
        icon.contentTintColor = palette.sidebarMutedForeground
        label.textColor = isHovered ? palette.sidebarForeground : palette.sidebarMutedForeground
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

// MARK: - Row Chrome

/// Key-window tracking shared by the sidebar rows. The row shows its close
/// button and the hover fill only while `isHovered`, which the list sets for
/// the row under the pointer, and the focused row's active fill only while
/// its window is key.
private class SidebarRowView: NSView {
    let background = ShellRowSurfaceView()
    var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            hoverStateDidChange()
        }
    }

    /// How far the fill (and, in rows that lay out with it, the content)
    /// starts right of the list's edge.
    var indent: CGFloat = 0 {
        didSet {
            backgroundLeading.constant = indent
            needsLayout = true
        }
    }
    private var backgroundLeading: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        background.identifier = NSUserInterfaceItemIdentifier("sidebar-row-background")
        addSubview(background)
        backgroundLeading = background.leadingAnchor.constraint(equalTo: leadingAnchor)
        NSLayoutConstraint.activate([
            backgroundLeading,
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        // The palette, an alert or another app taking the keyboard mutes
        // the open row's fill, like the pane header's focus.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(keyWindowDidChange(_:)),
                name: name,
                object: nil
            )
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    /// Re-applies the row's state after the pointer, the key window or the
    /// row's configuration changes.
    func hoverStateDidChange() {}

    /// Whether the row's window holds the keyboard. A row outside any window
    /// (tests) counts as focused.
    var isInKeyWindow: Bool {
        window.map(\.isKeyWindow) ?? true
    }

    @objc private func keyWindowDidChange(_ notification: Notification) {
        hoverStateDidChange()
    }

    /// Close buttons fade out instead of hiding, so VoiceOver and Full
    /// Keyboard Access keep them; a faded control ignores the pointer and the
    /// click selects the row instead.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        var current: NSView? = hit
        while let candidate = current, candidate !== self {
            if candidate is NSControl, candidate.alphaValue == 0 {
                return self
            }
            current = candidate.superview
        }
        return hit
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { isHovered = false }
        hoverStateDidChange()
    }

    func isInteractiveSubview(_ view: NSView?) -> Bool {
        var current = view
        while let candidate = current, candidate !== self {
            // A control that acts on clicks; labels (also `NSControl`s) pass
            // theirs on and still select the row.
            if let control = candidate as? NSControl, control.action != nil {
                return true
            }
            current = candidate.superview
        }
        return false
    }

    static func makeCloseButton(accessibilityLabel: String) -> ShellGhostButton {
        let button = ShellGhostButton(
            symbol: "xmark",
            label: accessibilityLabel,
            size: 20,
            symbolSize: 9,
            weight: .semibold,
            variant: .sidebar
        )
        button.translatesAutoresizingMaskIntoConstraints = true
        return button
    }
}

// MARK: - Window Row

/// `soprano  2 ⌄`: an Agents section header for a window — the title (13 pt
/// semibold, ink in the active window, muted elsewhere), the muted pane count
/// with the panes that need you in the warning tone, and the disclosure
/// chevron. Holding ⌃ swaps the count for the window's jump hint; the pointer
/// swaps it for a close button.
private final class SidebarWindowRowView: SidebarRowView {
    static let height: CGFloat = 32

    private let disclosureButton = ShellGhostButton(
        symbol: Icon.chevronDown,
        label: "Collapse Window",
        size: 20,
        symbolSize: 9,
        weight: .semibold,
        variant: .sidebar
    )
    private let titleLabel = NSTextField.label("", size: 13, weight: .semibold)
    private let countLabel = NSTextField.label("", size: Typography.smallSize)
    private let jumpBadge = ShellJumpHintBadge()
    private let closeButton = SidebarRowView.makeCloseButton(accessibilityLabel: "Close Window")
    private var onToggle: (() -> Void)?
    private var onSelect: (() -> Void)?
    private var onRename: (() -> Void)?
    private var onResetTitle: (() -> Void)?
    private var onClose: (() -> Void)?
    private var showsShortcut = false
    private var highlighted = false

    override init() {
        super.init()
        jumpBadge.identifier = NSUserInterfaceItemIdentifier("sidebar-jump-window")
        disclosureButton.target = self
        disclosureButton.action = #selector(handleToggle)
        disclosureButton.translatesAutoresizingMaskIntoConstraints = true
        closeButton.target = self
        closeButton.action = #selector(handleClose)
        countLabel.alignment = .right
        for view in [titleLabel, countLabel, jumpBadge, closeButton, disclosureButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
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
        self.highlighted = highlighted
        let palette = PaletteCenter.shared.palette

        let accessibilityLabel = expanded ? "Collapse Window" : "Expand Window"
        disclosureButton.setSymbol(expanded ? Icon.chevronDown : Icon.chevronRight, size: 9, weight: .semibold)
        disclosureButton.setAccessibilityLabel(accessibilityLabel)
        disclosureButton.toolTip = accessibilityLabel
        titleLabel.stringValue = title

        let countFont = Typography.tabular(Typography.smallSize)
        let counts = NSMutableAttributedString(string: "\(paneCount)", attributes: [
            .font: countFont, .foregroundColor: palette.sidebarMutedForeground,
        ])
        if attentionCount > 0 {
            counts.append(NSAttributedString(string: " · ", attributes: [
                .font: countFont, .foregroundColor: palette.sidebarMutedForeground,
            ]))
            counts.append(NSAttributedString(string: "\(attentionCount)!", attributes: [
                .font: Typography.tabular(Typography.smallSize, weight: .medium),
                .foregroundColor: palette.color(for: .approval),
            ]))
        }
        countLabel.attributedStringValue = counts
        let panes = "\(paneCount) pane\(paneCount == 1 ? "" : "s")"
        countLabel.toolTip = attentionCount > 0
            ? "\(panes), \(attentionCount) agent\(attentionCount == 1 ? "" : "s") ready"
            : panes

        showsShortcut = showShortcutHint && shortcutNumber != nil
        if let shortcutNumber {
            jumpBadge.caps = ["⌃\(shortcutNumber)"]
            jumpBadge.toolTip = "Ctrl+\(shortcutNumber)"
        }
        hoverStateDidChange()
        needsLayout = true

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

    override func layout() {
        super.layout()
        let left = ShellSidebarMetrics.contentLeft
        let right = bounds.width - ShellSidebarMetrics.contentLeft
        let midY = bounds.midY
        disclosureButton.frame = NSRect(x: right + 4 - 20, y: midY - 10, width: 20, height: 20)
        var slot = disclosureButton.frame.minX - 2
        closeButton.frame = NSRect(x: slot - 20, y: midY - 10, width: 20, height: 20)
        if !jumpBadge.isHidden {
            let width = jumpBadge.intrinsicContentSize.width
            jumpBadge.frame = NSRect(x: slot - width, y: midY - 10, width: width, height: 20)
            slot = jumpBadge.frame.minX - 6
        } else if !countLabel.isHidden {
            let size = countLabel.intrinsicContentSize
            let width = ceil(size.width) + 4
            countLabel.frame = NSRect(x: slot - width, y: midY - size.height / 2, width: width, height: size.height)
            slot = countLabel.frame.minX - 6
        } else {
            slot = closeButton.frame.minX - 4
        }
        let titleSize = titleLabel.intrinsicContentSize
        titleLabel.frame = NSRect(x: left - 2, y: midY - titleSize.height / 2, width: max(0, slot - left + 2), height: titleSize.height)
    }

    override func hoverStateDidChange() {
        let palette = PaletteCenter.shared.palette
        background.style = isHovered ? .hover : .none
        jumpBadge.isHidden = !showsShortcut
        closeButton.alphaValue = showsShortcut || !isHovered ? 0 : 1
        countLabel.isHidden = showsShortcut || isHovered
        titleLabel.textColor = highlighted || isHovered ? palette.sidebarForeground : palette.sidebarMutedForeground
        needsLayout = true
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
        // `hitTest` takes a point in the superview's coordinates.
        if let superview, isInteractiveSubview(hitTest(superview.convert(event.locationInWindow, from: nil))) {
            super.mouseDown(with: event)
            return
        }
        if event.clickCount == 2 {
            onToggle?()
        } else {
            onSelect?()
        }
    }
}

// MARK: - Pane Row

/// A pane under its window. Agent and chat panes are Agents cards: project
/// monogram and folder with the status pill on the first line, the title
/// (14 pt) on the second, and the meta line (`omp · ⎇ feat/x · 2 tabs`) on a
/// third when there is one. Other panes are slim rows: their kind's symbol,
/// the title and a Running pill while a command runs, with the meta line
/// under the title when there is one. The focused pane gets the active fill;
/// every other row is plain. Holding ⌃ swaps the pill for the pane's jump
/// hint; the pointer swaps it for a close button.
private final class SidebarPaneRowView: SidebarRowView {
    enum Kind: Equatable {
        case card
        case slim(symbol: String)
    }

    static let cardHeight: CGFloat = 76
    static let compactCardHeight: CGFloat = 56
    static let slimHeight: CGFloat = 36
    static let slimMetaHeight: CGFloat = 52

    private let monogram = ShellMonogramView()
    private let kindIcon = NSImageView()
    private let projectLabel = NSTextField.label("", size: Typography.smallSize)
    private let pillView = ShellStatusPillView()
    private let titleLabel = NSTextField.label("", size: Typography.bodySize, weight: .medium)
    private let metaLabel = NSTextField.label("", size: Typography.smallSize)
    private let jumpBadge = ShellJumpHintBadge()
    private let closeButton = SidebarRowView.makeCloseButton(accessibilityLabel: "Close Pane")
    private var heightConstraint: NSLayoutConstraint!
    private var onSelect: (() -> Void)?
    private var onClose: (() -> Void)?
    private var kind: Kind = .card
    private var meta = PaneContextLine()
    private var showsShortcut = false
    private var isFocusedPane = false
    private var inActiveWindow = true
    private var recedes = false

    override init() {
        super.init()
        pillView.label.identifier = NSUserInterfaceItemIdentifier("pane-status-label")
        metaLabel.identifier = NSUserInterfaceItemIdentifier("pane-row-meta")
        jumpBadge.identifier = NSUserInterfaceItemIdentifier("sidebar-jump-pane")
        kindIcon.imageScaling = .scaleNone
        closeButton.target = self
        closeButton.action = #selector(handleClose)
        for view in [monogram, kindIcon, projectLabel, titleLabel, metaLabel, pillView, jumpBadge, closeButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        heightConstraint = heightAnchor.constraint(equalToConstant: Self.cardHeight)
        heightConstraint.isActive = true
        indent = SidebarView.paneIndent
    }

    var hasLiveTime: Bool { !pillView.isHidden && pillView.hasLiveTime }

    func refreshTime(_ now: Date) {
        pillView.refreshTime(now)
        needsLayout = true
    }

    func configure(
        kind: Kind,
        title: String,
        project: String?,
        meta: PaneContextLine,
        pill: ShellStatusPill?,
        idleSince: Date?,
        recedes: Bool,
        shortcutCaps caps: [String]?,
        showShortcutHint: Bool,
        highlighted: Bool,
        inActiveWindow: Bool,
        now: Date,
        onSelect: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.onSelect = onSelect
        self.onClose = onClose
        self.kind = kind
        self.recedes = recedes
        self.inActiveWindow = inActiveWindow
        isFocusedPane = highlighted

        switch kind {
        case .card:
            monogram.projectName = project
            monogram.isHidden = project == nil
            kindIcon.isHidden = true
            projectLabel.isHidden = false
            projectLabel.stringValue = project ?? "No folder"
        case .slim(let symbol):
            monogram.isHidden = true
            kindIcon.isHidden = false
            kindIcon.image = NSImage.symbol(symbol, size: 13)
            projectLabel.isHidden = true
        }
        pillView.configure(pill, relativeTo: kind == .card ? idleSince : nil, now: now)

        showsShortcut = showShortcutHint && caps != nil
        if let caps, jumpBadge.caps != caps {
            jumpBadge.caps = caps
            jumpBadge.toolTip = caps.map { $0.replacingOccurrences(of: "⌃⇧", with: "Ctrl+Shift+") }
                .joined(separator: ", then ")
        }

        titleLabel.stringValue = title
        self.meta = meta
        updateMeta()
        hoverStateDidChange()
    }

    override func hoverStateDidChange() {
        let palette = PaletteCenter.shared.palette
        background.style = isFocusedPane
            ? (isInKeyWindow ? .selected : .selectedUnfocused)
            : (isHovered ? .hover : .none)
        jumpBadge.isHidden = !showsShortcut
        closeButton.alphaValue = showsShortcut || !isHovered ? 0 : 1
        pillView.isHidden = showsShortcut || isHovered || pillView.isEmpty
        let lit = isFocusedPane || isHovered
        switch kind {
        case .card:
            let receding = recedes && !lit
            titleLabel.font = Typography.ui(Typography.bodySize, weight: receding ? .regular : .medium)
            titleLabel.textColor = receding || !inActiveWindow
                ? palette.sidebarForeground.shellScaled(by: 0.75)
                : palette.sidebarForeground
        case .slim:
            titleLabel.font = Typography.ui(Typography.bodySize, weight: lit ? .medium : .regular)
            titleLabel.textColor = lit ? palette.sidebarForeground
                : inActiveWindow ? palette.sidebarForeground.shellScaled(by: 0.85)
                : palette.secondaryLabel
        }
        kindIcon.contentTintColor = lit ? palette.sidebarForeground : palette.sidebarMutedForeground
        projectLabel.textColor = palette.secondaryLabel
        metaLabel.attributedStringValue = meta.attributed(font: Typography.ui(Typography.smallSize), color: palette.secondaryLabel)
        needsLayout = true
    }

    func setTitle(_ title: String) {
        guard titleLabel.stringValue != title else { return }
        titleLabel.stringValue = title
        needsLayout = true
    }

    func setProject(_ project: String?) {
        guard kind == .card else { return }
        monogram.projectName = project
        monogram.isHidden = project == nil
        projectLabel.stringValue = project ?? "No folder"
        needsLayout = true
    }

    func setMeta(_ meta: PaneContextLine) {
        guard self.meta != meta else { return }
        self.meta = meta
        updateMeta()
    }

    private func updateMeta() {
        let palette = PaletteCenter.shared.palette
        metaLabel.attributedStringValue = meta.attributed(font: Typography.ui(Typography.smallSize), color: palette.secondaryLabel)
        metaLabel.toolTip = meta.branch.map { "On branch \($0)" }
        metaLabel.isHidden = meta.isEmpty
        heightConstraint.constant = switch kind {
        case .card: meta.isEmpty ? Self.compactCardHeight : Self.cardHeight
        case .slim: meta.isEmpty ? Self.slimHeight : Self.slimMetaHeight
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let left = ShellSidebarMetrics.contentLeft + indent
        let right = bounds.width - ShellSidebarMetrics.contentLeft
        switch kind {
        case .card:
            let line1: CGFloat = 1 + 8
            let line2 = line1 + 24
            let line3 = line2 + 22
            var x = left
            if !monogram.isHidden {
                monogram.frame = NSRect(x: x, y: line1 + 2, width: 16, height: 16)
                x += 16 + 6
            }
            let slotLeft = layoutTrailingSlot(right: right, lineY: line1)
            let projectSize = projectLabel.intrinsicContentSize
            projectLabel.frame = NSRect(x: x - 2, y: line1 + (20 - projectSize.height) / 2, width: max(0, slotLeft - 6 - x + 4), height: projectSize.height)
            let titleSize = titleLabel.intrinsicContentSize
            titleLabel.frame = NSRect(x: left - 2, y: line2 + (20 - titleSize.height) / 2, width: max(0, right - left + 4), height: titleSize.height)
            let metaSize = metaLabel.intrinsicContentSize
            metaLabel.frame = NSRect(x: left - 2, y: line3 + (16 - metaSize.height) / 2, width: max(0, right - left + 4), height: metaSize.height)
        case .slim:
            let titleLineY: CGFloat = metaLabel.isHidden ? (bounds.height - 20) / 2 : 7
            kindIcon.frame = NSRect(x: left, y: titleLineY + 2, width: 16, height: 16)
            let textLeft = left + 16 + 10
            let slotLeft = layoutTrailingSlot(right: right, lineY: titleLineY)
            let titleSize = titleLabel.intrinsicContentSize
            titleLabel.frame = NSRect(x: textLeft - 2, y: titleLineY + (20 - titleSize.height) / 2, width: max(0, slotLeft - 8 - textLeft + 4), height: titleSize.height)
            let metaSize = metaLabel.intrinsicContentSize
            metaLabel.frame = NSRect(x: textLeft - 2, y: titleLineY + 21, width: max(0, right - textLeft + 4), height: metaSize.height)
        }
    }

    /// Pill, jump hint and close button share the slot at the first line's
    /// right edge; returns where the slot starts.
    private func layoutTrailingSlot(right: CGFloat, lineY: CGFloat) -> CGFloat {
        closeButton.frame = NSRect(x: right + 4 - 20, y: lineY, width: 20, height: 20)
        var slotLeft = right
        if !jumpBadge.isHidden {
            let width = jumpBadge.intrinsicContentSize.width
            jumpBadge.frame = NSRect(x: right + 4 - width, y: lineY, width: width, height: 20)
            slotLeft = jumpBadge.frame.minX
        } else if !pillView.isHidden {
            let width = pillView.intrinsicContentSize.width
            pillView.frame = NSRect(x: right - width, y: lineY, width: width, height: 20)
            slotLeft = pillView.frame.minX
        } else if closeButton.alphaValue > 0 {
            slotLeft = closeButton.frame.minX
        }
        return slotLeft
    }

    @objc private func handleClose() {
        onClose?()
    }

    override func mouseDown(with event: NSEvent) {
        if let superview, isInteractiveSubview(hitTest(superview.convert(event.locationInWindow, from: nil))) {
            super.mouseDown(with: event)
            return
        }
        onSelect?()
    }
}

// MARK: - List

/// Document view for the pane list's NSScrollView. Flipping the coordinate
/// system anchors content to the top and lets the view grow taller than the
/// viewport (via a `>=` bottom pin) so the scroller engages on overflow
/// instead of Auto Layout forcing document height to equal viewport height.
///
/// It also owns the hover, like the file explorer: one tracking area follows
/// the pointer and marks the row under it, so at most one row shows its fill
/// and close button. Rows must not track the pointer themselves. They move
/// under a resting pointer whenever ⌃ expands collapsed windows, a pane opens
/// or closes, or the list scrolls, and AppKit sends no exit for a tracking
/// area that is replaced as its view moves, which left rows hovered for good.
/// The hover is therefore re-read from the last pointer position after every
/// layout and scroll.
private final class SidebarListView: NSView {
    weak var rowsStack: NSStackView?
    /// The pointer in window coordinates while it is over the list.
    private var pointerInWindow: NSPoint?
    private var hoverArea: NSTrackingArea?
    private weak var hoveredRow: SidebarRowView?

    /// An expanded window's span, from its title row to its last pane row.
    struct Guide {
        let window: NSView
        let lastPane: NSView
    }

    /// One hairline per expanded window in the panes' indent, under the
    /// window title's first letter.
    var guides: [Guide] = [] {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Tracking stops while another app is active, without an exit event.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive(_:)),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        PaletteCenter.shared.addObserver(self) { [weak self] _ in self?.needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !guides.isEmpty else { return }
        PaletteCenter.shared.palette.sidebarBorder.setFill()
        let x = ShellSidebarMetrics.contentLeft
        for guide in guides {
            let top = guide.window.convert(guide.window.bounds, to: self).maxY - 6
            let bottom = guide.lastPane.convert(guide.lastPane.bounds, to: self).maxY - 6
            let line = NSRect(x: x, y: top, width: 1, height: bottom - top)
            guard line.height > 0, line.intersects(dirtyRect) else { continue }
            line.fill()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        guard let clipView = superview as? NSClipView else { return }
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea {
            removeTrackingArea(hoverArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        pointerInWindow = event.locationInWindow
        refreshHover()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        pointerInWindow = event.locationInWindow
        refreshHover()
    }

    override func mouseExited(with event: NSEvent) {
        pointerInWindow = nil
        refreshHover()
    }

    /// Rows settle inside the stack after this view's own layout, so they are
    /// laid out before the hover is re-read.
    override func layout() {
        super.layout()
        rowsStack?.layoutSubtreeIfNeeded()
        // The guides follow the rows' new frames.
        needsDisplay = true
        refreshHover()
    }

    @objc private func clipViewDidScroll(_ notification: Notification) {
        refreshHover()
    }

    @objc private func applicationDidResignActive(_ notification: Notification) {
        pointerInWindow = nil
        refreshHover()
    }

    private func refreshHover() {
        let pointed = pointerInWindow.flatMap { row(at: convert($0, from: nil)) }
        guard pointed !== hoveredRow else { return }
        hoveredRow?.isHovered = false
        hoveredRow = pointed
        pointed?.isHovered = true
    }

    private func row(at point: NSPoint) -> SidebarRowView? {
        guard visibleRect.contains(point), let rowsStack else { return nil }
        return rowsStack.arrangedSubviews.lazy
            .compactMap { $0 as? SidebarRowView }
            .first { $0.convert($0.bounds, to: self).contains(point) }
    }
}

// MARK: - Nav Row

/// A page entry above the windows (`Automations`): Agents' row look — a
/// 16 pt muted symbol and a 14 pt label, the hover fill under the pointer and
/// the active fill while its page is open.
private final class SidebarNavRowView: NSView {
    var onClick: (() -> Void)?
    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            setAccessibilitySelected(isSelected)
            refresh()
        }
    }

    private let background = ShellRowSurfaceView()
    private let iconView = NSImageView()
    private let titleLabel: NSTextField
    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            refresh()
        }
    }

    init(title: String, symbolName: String) {
        titleLabel = NSTextField.label(title, size: Typography.bodySize, weight: .medium)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        iconView.image = NSImage.symbol(symbolName, size: 13)
        iconView.imageScaling = .scaleNone
        iconView.setAccessibilityElement(false)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ShellSidebarMetrics.contentLeft),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -ShellSidebarMetrics.contentLeft),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        PaletteCenter.shared.addObserver(self) { [weak self] _ in self?.refresh() }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func refresh() {
        let palette = PaletteCenter.shared.palette
        background.style = isSelected ? .selected : (isHovered ? .hover : .none)
        let lit = isSelected || isHovered
        iconView.contentTintColor = lit ? palette.sidebarForeground : palette.sidebarMutedForeground
        titleLabel.textColor = lit ? palette.sidebarForeground : palette.sidebarMutedForeground
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { isHovered = false }
    }

    override func viewDidHide() {
        super.viewDidHide()
        isHovered = false
    }

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0 else { return }
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}
