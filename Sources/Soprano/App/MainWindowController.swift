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

        let keybindingManager = KeybindingManager(agentManager: agentManager)
        keybindingManager.delegate = self
        keybindingManager.stateChangeHandler = { [weak contentVC] state in
            contentVC?.setKeybindingMode(state)
        }
        keybindingManager.controlKeyStateChangeHandler = { [weak contentVC] isHeld in
            contentVC?.setControlKeyHeld(isHeld)
        }
        contentVC.setControlKeyHeld(keybindingManager.isControlKeyHeld)
        self.keybindingManager = keybindingManager

        themeManager.onThemeChanged = { [weak self] _ in
            self?.applyTheme()
            self?.mainContentVC?.refreshTheme()
        }

        applyTheme()
        installCommandsMenu()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
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

    private func buildCommandPaletteItems() -> [CommandItem] {
        [
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
                id: "launch-codex",
                icon: "command.square",
                label: "Launch Codex",
                description: "Launch Codex agent",
                shortcut: commandShortcut(for: "launch-codex"),
                action: { [weak self] in
                    guard let self else { return }
                    _ = self.agentManager.spawnAgent("codex")
                }
            ),
            CommandItem(
                id: "launch-claude-code",
                icon: "sparkles",
                label: "Launch Claude Code",
                description: "Launch Claude Code agent",
                shortcut: commandShortcut(for: "launch-claude-code"),
                action: { [weak self] in
                    guard let self else { return }
                    _ = self.agentManager.spawnAgent("claude-code")
                }
            ),
            CommandItem(
                id: "launch-opencode",
                icon: "chevron.left.forwardslash.chevron.right",
                label: "Launch OpenCode",
                description: "Launch OpenCode agent",
                shortcut: commandShortcut(for: "launch-opencode"),
                action: { [weak self] in
                    guard let self else { return }
                    _ = self.agentManager.spawnAgent("opencode")
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
                id: "toggle-sidebar",
                icon: "sidebar.leading",
                label: "Toggle Sidebar",
                description: "Show or hide the sidebar",
                shortcut: commandShortcut(for: "toggle-sidebar"),
                action: { [weak self] in
                    self?.keybindingToggleSidebar()
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

    func keybindingOpenCommandPalette() {
        guard let window else { return }

        let panel = palettePanel()
        let commands = buildCommandPaletteItems()
        panel.show(relativeTo: window, commands: commands)
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
        let paletteItem = NSMenuItem(
            title: "Command Palette…",
            action: #selector(commandPaletteMenuItemSelected),
            keyEquivalent: "p"
        )
        paletteItem.keyEquivalentModifierMask = [.command]
        paletteItem.target = self
        commandsMenu.addItem(paletteItem)

        let projectItem = NSMenuItem(
            title: "Open Project…",
            action: #selector(openProjectMenuItemSelected),
            keyEquivalent: "p"
        )
        projectItem.keyEquivalentModifierMask = [.command, .shift]
        projectItem.target = self
        commandsMenu.addItem(projectItem)

        commandsItem.submenu = commandsMenu
        mainMenu.addItem(commandsItem)
    }

    @objc func commandPaletteMenuItemSelected() {
        keybindingOpenCommandPalette()
    }

    @objc func openProjectMenuItemSelected() {
        keybindingOpenProjectSearch()
    }

    func openSettings() {
        let config = keybindingManager?.config ?? DefaultKeybindings.load()
        mainContentVC?.showSettings(
            settings: settings,
            keybindingConfig: config,
            onSettingsChanged: { [weak self] updatedSettings in
                guard let self else { return }
                self.settings = updatedSettings
                self.settings.save()
                self.applyTheme()
            },
            onKeybindingConfigChanged: { [weak self] updatedConfig in
                guard let self else { return }
                DefaultKeybindings.save(updatedConfig)
                self.reloadKeybindingManager()
            }
        )
    }

    func reloadKeybindingManager() {
        let manager = KeybindingManager(agentManager: agentManager)
        manager.delegate = self
        manager.stateChangeHandler = { [weak mainContentVC] state in
            mainContentVC?.setKeybindingMode(state)
        }
        manager.controlKeyStateChangeHandler = { [weak mainContentVC] isHeld in
            mainContentVC?.setControlKeyHeld(isHeld)
        }
        mainContentVC?.setControlKeyHeld(manager.isControlKeyHeld)
        keybindingManager = manager
    }
}
