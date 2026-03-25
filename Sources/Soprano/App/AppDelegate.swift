import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        GhosttyAppManager.shared.initialize()

        let settings = AppSettings.load()
        let themeManager = ThemeManager(themeId: settings.themeId)
        let agentManager = AgentManager()
        let sessionManager = SessionManager(agentManager: agentManager)

        if settings.restoreLastSession, let workspace = WorkspaceSession.loadLast() {
            agentManager.restoreWorkspace(workspace)
        }

        let controller = MainWindowController(
            agentManager: agentManager,
            sessionManager: sessionManager,
            themeManager: themeManager,
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
}
