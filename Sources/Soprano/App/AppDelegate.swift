import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installApplicationMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        GhosttyAppManager.shared.initialize()

        let settings = AppSettings.load()
        let themeManager = ThemeManager(themeId: settings.themeId)
        let agentManager = AgentManager()
        let sessionManager = SessionManager(agentManager: agentManager)
        let gitBranchMonitor = GitBranchMonitor()

        if settings.restoreLastSession, let workspace = WorkspaceSession.loadLast() {
            agentManager.restoreWorkspace(workspace)
        }

        let controller = MainWindowController(
            agentManager: agentManager,
            sessionManager: sessionManager,
            themeManager: themeManager,
            gitBranchMonitor: gitBranchMonitor,
            settings: settings
        )
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        mainWindowController = controller
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        mainWindowController?.saveWorkspaceIfNeeded()
    }

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
            NSApp.mainMenu = mainMenu
        }
    }
}
