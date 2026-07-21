import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?
    private var agentNotificationManager: AgentNotificationManager?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installApplicationIcon()
        installApplicationMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        GhosttyAppManager.shared.initialize()

        let settings = AppSettings.load()
        let themeManager = ThemeManager(themeId: settings.themeId)
        let agentManager = AgentManager()
        let agentNotificationManager = AgentNotificationManager(agentManager: agentManager)
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
        self.agentNotificationManager = agentNotificationManager
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        mainWindowController?.saveWorkspaceIfNeeded()
    }

    private func installApplicationIcon() {
        MainActor.assumeIsolated {
            let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
                ?? Bundle.module.url(forResource: "AppIcon", withExtension: "icns")
            guard let iconURL, let icon = NSImage(contentsOf: iconURL) else { return }
            NSApp.applicationIconImage = icon
        }
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

            NSApp.mainMenu = mainMenu
        }
    }
}
