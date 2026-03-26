import AppKit

final class MainWindowController: NSWindowController {
    let agentManager: AgentManager
    let sessionManager: SessionManager
    let themeManager: ThemeManager
    var settings: AppSettings

    private var mainContentVC: MainContentViewController?
    private var keybindingManager: KeybindingManager?
    private var commandPalette: CommandPalettePanel?

    init(
        agentManager: AgentManager,
        sessionManager: SessionManager,
        themeManager: ThemeManager,
        settings: AppSettings
    ) {
        self.agentManager = agentManager
        self.sessionManager = sessionManager
        self.themeManager = themeManager
        self.settings = settings

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Soprano"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 600, height: 400)
        window.isReleasedWhenClosed = false

        // Restore saved frame or center on screen
        if !window.setFrameUsingName("SopranoMainWindow") {
            window.center()
        }
        window.setFrameAutosaveName("SopranoMainWindow")

        super.init(window: window)

        let contentVC = MainContentViewController(
            agentManager: agentManager,
            sessionManager: sessionManager,
            themeManager: themeManager,
            onSettingsRequested: { [weak self] in
                self?.openSettings()
            }
        )
        window.contentViewController = contentVC
        self.mainContentVC = contentVC

        let keybindingManager = KeybindingManager(agentManager: agentManager)
        keybindingManager.delegate = self
        keybindingManager.stateChangeHandler = { [weak contentVC] state in
            contentVC?.setKeybindingMode(state)
        }
        self.keybindingManager = keybindingManager

        themeManager.onThemeChanged = { [weak self] _ in
            self?.applyTheme()
            self?.mainContentVC?.refreshTheme()
        }

        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func saveWorkspaceIfNeeded() {
        guard settings.restoreLastSession else { return }
        let session = agentManager.snapshotWorkspace()
        WorkspaceSession.saveLast(session)
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
                description: "Open a new browser pane",
                shortcut: commandShortcut(for: "new-browser"),
                action: { [weak self] in
                    guard let self else { return }
                    _ = self.agentManager.spawnBrowser()
                }
            ),
            CommandItem(
                id: "split-horizontal",
                icon: "rectangle.split.2x1",
                label: "Split Horizontal",
                description: "Split the active pane horizontally",
                shortcut: commandShortcut(for: "split-horizontal"),
                action: { [weak self] in
                    guard let self else { return }
                    _ = self.agentManager.splitPane(direction: .horizontal, paneId: self.agentManager.activePaneId)
                }
            ),
            CommandItem(
                id: "split-vertical",
                icon: "rectangle.split.1x2",
                label: "Split Vertical",
                description: "Split the active pane vertically",
                shortcut: commandShortcut(for: "split-vertical"),
                action: { [weak self] in
                    guard let self else { return }
                    _ = self.agentManager.splitPane(direction: .vertical, paneId: self.agentManager.activePaneId)
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
                label: "Save Session",
                description: "Save the current workspace session",
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

extension MainWindowController: KeybindingDelegate {
    func keybindingToggleSidebar() {
        mainContentVC?.toggleSidebar()
    }

    func keybindingSaveSession() {
        saveWorkspaceIfNeeded()
    }

    func keybindingOpenSettings() {
        openSettings()
    }

    func keybindingToggleMaximize() {}

    func keybindingOpenCommandPalette() {
        guard let window else { return }

        let panel = palettePanel()
        let commands = buildCommandPaletteItems()
        panel.show(relativeTo: window, commands: commands)
    }

    func keybindingOpenProjectSearch() {}

    func keybindingZoom(delta _: Int) {}

    func keybindingZoomReset() {}
}

private extension MainWindowController {
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
        keybindingManager = manager
    }
}
