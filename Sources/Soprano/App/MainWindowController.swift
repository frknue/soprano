import AppKit

final class MainWindowController: NSWindowController {
    let agentManager: AgentManager
    let sessionManager: SessionManager
    let themeManager: ThemeManager
    let gitBranchMonitor: GitBranchMonitor
    var settings: AppSettings

    private var mainContentVC: MainContentViewController?
    private var keybindingManager: KeybindingManager?
    private var commandPalette: CommandPalettePanel?

    init(
        agentManager: AgentManager,
        sessionManager: SessionManager,
        themeManager: ThemeManager,
        gitBranchMonitor: GitBranchMonitor,
        settings: AppSettings
    ) {
        self.agentManager = agentManager
        self.sessionManager = sessionManager
        self.themeManager = themeManager
        self.gitBranchMonitor = gitBranchMonitor
        self.settings = settings

        let mainVisibleFrame =
            NSScreen.main?.visibleFrame ?? MainWindowSizing.fallbackVisibleFrame
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        let startupFrame = MainWindowFrameStore.load(
            visibleFrames: visibleFrames
        ) ?? MainWindowSizing.initialFrame(in: mainVisibleFrame)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: startupFrame.size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Soprano"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = MainWindowSizing.minimumFrameSize
        window.isReleasedWhenClosed = false

        super.init(window: window)

        let contentVC = MainContentViewController(
            agentManager: agentManager,
            sessionManager: sessionManager,
            themeManager: themeManager,
            gitBranchMonitor: gitBranchMonitor,
            onSettingsRequested: { [weak self] in
                self?.openSettings()
            }
        )
        window.contentViewController = contentVC
        // Assigning a content controller can make AppKit consult its fitting
        // size. Reapply the chosen startup frame after the content is attached.
        window.setFrame(startupFrame, display: false)
        window.delegate = self
        self.mainContentVC = contentVC

        let keybindingManager = KeybindingManager(
            agentManager: agentManager,
            config: ConfigStore.shared.keybindings
        )
        keybindingManager.delegate = self
        keybindingManager.stateChangeHandler = { [weak contentVC] state in
            contentVC?.setKeybindingMode(state)
        }
        keybindingManager.controlKeyStateChangeHandler = { [weak contentVC] isHeld in
            contentVC?.setControlKeyHeld(isHeld)
        }
        contentVC.setControlKeyHeld(keybindingManager.isControlKeyHeld)
        self.keybindingManager = keybindingManager

        themeManager.onThemeChanged = { [weak self] theme in
            GhosttyAppManager.shared.applyTheme(theme)
            self?.applyTheme()
            self?.mainContentVC?.refreshTheme()
        }

        applyTheme()
        installCommandsMenu()

        // settings.json is the source of truth: an edit on disk must land in
        // the running app the same way a click in Settings does.
        //
        // The observer is keyed by type and captures self weakly, so it needs
        // no matching teardown — and a `deinit` could not do one safely anyway,
        // since reaching the main-actor store from a nonisolated `deinit`
        // means `assumeIsolated`, which traps if the final release lands off
        // the main thread.
        ConfigStore.shared.addObserver(id: Self.configObserverId) { [weak self] in
            self?.applyConfigChange()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private static let configObserverId = "MainWindowController"

    /// Re-applies everything `settings.json` owns after the file changed.
    private func applyConfigChange() {
        let store = ConfigStore.shared
        settings = store.settings

        if themeManager.currentTheme.id != settings.themeId {
            // setTheme fans out through onThemeChanged to the whole view tree.
            themeManager.setTheme(id: settings.themeId)
        }

        reloadKeybindingManager()
        // The Commands menu carries key equivalents for the actions AppKit
        // dispatches itself; rebuild it so a rebound chord takes effect and the
        // old one stops firing.
        installCommandsMenu()
        // Agent profiles feed pane headers and the sidebar; redraw them so a
        // renamed or recolored agent updates without touching a pane.
        agentManager.reloadAgentProfiles()
        mainContentVC?.refreshSettingsScreenIfVisible(
            settings: settings,
            keybindingConfig: store.keybindings
        )
    }

    func saveLastWorkspaceIfNeeded() {
        saveWindowFrame()
        guard settings.restoreLastSession else { return }
        let session = agentManager.snapshotWorkspace()
        WorkspaceSession.saveLast(session)
    }

    private func saveWindowFrame() {
        guard let window,
              !window.styleMask.contains(.fullScreen)
        else {
            return
        }
        MainWindowFrameStore.save(window.frame)
    }

    private func applyTheme() {
        let theme = themeManager.currentTheme
        window?.backgroundColor = theme.backgroundColor
        window?.appearance = NSAppearance(named: .darkAqua)
    }

    private func palettePanel() -> CommandPalettePanel {
        if let commandPalette {
            return commandPalette
        }

        let panel = CommandPalettePanel(themeManager: themeManager)
        commandPalette = panel
        return panel
    }

    private func commandShortcut(for bindingId: String) -> String? {
        keybindingManager?.config.bindings.first(where: { $0.id == bindingId })?.defaultKeys
    }

    /// One launcher per agent in the catalog, so an agent defined in
    /// settings.json is reachable from `⌘P` exactly like a built-in one.
    /// `terminal` is excluded because "Open Terminal" already covers it.
    private func agentLaunchPaletteItems() -> [CommandItem] {
        AgentCatalog.all
            .filter { $0.id != "terminal" }
            .map { profile in
                CommandItem(
                    id: "launch-\(profile.id)",
                    icon: "command.square",
                    label: "Launch \(profile.name)",
                    description: "Launch the \(profile.name) agent",
                    shortcut: commandShortcut(for: "launch-\(profile.id)"),
                    action: { [weak self] in
                        guard let self else { return }
                        _ = self.agentManager.spawnAgent(profile.id)
                    }
                )
            }
    }

    private func buildCommandPaletteItems() -> [CommandItem] {
        agentLaunchPaletteItems() + [
            CommandItem(
                id: "new-window",
                icon: "macwindow.badge.plus",
                label: "New Window",
                description: "Create a new logical window",
                shortcut: commandShortcut(for: "new-window"),
                action: { [weak self] in
                    guard let self else { return }
                    _ = self.agentManager.createWindow()
                }
            ),
            CommandItem(
                id: "previous-window",
                icon: "chevron.left.square",
                label: "Previous Window",
                description: "Switch to the previous logical window",
                shortcut: commandShortcut(for: "previous-window"),
                action: { [weak self] in
                    self?.agentManager.activatePreviousWindow()
                }
            ),
            CommandItem(
                id: "next-window",
                icon: "chevron.right.square",
                label: "Next Window",
                description: "Switch to the next logical window",
                shortcut: commandShortcut(for: "next-window"),
                action: { [weak self] in
                    self?.agentManager.activateNextWindow()
                }
            ),
            CommandItem(
                id: "last-window",
                icon: "arrow.uturn.backward.square",
                label: "Last Window",
                description: "Switch to the most recently active logical window",
                shortcut: commandShortcut(for: "last-window"),
                action: { [weak self] in
                    self?.agentManager.activateLastWindow()
                }
            ),
            CommandItem(
                id: "find-window",
                icon: "macwindow",
                label: "Find Window…",
                description: "Search and switch to a logical window",
                shortcut: commandShortcut(for: "find-window"),
                action: { [weak self] in
                    DispatchQueue.main.async {
                        self?.keybindingFindWindow()
                    }
                }
            ),
            CommandItem(
                id: "rename-window",
                icon: "pencil",
                label: "Rename Window…",
                description: "Rename the active logical window",
                shortcut: commandShortcut(for: "rename-window"),
                action: { [weak self] in
                    self?.keybindingRenameWindow()
                }
            ),
            CommandItem(
                id: "close-window",
                icon: "xmark.rectangle",
                label: "Close Window",
                description: "Close the active logical window",
                shortcut: commandShortcut(for: "close-window"),
                action: { [weak self] in
                    guard let self else { return }
                    self.agentManager.closeWindow(self.agentManager.activeWindowId)
                }
            ),
            CommandItem(
                id: "open-project",
                icon: "folder",
                label: "Open Project…",
                description: "Search configured projects or choose a directory",
                shortcut: commandShortcut(for: "open-project"),
                action: { [weak self] in
                    // The current palette dismisses after executing an item;
                    // reopen it in project mode on the next run-loop turn.
                    DispatchQueue.main.async {
                        self?.keybindingOpenProjectSearch()
                    }
                }
            ),
            CommandItem(
                id: "new-terminal",
                icon: "terminal",
                label: "Open Terminal",
                description: "Open a new terminal pane",
                shortcut: commandShortcut(for: "new-terminal"),
                action: { [weak self] in
                    guard let self else { return }
                    _ = self.agentManager.spawnTerminal()
                }
            ),
            CommandItem(
                id: "new-browser",
                icon: "globe",
                label: "Open Browser",
                description: "Split a browser pane to the right",
                shortcut: commandShortcut(for: "new-browser"),
                action: { [weak self] in
                    guard let self else { return }
                    _ = self.agentManager.spawnBrowser()
                }
            ),
            CommandItem(
                id: "split-horizontal",
                icon: "rectangle.split.1x2",
                label: "Split Horizontal",
                description: "Split the active pane horizontally",
                shortcut: commandShortcut(for: "split-horizontal"),
                action: { [weak self] in
                    guard let self else { return }
                    guard let direction = KeybindingManager.splitDirection(
                        for: "split-horizontal"
                    ) else { return }
                    _ = self.agentManager.splitPane(
                        direction: direction,
                        paneId: self.agentManager.activePaneId
                    )
                }
            ),
            CommandItem(
                id: "split-vertical",
                icon: "rectangle.split.2x1",
                label: "Split Vertical",
                description: "Split the active pane vertically",
                shortcut: commandShortcut(for: "split-vertical"),
                action: { [weak self] in
                    guard let self else { return }
                    guard let direction = KeybindingManager.splitDirection(
                        for: "split-vertical"
                    ) else { return }
                    _ = self.agentManager.splitPane(
                        direction: direction,
                        paneId: self.agentManager.activePaneId
                    )
                }
            ),
            CommandItem(
                id: "pane-depth-in",
                icon: "arrow.down.right.and.arrow.up.left",
                label: "Go In",
                description: "Open or resume a terminal one level into the active pane",
                shortcut: commandShortcut(for: "pane-depth-in"),
                action: { [weak self] in
                    guard let self else { return }
                    _ = self.agentManager.goIn(self.agentManager.activePaneId)
                }
            ),
            CommandItem(
                id: "pane-depth-out",
                icon: "arrow.up.left.and.arrow.down.right",
                label: "Go Out",
                description: "Return to the terminal one level out of the active pane",
                shortcut: commandShortcut(for: "pane-depth-out"),
                action: { [weak self] in
                    guard let self else { return }
                    _ = self.agentManager.goOut(self.agentManager.activePaneId)
                }
            ),
            CommandItem(
                id: "close-pane",
                icon: "xmark.square",
                label: "Close Pane",
                description: "Close the active pane",
                shortcut: commandShortcut(for: "close-pane") ?? commandShortcut(for: "close-active"),
                action: { [weak self] in
                    guard let self else { return }
                    self.agentManager.closePane(self.agentManager.activePaneId)
                }
            ),
            CommandItem(
                id: "restart-agent",
                icon: "arrow.clockwise",
                label: "Restart Agent",
                description: "Restart the active agent",
                shortcut: nil,
                action: { [weak self] in
                    guard let self else { return }
                    self.agentManager.restartAgent(paneId: self.agentManager.activePaneId)
                }
            ),
            CommandItem(
                id: "stop-agent",
                icon: "stop.square",
                label: "Stop Agent",
                description: "Stop the active agent",
                shortcut: nil,
                action: { [weak self] in
                    guard let self else { return }
                    self.agentManager.stopAgent(paneId: self.agentManager.activePaneId)
                }
            ),
            CommandItem(
                id: "save-session",
                icon: "square.and.arrow.down",
                label: "Save Session As…",
                description: "Save the current workspace as a named session",
                shortcut: commandShortcut(for: "save-session"),
                action: { [weak self] in
                    self?.keybindingSaveSession()
                }
            ),
            CommandItem(
                id: "agent-dashboard",
                icon: "chart.xyaxis.line",
                label: "Agent Dashboard",
                description: "Monitor every agent across all windows",
                shortcut: commandShortcut(for: "agent-dashboard"),
                searchText: "agents monitor status attention working",
                action: { [weak self] in
                    DispatchQueue.main.async {
                        self?.mainContentVC?.showDashboard()
                    }
                }
            ),
            CommandItem(
                id: "toggle-sidebar",
                icon: "sidebar.leading",
                label: "Toggle Sidebar",
                description: "Show or hide the sidebar",
                shortcut: commandShortcut(for: "toggle-sidebar"),
                action: { [weak self] in
                    self?.keybindingToggleSidebar()
                }
            ),
            CommandItem(
                id: "open-settings",
                icon: "gearshape",
                label: "Settings",
                description: "Open the settings screen",
                shortcut: commandShortcut(for: "open-settings"),
                action: { [weak self] in
                    DispatchQueue.main.async {
                        self?.openSettings()
                    }
                }
            ),
            CommandItem(
                id: "open-settings-json",
                icon: "curlybraces",
                label: "Open settings.json",
                description: ConfigStore.shared.displayPath,
                shortcut: nil,
                searchText: "config json edit settings file",
                action: {
                    ConfigStore.shared.openInEditor()
                }
            ),
        ]
    }
}

extension MainWindowController: NSWindowDelegate {
    func windowDidMove(_ notification: Notification) {
        saveWindowFrame()
    }

    func windowDidResize(_ notification: Notification) {
        saveWindowFrame()
    }

    func windowWillClose(_ notification: Notification) {
        saveWindowFrame()
    }
}

extension MainWindowController: KeybindingDelegate {
    func keybindingToggleSidebar() {
        mainContentVC?.toggleSidebar()
    }

    func keybindingSaveSession() {
        mainContentVC?.saveSessionAs()
    }

    func keybindingRenameWindow() {
        mainContentVC?.renameActiveWindow()
    }

    func keybindingOpenSettings() {
        openSettings()
    }

    func keybindingOpenAgentDashboard() {
        mainContentVC?.showDashboard()
    }

    func keybindingOpenCommandPalette() {
        guard let window else { return }

        let panel = palettePanel()
        let commands = buildCommandPaletteItems()
        panel.show(relativeTo: window, commands: commands)
    }

    func keybindingFindWindow() {
        guard let window else { return }

        let panel = palettePanel()
        panel.show(
            relativeTo: window,
            commands: buildWindowPaletteItems(),
            placeholder: "Search windows and panes..."
        )
    }

    func keybindingOpenProjectSearch() {
        guard let window else { return }

        let panel = palettePanel()
        panel.show(
            relativeTo: window,
            commands: buildProjectPaletteItems(),
            placeholder: "Search projects..."
        )
    }

    func keybindingZoom(delta: Int) {
        mainContentVC?.changeActiveTerminalFontSize(delta: delta)
    }

    func keybindingZoomReset() {
        mainContentVC?.resetActiveTerminalFontSize()
    }

    func keybindingStartCopyMode() {
        mainContentVC?.beginActiveTerminalCopyMode()
    }
}

private extension MainWindowController {
    static let commandsMenuIdentifier = NSUserInterfaceItemIdentifier(
        "SopranoCommandsMenu"
    )

    struct ProjectEntry {
        let name: String
        let path: String
    }

    func buildWindowPaletteItems() -> [CommandItem] {
        agentManager.orderedWindows.enumerated().map { index, terminalWindow in
            let panes = agentManager.orderedPanes(in: terminalWindow.id)
            let activePaneTitle = agentManager.panes[terminalWindow.activePaneId]?
                .activeTab?.title ?? "No active pane"
            let paneCount = panes.count
            let currentPrefix = terminalWindow.id == agentManager.activeWindowId
                ? "Current · "
                : ""
            let description = "\(currentPrefix)\(paneCount) pane\(paneCount == 1 ? "" : "s") · Active: \(activePaneTitle)"
            let searchText = panes.flatMap { pane in
                pane.tabs.flatMap { tab -> [String] in
                    [
                        tab.title,
                        tab.cwd,
                        tab.url,
                        tab.agent.flatMap { AgentCatalog.profile(for: $0.profileId)?.name },
                    ].compactMap { $0 }
                }
            }.joined(separator: " ")
            let shortcut = index < 9
                ? commandShortcut(for: "select-window-\(index + 1)")
                : nil

            return CommandItem(
                id: "activate-\(terminalWindow.id)",
                icon: "macwindow",
                label: terminalWindow.title,
                description: description,
                shortcut: shortcut,
                searchText: searchText,
                action: { [weak self] in
                    self?.agentManager.activateWindow(terminalWindow.id)
                }
            )
        }
    }

    func buildProjectPaletteItems() -> [CommandItem] {
        var projectsByPath: [String: ProjectEntry] = [:]
        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey]

        for rootPath in settings.projectDirectories {
            let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            guard let childURLs = try? FileManager.default.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles]
            ) else { continue }

            for childURL in childURLs {
                guard let values = try? childURL.resourceValues(forKeys: resourceKeys),
                      values.isDirectory == true
                else { continue }

                let standardizedURL = childURL.standardizedFileURL
                projectsByPath[standardizedURL.path] = ProjectEntry(
                    name: standardizedURL.lastPathComponent,
                    path: standardizedURL.path
                )
            }
        }

        let projectItems = projectsByPath.values.sorted { lhs, rhs in
            let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameOrder == .orderedSame {
                return lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
            }
            return nameOrder == .orderedAscending
        }.map { project in
            CommandItem(
                id: "open-project-\(project.path)",
                icon: "folder",
                label: project.name,
                description: project.path,
                shortcut: nil,
                action: { [weak self] in
                    guard let self else { return }
                    _ = self.agentManager.spawnTerminal(cwd: project.path)
                }
            )
        }

        let chooseDirectoryItem = CommandItem(
            id: "choose-project-directory",
            icon: "folder.badge.plus",
            label: "Choose Directory…",
            description: "Open a terminal in any directory",
            shortcut: nil,
            action: { [weak self] in
                DispatchQueue.main.async {
                    self?.chooseProjectDirectory()
                }
            }
        )
        return projectItems + [chooseDirectoryItem]
    }

    func chooseProjectDirectory() {
        guard let window else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Open"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let path = panel.url?.path else { return }
            _ = self?.agentManager.spawnTerminal(cwd: path)
        }
    }

    func installCommandsMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }

        if let existingItem = mainMenu.items.first(where: {
            $0.identifier == Self.commandsMenuIdentifier
        }) {
            mainMenu.removeItem(existingItem)
        }

        let commandsItem = NSMenuItem(title: "Commands", action: nil, keyEquivalent: "")
        commandsItem.identifier = Self.commandsMenuIdentifier

        let commandsMenu = NSMenu(title: "Commands")
        let windowItem = makeCommandsMenuItem(
            title: "Find Window…",
            action: #selector(findWindowMenuItemSelected),
            bindingId: "find-window"
        )
        commandsMenu.addItem(windowItem)

        let paletteItem = makeCommandsMenuItem(
            title: "Command Palette…",
            action: #selector(commandPaletteMenuItemSelected),
            bindingId: "command-palette"
        )
        commandsMenu.addItem(paletteItem)

        let projectItem = makeCommandsMenuItem(
            title: "Open Project…",
            action: #selector(openProjectMenuItemSelected),
            bindingId: "open-project"
        )
        commandsMenu.addItem(projectItem)

        let dashboardItem = makeCommandsMenuItem(
            title: "Agent Dashboard",
            action: #selector(openDashboardMenuItemSelected),
            bindingId: "agent-dashboard"
        )
        commandsMenu.addItem(dashboardItem)

        commandsMenu.addItem(.separator())
        let settingsFileItem = NSMenuItem(
            title: "Open settings.json",
            action: #selector(openSettingsFileMenuItemSelected),
            keyEquivalent: ""
        )
        settingsFileItem.target = self
        commandsMenu.addItem(settingsFileItem)

        commandsItem.submenu = commandsMenu
        mainMenu.addItem(commandsItem)
    }

    /// A Commands-menu item whose key equivalent comes from the live keybinding
    /// configuration.
    ///
    /// These actions are dispatched by AppKit through the menu rather
    /// than by the event monitor, so a hardcoded key equivalent here would
    /// quietly outrank `settings.json`: the rebound chord would do nothing and
    /// the original would keep firing. Prefix chords and disabled actions get
    /// no key equivalent — the menu cannot express the former, and the latter
    /// is the point.
    private func makeCommandsMenuItem(
        title: String,
        action: Selector,
        bindingId: String
    ) -> NSMenuItem {
        let binding = ConfigStore.shared.keybindings.bindings.first { $0.id == bindingId }
        var key = ""
        var modifiers: NSEvent.ModifierFlags = []
        if let binding, binding.mode == .direct, binding.key.count == 1 {
            key = binding.key
            if binding.meta == true { modifiers.insert(.command) }
            if binding.ctrl == true { modifiers.insert(.control) }
            if binding.shift == true { modifiers.insert(.shift) }
        }

        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }

    @objc func commandPaletteMenuItemSelected() {
        keybindingOpenCommandPalette()
    }

    @objc func findWindowMenuItemSelected() {
        keybindingFindWindow()
    }

    @objc func openProjectMenuItemSelected() {
        keybindingOpenProjectSearch()
    }

    @objc func openSettingsFileMenuItemSelected() {
        ConfigStore.shared.openInEditor()
    }

    @objc func openDashboardMenuItemSelected() {
        keybindingOpenAgentDashboard()
    }

    func openSettings() {
        // The settings screen edits settings.json; the store's observer feeds
        // the result back here, so there is nothing to save on this side.
        mainContentVC?.showSettings(
            settings: ConfigStore.shared.settings,
            keybindingConfig: ConfigStore.shared.keybindings
        )
    }

    func reloadKeybindingManager() {
        keybindingManager?.apply(config: ConfigStore.shared.keybindings)
    }
}
