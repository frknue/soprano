import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?
    private var agentNotificationManager: AgentNotificationManager?
    private var browserAutomationController: BrowserAutomationController?
    private var markdownCommandController: MarkdownCommandController?
    private var automationController: AutomationController?
    private var menuBar: MenuBarSwitcher?
    private var agentsController: AgentsAppController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installApplicationIcon()
        installApplicationMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Load settings.json (creating it on first run) before anything reads
        // a setting, so the whole launch sees the user's configuration.
        let configStore = ConfigStore.shared
        configStore.start()
        // Before any pane starts: omp panes load the account overlay, codex
        // panes need the chosen CODEX_HOME.
        AccountsController.shared.start()

        let settings = configStore.settings
        let themeManager = ThemeManager(themeId: settings.themeId, appearance: settings.appearance)
        // NSApp.appearance follows the theme from here on, so alerts, menus
        // and panels match it, and `folio` re-resolves when macOS flips.
        themeManager.startDrivingApplicationAppearance()
        GhosttyAppManager.shared.initialize(theme: themeManager.currentTheme)
        let agentManager = AgentManager()
        // Unsaved editor changes are asked about before any tab showing them closes.
        agentManager.closeConfirmation = { targets in
            EditorDocumentStore.shared.confirmClosing(targets)
        }
        let agentNotificationManager = AgentNotificationManager(agentManager: agentManager)
        agentNotificationManager.requestAuthorizationIfNeeded()
        let sessionManager = SessionManager(agentManager: agentManager)
        let gitBranchMonitor = GitBranchMonitor()

        if settings.restoreLastSession, let workspace = WorkspaceSession.loadLast() {
            agentManager.restoreWorkspace(workspace)
        }

        guard let menuBar else { preconditionFailure("The menu bar is installed in applicationWillFinishLaunching") }
        let controller = MainWindowController(
            agentManager: agentManager,
            sessionManager: sessionManager,
            themeManager: themeManager,
            gitBranchMonitor: gitBranchMonitor,
            settings: settings,
            mainMenu: menuBar.sopranoBar.menu
        )
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        mainWindowController = controller
        self.agentNotificationManager = agentNotificationManager

        let showTerminals: @MainActor @Sendable () -> Void = { [weak controller] in
            controller?.showWindow(nil)
            controller?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        let terminalAgents = TerminalAgentsSource(
            agentManager: agentManager,
            makeDashboard: { [weak controller] theme in
                controller?.contentController?.makeAgentDashboard(themeManager: theme, title: "Terminal Agents")
                    ?? AgentDashboardViewController(agentManager: agentManager, themeManager: theme, title: "Terminal Agents")
            },
            openInTerminal: { [weak controller] target in
                controller?.contentController?.focusAgent(target)
                showTerminals()
            }
        )
        let agentsController = AgentsAppController(menuBar: menuBar, showTerminals: showTerminals, terminalAgents: terminalAgents)
        controller.openAgentsWindow = { [weak agentsController] in agentsController?.showWindow() }
        agentNotificationManager.showSopranoWindow = showTerminals
        agentNotificationManager.openAgentsThread = { [weak agentsController] threadID in
            agentsController?.openThread(threadID)
        }
        agentsController.restoreIfNeeded(behind: controller.window)
        self.agentsController = agentsController
        browserAutomationController = BrowserAutomationController(agentManager: agentManager)
        markdownCommandController = MarkdownCommandController(agentManager: agentManager)

        let automationController = AutomationController(
            store: AutomationStore(fileURL: AutomationStore.defaultFileURL()),
            agentManager: agentManager,
            environment: AutomationController.Environment(
                startTerminal: { [weak controller] target in
                    controller?.contentController?.startBackgroundTerminal(for: target) ?? false
                },
                submitPrompt: { [weak controller] prompt, target in
                    controller?.contentController?.submitAgentPrompt(prompt, to: target) ?? false
                },
                visibleText: { [weak controller] target in
                    controller?.contentController?.visibleTerminalText(for: target)
                },
                notify: { [weak agentNotificationManager] title, body, runId in
                    agentNotificationManager?.deliverAutomationNotification(title: title, body: body, runId: runId)
                }
            )
        )
        controller.install(automationController: automationController)
        automationController.start()
        self.automationController = automationController
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard EditorDocumentStore.shared.confirmClosingAll() else { return .terminateCancel }
        guard let agentsController else { return .terminateNow }
        agentsController.recordWindowState()
        guard agentsController.needsShutdown else { return .terminateNow }
        // Soprano Agents stops its omp sessions first, so none is cut off mid-write.
        Task { @MainActor in
            await agentsController.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        mainWindowController?.saveLastWorkspaceIfNeeded()
    }

    private func installApplicationIcon() {
        MainActor.assumeIsolated {
            let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
                ?? SopranoResources.bundle.url(forResource: "AppIcon", withExtension: "icns")
            guard let iconURL, let icon = NSImage(contentsOf: iconURL) else { return }
            NSApp.applicationIconImage = icon
        }
    }

    /// Soprano's menu bar, handed to `MenuBarSwitcher`, which swaps in the
    /// Agents window's own bar while that window is key.
    private func installApplicationMenu() {
        MainActor.assumeIsolated {
            let mainMenu = NSMenu()
            let applicationMenuItem = NSMenuItem(
                title: "Soprano",
                action: nil,
                keyEquivalent: ""
            )
            mainMenu.addItem(applicationMenuItem)

            let applicationMenu = NSMenu(title: "Soprano")
            let quitItem = NSMenuItem(
                title: "Quit Soprano",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
            quitItem.keyEquivalentModifierMask = [.command]
            quitItem.target = NSApp
            applicationMenu.addItem(quitItem)
            applicationMenuItem.submenu = applicationMenu

            let editMenuItem = NSMenuItem(
                title: "Edit",
                action: nil,
                keyEquivalent: ""
            )
            mainMenu.addItem(editMenuItem)

            let editMenu = NSMenu(title: "Edit")
            editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")

            let redoItem = editMenu.addItem(
                withTitle: "Redo",
                action: Selector(("redo:")),
                keyEquivalent: "z"
            )
            redoItem.keyEquivalentModifierMask = [.command, .shift]

            editMenu.addItem(.separator())
            editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
            editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
            editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
            editMenu.addItem(.separator())
            editMenu.addItem(
                withTitle: "Select All",
                action: #selector(NSText.selectAll(_:)),
                keyEquivalent: "a"
            )
            editMenuItem.submenu = editMenu

            let windowMenuItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
            mainMenu.addItem(windowMenuItem)
            let windowMenu = NSMenu(title: "Window")
            windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "")
            windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
            windowMenu.addItem(.separator())
            windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
            windowMenuItem.submenu = windowMenu

            let menuBar = MenuBarSwitcher(
                soprano: MenuBarSwitcher.Bar(menu: mainMenu, windowsMenu: windowMenu)
            ) { window in
                if window is AgentsWindow { return .agents }
                if window is MainWindow { return .soprano }
                return nil
            }
            menuBar.start()
            self.menuBar = menuBar
        }
    }
}
