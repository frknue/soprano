import AppKit

/// Persistent sidebar showing collapsible logical windows and their panes.
final class SidebarView: NSView {
    /// The session popup's header and the WINDOWS heading are 32 pt each.
    static let headerHeight: CGFloat = 32
    /// The Automations entry between them, a 28 pt row like a window row.
    static let navRowHeight: CGFloat = 28
    /// Rows sit 1 pt apart. Panes that share a tab stay that close, a new tab
    /// starts a little further down, and a new window further still, so the
    /// list groups itself without a label on every row.
    static let rowGap: CGFloat = 1
    static let tabGap: CGFloat = 5
    static let windowGap: CGFloat = 10

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

    private var contentWidthConstraint: NSLayoutConstraint!
    private var contentContainer: NSView!
    private var headerView: ChromeEyebrowView!
    private var automationsRow: SidebarNavRowView!
    private var sessionSelector: NSPopUpButton!
    private var scrollView: NSScrollView!
    private var listContentView: SidebarListView!
    private var rowsStack: NSStackView!
    private var footerView: NSView!
    private var footerSeparator: ChromeRuleView!
    private var trailingBorder: ChromeRuleView!
    private var settingsButton: ChromeIconButton!
    private var dashboardButton: ChromeIconButton!
    private var plusButton: ChromeIconButton!
    private var collapseAllButton: ChromeIconButton!
    private var sessionsButton: ChromeIconButton!
    private var isResizeHighlighted = false
    private var isControlKeyHeld = false
    private var typedPaneHint = ""
    private var windowRows: [String: SidebarWindowRowView] = [:]
    private var paneRows: [String: SidebarPaneRowView] = [:]
    private var displayedWindowId: String?
    private var needsActiveWindowReveal = false

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
        guard needsActiveWindowReveal,
              scrollView.contentSize.height > 0,
              let row = windowRows[agentManager.activeWindowId]
        else { return }
        // Reconciled rows need their final frames before AppKit can reveal one.
        listContentView.layoutSubtreeIfNeeded()
        needsActiveWindowReveal = false
        row.scrollToVisible(row.bounds)
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

        sessionSelector = NSPopUpButton(frame: .zero, pullsDown: false)
        sessionSelector.identifier = NSUserInterfaceItemIdentifier("session-selector")
        sessionSelector.setAccessibilityLabel("Current Session")
        sessionSelector.font = ChromeFont.labelStrong
        // Borderless, like the rows under it: the bezel made the session
        // name the heaviest thing in the sidebar.
        sessionSelector.isBordered = false
        sessionSelector.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sessionSelector.target = self
        sessionSelector.action = #selector(sessionSelected(_:))
        sessionSelector.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(sessionSelector)

        headerView = ChromeEyebrowView(title: "WINDOWS", theme: themeManager.currentTheme)

        automationsRow = SidebarNavRowView(
            title: "Automations",
            symbolName: "calendar.badge.clock",
            theme: themeManager.currentTheme
        )
        automationsRow.identifier = NSUserInterfaceItemIdentifier("sidebar-automations")
        automationsRow.onClick = { [weak self] in
            self?.onAutomationsRequested?()
        }
        contentContainer.addSubview(automationsRow)
        contentContainer.addSubview(headerView)

        plusButton = makeIconButton(
            symbolName: "plus",
            accessibilityLabel: "New Window or Pane",
            action: #selector(plusClicked)
        )
        contentContainer.addSubview(plusButton)

        collapseAllButton = ChromeIconButton(
            symbolName: "rectangle.compress.vertical",
            accessibilityLabel: "Collapse All Windows",
            pointSize: 12,
            target: self,
            action: #selector(collapseAllClicked)
        )
        contentContainer.addSubview(collapseAllButton)

        scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
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

        footerSeparator = ChromeRuleView(axis: .horizontal)
        footerView.addSubview(footerSeparator)

        settingsButton = makeIconButton(
            symbolName: "gearshape",
            accessibilityLabel: "Settings",
            action: #selector(settingsClicked)
        )
        footerView.addSubview(settingsButton)

        sessionsButton = makeIconButton(
            symbolName: "clock.arrow.trianglehead.counterclockwise.rotate.90",
            accessibilityLabel: "Saved Workspaces",
            action: #selector(sessionsClicked)
        )
        footerView.addSubview(sessionsButton)

        dashboardButton = makeIconButton(
            symbolName: "chart.xyaxis.line",
            accessibilityLabel: "Agent Dashboard",
            action: #selector(dashboardClicked)
        )
        footerView.addSubview(dashboardButton)

        trailingBorder = ChromeRuleView(axis: .vertical)
        addSubview(trailingBorder)

        contentWidthConstraint = contentContainer.widthAnchor.constraint(
            equalToConstant: SidebarWidthStore.left.defaultWidth
        )

        NSLayoutConstraint.activate([
            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.topAnchor.constraint(equalTo: topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentWidthConstraint,

            // Sidebar header (32): the session popup.
            sessionSelector.centerYAnchor.constraint(
                equalTo: contentContainer.topAnchor,
                constant: Self.headerHeight / 2
            ),
            sessionSelector.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: 8),
            sessionSelector.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -8),
            // Automations (28): the page entry under the popup.
            automationsRow.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: Self.headerHeight),
            automationsRow.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            automationsRow.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            automationsRow.heightAnchor.constraint(equalToConstant: Self.navRowHeight),
            // Section heading (32): WINDOWS, Collapse All and New on the right.
            headerView.centerYAnchor.constraint(
                equalTo: contentContainer.topAnchor,
                constant: Self.headerHeight * 1.5 + Self.navRowHeight
            ),
            headerView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: 12),
            headerView.trailingAnchor.constraint(equalTo: collapseAllButton.leadingAnchor, constant: -6),

            scrollView.topAnchor.constraint(
                equalTo: contentContainer.topAnchor,
                constant: Self.headerHeight * 2 + Self.navRowHeight
            ),
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
            footerSeparator.heightAnchor.constraint(equalToConstant: Chrome.hairline),

            settingsButton.trailingAnchor.constraint(equalTo: footerView.trailingAnchor, constant: -8),
            settingsButton.centerYAnchor.constraint(equalTo: footerView.centerYAnchor),

            plusButton.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -6),
            plusButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

            collapseAllButton.trailingAnchor.constraint(equalTo: plusButton.leadingAnchor, constant: -2),
            collapseAllButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

            sessionsButton.leadingAnchor.constraint(equalTo: footerView.leadingAnchor, constant: 8),
            sessionsButton.centerYAnchor.constraint(equalTo: footerView.centerYAnchor),

            dashboardButton.leadingAnchor.constraint(equalTo: sessionsButton.trailingAnchor, constant: 2),
            dashboardButton.centerYAnchor.constraint(equalTo: footerView.centerYAnchor),

            trailingBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            trailingBorder.topAnchor.constraint(equalTo: topAnchor),
            trailingBorder.bottomAnchor.constraint(equalTo: bottomAnchor),
            trailingBorder.widthAnchor.constraint(equalToConstant: Chrome.hairline),
        ])
    }

    private func makeIconButton(
        symbolName: String,
        accessibilityLabel: String,
        action: Selector
    ) -> ChromeIconButton {
        ChromeIconButton(
            symbolName: symbolName,
            accessibilityLabel: accessibilityLabel,
            target: self,
            action: action
        )
    }

    /// Width of the sidebar's content. Kept in step with the view's own width so
    /// rows lay out at the dragged size instead of being clipped at the default.
    func setContentWidth(_ width: CGFloat) {
        contentWidthConstraint.constant = width
    }

    /// Darkens the trailing border to the splitter color while the resize
    /// handle is hovered or dragged, so the draggable edge is visible before
    /// the mouse goes down.
    func setResizeHighlighted(_ isHighlighted: Bool) {
        isResizeHighlighted = isHighlighted
        applyTrailingBorderColor(theme: themeManager.currentTheme)
    }

    private func applyTrailingBorderColor(theme: AppTheme) {
        trailingBorder.color = isResizeHighlighted
            ? theme.colors.borderStrong
            : theme.colors.borderSubtle
    }

    func setControlKeyHeld(_ isHeld: Bool) {
        guard isControlKeyHeld != isHeld else { return }
        isControlKeyHeld = isHeld
        rebuildRows(theme: themeManager.currentTheme)
    }

    /// Letters of a longer pane hint typed so far. The hints stay up, even
    /// once ⌃ is released, narrowed to the panes the letters still reach.
    func setTypedPaneHint(_ typed: String) {
        guard typedPaneHint != typed else { return }
        typedPaneHint = typed
        rebuildRows(theme: themeManager.currentTheme)
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
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -2), in: plusButton)
    }

    @objc private func newWindowClicked() {
        _ = agentManager.createWindow()
    }

    @objc private func spawnMenuItemClicked(_ sender: NSMenuItem) {
        guard let profileId = sender.representedObject as? String else { return }
        _ = agentManager.spawnAgent(profileId)
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
        let alert = NSAlert()
        alert.messageText = "Save Workspace"
        alert.informativeText = "Save a snapshot of all sessions and their window layouts:"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "Workspace name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        sessionManager.saveSession(name: name)
    }

    // MARK: - Refresh

    func refreshTheme() {
        // Rows take their colors when they are built.
        rowsStack.setArrangedSubviews([])
        windowRows.removeAll()
        paneRows.removeAll()
        refresh()
    }

    private func refresh() {
        let theme = themeManager.currentTheme
        layer?.backgroundColor = theme.colors.bgPanel.cgColor
        headerView.apply(theme: theme)
        footerSeparator.color = theme.colors.borderSubtle
        applyTrailingBorderColor(theme: theme)
        for button in [settingsButton, dashboardButton, plusButton, collapseAllButton, sessionsButton] {
            button?.apply(theme: theme)
        }
        automationsRow.apply(theme: theme)
        rebuildSessionSelector()
        collapseAllButton.isEnabled = agentManager.activeSessionWindows.contains { !$0.isSidebarCollapsed }

        // Reconcile watchers first so rows read freshly-invalidated caches.
        gitBranchMonitor.setWatchedPaths(watchedCwds())
        rebuildRows(theme: theme)
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
    private func rebuildRows(theme: AppTheme) {
        let paneShortcutKeysById = Dictionary(
            uniqueKeysWithValues: agentManager.paneShortcutAssignments.map {
                ($0.paneId, $0.key)
            }
        )
        // Holding ⌃ shows the hints; a started hint keeps them up.
        let showsHints = isControlKeyHeld || !typedPaneHint.isEmpty
        var rows: [NSView] = []
        // The gap under each row, by index into `rows`.
        var gaps: [CGFloat] = []
        var nextWindowRows: [String: SidebarWindowRowView] = [:]
        var nextPaneRows: [String: SidebarPaneRowView] = [:]
        for (index, terminalWindow) in agentManager.activeSessionWindows.enumerated() {
            let isActiveWindow = terminalWindow.id == agentManager.activeWindowId
            let isExpanded = showsHints
                || !terminalWindow.isSidebarCollapsed
            let paneIds = terminalWindow.paneIds
            let windowRow = windowRows[terminalWindow.id] ?? {
                let row = SidebarWindowRowView(theme: theme)
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
                        let row = SidebarPaneRowView(theme: theme)
                        row.identifier = NSUserInterfaceItemIdentifier("sidebar-pane-\(pane.id)")
                        return row
                    }()
                    let title = sidebarTitle(for: pane)
                    row.configure(
                        title: title,
                        meta: meta(for: pane, title: title),
                        status: paneStatus(for: pane),
                        statusWord: paneStatusWord(for: pane),
                        shortcutCaps: paneShortcutKeysById[pane.id].flatMap {
                            Self.paneHintCaps(for: $0, typed: typedPaneHint)
                        },
                        showShortcutHint: showsHints,
                        highlighted: isActiveWindow && pane.id == agentManager.activePaneId,
                        inActiveWindow: isActiveWindow,
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
        }
        windowRows = nextWindowRows
        paneRows = nextPaneRows
        rowsStack.setArrangedSubviews(rows) { row in
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }
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

    private func rebuildSessionSelector() {
        sessionSelector.removeAllItems()
        for session in agentManager.orderedSessions {
            let item = NSMenuItem(title: session.name, action: nil, keyEquivalent: "")
            item.representedObject = session.id
            sessionSelector.menu?.addItem(item)
            if session.id == agentManager.activeSessionId {
                sessionSelector.select(item)
            }
        }
        sessionSelector.menu?.addItem(.separator())
        for (title, action) in [
            ("New Session…", #selector(promptToCreateSession)),
            ("Rename Session…", #selector(promptToRenameSession)),
            ("Close Session…", #selector(promptToCloseSession)),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            sessionSelector.menu?.addItem(item)
        }
    }

    @objc private func sessionSelected(_ sender: NSPopUpButton) {
        guard let sessionId = sender.selectedItem?.representedObject as? String else { return }
        agentManager.activateSession(sessionId)
    }

    @objc func promptToCreateSession() {
        guard let name = promptForSessionName(title: "New Session", initialName: "") else {
            rebuildSessionSelector()
            return
        }
        _ = agentManager.createSession(name: name)
    }

    @objc func promptToRenameSession() {
        guard let session = agentManager.activeSession else { return }
        guard let name = promptForSessionName(title: "Rename Session", initialName: session.name) else {
            rebuildSessionSelector()
            return
        }
        agentManager.renameSession(session.id, to: name)
    }

    private func promptForSessionName(title: String, initialName: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Name this group of windows."
        alert.addButton(withTitle: initialName.isEmpty ? "Create" : "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Session name"
        field.stringValue = initialName
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    @objc func promptToCloseSession() {
        guard let session = agentManager.activeSession else { return }
        let alert = NSAlert()
        alert.messageText = "Close \"\(session.name)\"?"
        alert.informativeText = "All windows and running terminals in this session will close."
        alert.addButton(withTitle: "Close Session")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            rebuildSessionSelector()
            return
        }
        agentManager.closeSession(session.id)
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

    /// The second line under `title`; see `PaneContextLine`.
    private func meta(for pane: PaneState, title: String) -> PaneContextLine {
        guard let tab = pane.activeTab else { return PaneContextLine() }
        let cwd = tab.effectiveWorkingDirectory
        return PaneContextLine(
            title: title,
            agentName: tab.agent.flatMap { AgentCatalog.profile(for: $0.profileId)?.name },
            workingDirectory: cwd,
            branch: cwd.flatMap { gitBranchMonitor.notableBranch(for: $0) },
            tabCount: pane.tabs.count
        )
    }

    private func watchedCwds() -> [String] {
        agentManager.panes.values.flatMap { pane in
            pane.tabs.compactMap(\.effectiveWorkingDirectory)
        }
    }

    // MARK: - Status

    /// The pane's mark: the active tab's agent speaks for the pane; without
    /// one, a command running in any of its tabs shows RUNNING. A plain shell
    /// is `.idle`, which its row draws as no mark at all.
    private func paneStatus(for pane: PaneState) -> ChromeStatus {
        if let agent = pane.activeTab?.agent {
            return agent.status.chromeStatus
        }
        return paneRunsCommand(pane) ? .running : .idle
    }

    /// The status word beside the title; nil for plain shells.
    private func paneStatusWord(for pane: PaneState) -> String? {
        if let agent = pane.activeTab?.agent {
            return agent.status.displayLabel
        }
        return paneRunsCommand(pane) ? AgentManager.runningCommandLabel : nil
    }

    private func paneRunsCommand(_ pane: PaneState) -> Bool {
        pane.tabs.contains { agentManager.isRunningCommand($0, in: pane.id) }
    }
}

// MARK: - Row Chrome

/// Key-window tracking shared by the sidebar rows. The row shows its close
/// button and the hover pill only while `isHovered`, which the list sets for
/// the row under the pointer, and the focused row's pencil tick only while
/// its window is key.
private class SidebarRowView: NSView {
    let theme: AppTheme
    let background: ChromeRowBackgroundView
    var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            hoverStateDidChange()
        }
    }

    init(theme: AppTheme) {
        self.theme = theme
        background = ChromeRowBackgroundView(theme: theme)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        background.identifier = NSUserInterfaceItemIdentifier("sidebar-row-background")
        addSubview(background)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        // The palette, an alert or another app taking the keyboard drops the
        // pencil tick, like the pane header's focus rule.
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
            if candidate is NSControl {
                return true
            }
            current = candidate.superview
        }
        return false
    }

    static func makeCloseButton(accessibilityLabel: String) -> ChromeIconButton {
        ChromeIconButton(
            symbolName: "xmark",
            accessibilityLabel: accessibilityLabel,
            pointSize: 9,
            size: 18,
            target: nil,
            action: nil
        )
    }
}

// MARK: - Window Row

/// `⌄ storefront   3 · 1!`: a 28 pt row with the disclosure chevron, the title
/// (ink in the active window, muted elsewhere) and the pane count with the
/// panes that need you in the attention color. Holding ⌃ swaps the count for
/// the window's accent jump keycap; the pointer swaps it for a close button.
private final class SidebarWindowRowView: SidebarRowView {
    static let height: CGFloat = 28

    private let disclosureButton = NSButton(title: "", target: nil, action: nil)
    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let shortcutCap: ChromeKeycapView
    private let closeButton = SidebarRowView.makeCloseButton(accessibilityLabel: "Close Window")
    private var onToggle: (() -> Void)?
    private var onSelect: (() -> Void)?
    private var onRename: (() -> Void)?
    private var onResetTitle: (() -> Void)?
    private var onClose: (() -> Void)?
    private var showsShortcut = false

    override init(theme: AppTheme) {
        shortcutCap = ChromeKeycapView(legend: "", theme: theme, style: .small, tone: .accent)
        super.init(theme: theme)
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
        disclosureButton.contentTintColor = theme.colors.textMuted
        disclosureButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(disclosureButton)

        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        countLabel.alignment = .right
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(countLabel)

        addSubview(shortcutCap)

        closeButton.target = self
        closeButton.action = #selector(handleClose)
        closeButton.apply(theme: theme)
        addSubview(closeButton)

        let trailingInset = Chrome.pillInset + 8
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),

            disclosureButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Chrome.pillInset + 4),
            disclosureButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosureButton.widthAnchor.constraint(equalToConstant: 18),
            disclosureButton.heightAnchor.constraint(equalToConstant: 18),

            titleLabel.leadingAnchor.constraint(equalTo: disclosureButton.trailingAnchor, constant: 4),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: shortcutCap.leadingAnchor, constant: -8),

            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -trailingInset),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            shortcutCap.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -trailingInset),
            shortcutCap.centerYAnchor.constraint(equalTo: centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(Chrome.pillInset + 4)),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
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
        let colors = theme.colors

        let accessibilityLabel = expanded ? "Collapse Window" : "Expand Window"
        disclosureButton.image = NSImage(
            systemSymbolName: expanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: accessibilityLabel
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        disclosureButton.setAccessibilityLabel(accessibilityLabel)
        disclosureButton.toolTip = accessibilityLabel
        titleLabel.setChromeText(
            title,
            font: ChromeFont.labelStrong,
            color: highlighted ? colors.textPrimary : colors.textMuted
        )

        let counts = NSMutableAttributedString(attributedString: ChromeText.attributed(
            "\(paneCount)",
            font: ChromeFont.count,
            color: colors.textMuted
        ))
        if attentionCount > 0 {
            counts.append(ChromeText.attributed(" · ", font: ChromeFont.count, color: colors.textMuted))
            counts.append(ChromeText.attributed("\(attentionCount)!", font: ChromeFont.count, color: colors.attention))
        }
        countLabel.attributedStringValue = counts
        let panes = "\(paneCount) pane\(paneCount == 1 ? "" : "s")"
        countLabel.toolTip = attentionCount > 0
            ? "\(panes), \(attentionCount) agent\(attentionCount == 1 ? "" : "s") ready"
            : panes

        showsShortcut = showShortcutHint && shortcutNumber != nil
        if let shortcutNumber {
            shortcutCap.legend = "⌃\(shortcutNumber)"
            shortcutCap.toolTip = "Ctrl+\(shortcutNumber)"
        }
        hoverStateDidChange()

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

    override func hoverStateDidChange() {
        background.style = isHovered ? .hover : .none
        shortcutCap.isHidden = !showsShortcut
        closeButton.alphaValue = showsShortcut || !isHovered ? 0 : 1
        countLabel.isHidden = showsShortcut || isHovered
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
}

// MARK: - Pane Row

/// A pane under its window: status mark, title and the colored status word,
/// with `omp · soprano · ⎇ feat/x · 2 tabs` muted on a second line when any
/// of it applies (40 pt; 28 without). A plain shell has no mark, so the
/// marks that remain are the agents and commands worth looking at. The
/// focused pane gets the selection pill and pencil tick; every other row is
/// plain. Holding ⌃ swaps the status word for the pane's accent jump
/// keycaps; the pointer swaps it for a close button.
private final class SidebarPaneRowView: SidebarRowView {
    static let height: CGFloat = 40
    static let singleLineHeight: CGFloat = 28
    /// The mark sits under the window title, past the disclosure chevron.
    private static let indent: CGFloat = 18

    private let mark = ChromeStatusMark()
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let shortcutCaps: ChromeKeycapGroupView
    private let closeButton = SidebarRowView.makeCloseButton(accessibilityLabel: "Close Pane")
    private let metaLabel = NSTextField(labelWithString: "")
    private var heightConstraint: NSLayoutConstraint!
    private var titleTopConstraint: NSLayoutConstraint!
    private var onSelect: (() -> Void)?
    private var onClose: (() -> Void)?
    private var titleColor: NSColor
    private var meta = PaneContextLine()
    private var showsShortcut = false
    private var isFocusedPane = false

    override init(theme: AppTheme) {
        shortcutCaps = ChromeKeycapGroupView(caps: [], theme: theme, style: .small, tone: .accent)
        titleColor = theme.colors.textPrimary
        super.init(theme: theme)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setup() {
        addSubview(mark)

        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        statusLabel.identifier = NSUserInterfaceItemIdentifier("pane-status-label")
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        addSubview(shortcutCaps)

        closeButton.target = self
        closeButton.action = #selector(handleClose)
        closeButton.apply(theme: theme)
        addSubview(closeButton)

        metaLabel.identifier = NSUserInterfaceItemIdentifier("pane-row-meta")
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(metaLabel)

        let trailingInset = Chrome.pillInset + 8
        heightConstraint = heightAnchor.constraint(equalToConstant: Self.height)
        titleTopConstraint = titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5)
        NSLayoutConstraint.activate([
            heightConstraint,
            titleTopConstraint,

            mark.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Chrome.pillInset + 8 + Self.indent
            ),
            mark.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusLabel.leadingAnchor, constant: -6),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: shortcutCaps.leadingAnchor, constant: -6),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -6),

            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -trailingInset),
            statusLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            shortcutCaps.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -trailingInset),
            shortcutCaps.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(Chrome.pillInset + 4)),
            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            metaLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            metaLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            metaLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -trailingInset),
        ])
    }

    func configure(
        title: String,
        meta: PaneContextLine,
        status: ChromeStatus,
        statusWord: String?,
        shortcutCaps caps: [String]?,
        showShortcutHint: Bool,
        highlighted: Bool,
        inActiveWindow: Bool,
        onSelect: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.onSelect = onSelect
        self.onClose = onClose
        let colors = theme.colors
        mark.set(status: status, colors: colors)
        mark.isHidden = status == .idle
        if let statusWord {
            statusLabel.setStatusText(statusWord, color: status.color(in: colors))
        } else {
            statusLabel.stringValue = ""
        }

        showsShortcut = showShortcutHint && caps != nil
        // Rebuilding the caps costs views, and this runs on every refresh.
        if let caps, shortcutCaps.caps != caps {
            shortcutCaps.caps = caps
            shortcutCaps.toolTip = caps.map { $0.replacingOccurrences(of: "⌃⇧", with: "Ctrl+Shift+") }
                .joined(separator: ", then ")
        }

        titleColor = inActiveWindow ? colors.textPrimary : colors.textMuted
        titleLabel.setChromeText(title, color: titleColor)
        isFocusedPane = highlighted
        self.meta = meta
        updateMeta()
        hoverStateDidChange()
    }

    override func hoverStateDidChange() {
        background.style = isFocusedPane
            ? (isInKeyWindow ? .selected : .selectedUnfocused)
            : (isHovered ? .hover : .none)
        shortcutCaps.isHidden = !showsShortcut
        closeButton.alphaValue = showsShortcut || !isHovered ? 0 : 1
        statusLabel.isHidden = showsShortcut || isHovered || statusLabel.stringValue.isEmpty
    }

    func setTitle(_ title: String) {
        guard titleLabel.stringValue != title else { return }
        titleLabel.setChromeText(title, color: titleColor)
    }

    func setMeta(_ meta: PaneContextLine) {
        guard self.meta != meta else { return }
        self.meta = meta
        updateMeta()
    }

    private func updateMeta() {
        metaLabel.attributedStringValue = meta.attributed(font: ChromeFont.meta, color: theme.colors.textMuted)
        metaLabel.toolTip = meta.branch.map { "On branch \($0)" }
        metaLabel.isHidden = meta.isEmpty
        heightConstraint.constant = meta.isEmpty ? Self.singleLineHeight : Self.height
        titleTopConstraint.constant = meta.isEmpty ? 6 : 5
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
}

// MARK: - List

/// Document view for the pane list's NSScrollView. Flipping the coordinate
/// system anchors content to the top and lets the view grow taller than the
/// viewport (via a `>=` bottom pin) so the scroller engages on overflow
/// instead of Auto Layout forcing document height to equal viewport height.
///
/// It also owns the hover, like the file explorer: one tracking area follows
/// the pointer and marks the row under it, so at most one row shows its pill
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

/// A page entry above the windows (`Automations`): a 28 pt row with a muted
/// SF Symbol and an SF Pro label. The pointer gives it the `hover` pill;
/// while its page is open it is the raised nav pill, as Settings marks its
/// open tab, with the icon in ink.
private final class SidebarNavRowView: NSView {
    var onClick: (() -> Void)?
    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            setAccessibilitySelected(isSelected)
            refresh()
        }
    }

    private let background: ChromeRowBackgroundView
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let title: String
    private var theme: AppTheme
    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            refresh()
        }
    }

    init(title: String, symbolName: String, theme: AppTheme) {
        self.title = title
        self.theme = theme
        background = ChromeRowBackgroundView(theme: theme)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        iconView.imageScaling = .scaleNone
        iconView.setAccessibilityElement(false)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),

            // The icon sits where a window row's disclosure chevron does.
            iconView.centerXAnchor.constraint(equalTo: leadingAnchor, constant: Chrome.pillInset + 4 + 9),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Chrome.pillInset + 4 + 18 + 4),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -(Chrome.pillInset + 8)),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        background.apply(theme: theme)
        refresh()
    }

    private func refresh() {
        let colors = theme.colors
        background.style = isSelected ? .raisedTab : (isHovered ? .hover : .none)
        iconView.contentTintColor = isSelected || isHovered ? colors.textPrimary : colors.textMuted
        titleLabel.setChromeText(
            title,
            font: isSelected ? ChromeFont.labelStrong : ChromeFont.label,
            color: colors.textPrimary
        )
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
