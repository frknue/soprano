import AppKit
import SopranoAgentsCore

/// Normal launch: settings → palette → commands → menus → engine → main window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var windowController: MainWindowController?
    private(set) var engine: AgentEngine?
    private var menuController: MainMenuController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        Self.installApplicationIcon()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = SettingsCenter.shared
        settings.start()
        PaletteCenter.shared.apply(setting: settings.settings.theme)
        PaletteCenter.shared.startFollowingSystemAppearance()

        AllCommands.registerAll()
        settings.reloadKeymap()

        let menu = MainMenuController(windowController: { [weak self] in self?.windowController })
        menu.install()
        menuController = menu

        let engine = EngineFactory.live(settings: settings.settings.engineSettings)
        self.engine = engine

        settings.addObserver(self) { [weak self] in
            let current = SettingsCenter.shared.settings
            PaletteCenter.shared.apply(setting: current.theme)
            EngineFactory.executablePaths.update(codex: current.codexPath, claude: current.claudePath)
            self?.engine?.settings = current.engineSettings
            self?.menuController?.install()
        }

        let controller = MainWindowController(engine: engine)
        windowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        Task { await engine.refreshProviders() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { windowController?.window?.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let engine else { return .terminateNow }
        Task { @MainActor in
            await engine.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    static func installApplicationIcon() {
        let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
            ?? AppResources.bundle.url(forResource: "AppIcon", withExtension: "icns")
        if let url, let image = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = image
        }
    }
}
