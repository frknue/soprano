import AppKit
import SopranoAgentsCore

/// Soprano Agents inside Soprano: the thread window with its engine, menu bar
/// and notifications.
///
/// Nothing starts until the window first opens; then the engine runs until
/// Soprano quits, so closing the window leaves its threads working.
@MainActor
final class AgentsAppController {
    /// Whether the window was open when Soprano last quit; it reopens on the next launch.
    static let windowOpenKey = "soprano-agents-window-open"

    private(set) var windowController: AgentsWindowController?
    private(set) var engine: AgentEngine?
    private var menuController: MainMenuController?
    private var notifier: ThreadNotifier?
    private let menuBar: MenuBarSwitcher
    private let defaults: UserDefaults
    /// Brings Soprano's terminal window forward (Show Terminals).
    let showTerminals: () -> Void

    init(menuBar: MenuBarSwitcher, defaults: UserDefaults = .standard, showTerminals: @escaping () -> Void) {
        self.menuBar = menuBar
        self.defaults = defaults
        self.showTerminals = showTerminals
    }

    /// Reopens the window behind `window` when it was open at the last quit.
    func restoreIfNeeded(behind window: NSWindow?) {
        guard defaults.bool(forKey: Self.windowOpenKey) else { return }
        let controller = ensureWindow()
        controller.prepareToShow()
        if let window {
            controller.window?.order(.below, relativeTo: window.windowNumber)
        } else {
            controller.showWindow(nil)
        }
    }

    /// Shows the window, starting the engine on first use, and makes it key.
    func showWindow() {
        let controller = ensureWindow()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A thread's notification was clicked: show the window on that thread.
    func openThread(_ threadID: String) {
        showWindow()
        windowController?.state.select(.thread(threadID))
    }

    /// True while the engine may have omp sessions to stop before quitting.
    var needsShutdown: Bool { engine != nil }

    /// Remembers whether the window is open for the next launch; a minimized
    /// window, or one hidden with Soprano, counts as open.
    func recordWindowState() {
        defaults.set(windowController?.isOpen == true, forKey: Self.windowOpenKey)
    }

    /// Stops every omp session.
    func shutdown() async {
        await engine?.shutdown()
    }

    /// Whether the user is looking at the Agents window: Soprano is active and the
    /// key window is that window or a panel hanging off it. The terminal window in
    /// front does not count, so threads still notify while you work there.
    static func isWatching(agentsWindow: NSWindow?, keyWindow: NSWindow?, isActive: Bool) -> Bool {
        guard isActive, let agentsWindow, let keyWindow else { return false }
        return MenuBarSwitcher.rootWindow(of: keyWindow) === agentsWindow
    }

    private func ensureWindow() -> AgentsWindowController {
        if let windowController { return windowController }

        let settings = SettingsCenter.shared
        settings.importLegacySettings(defaults: defaults)
        settings.start()
        PaletteCenter.shared.apply(setting: ThemeCenter.followSoprano)
        ThemeCenter.shared.followSystemAppearance()
        AllCommands.registerAll()
        settings.reloadKeymap()

        let menu = MainMenuController(
            windowController: { [weak self] in self?.windowController },
            install: { [weak menuBar] bar in menuBar?.setAgentsBar(bar) }
        )
        menu.install()
        menuController = menu

        // Soprano started `AccountsController` at launch, before any omp process.
        AccountsCenter.source = AccountsController.shared

        let engine = EngineFactory.live(settings: settings.settings.engineSettings)
        self.engine = engine

        settings.addObserver(self) { [weak self] in
            let current = SettingsCenter.shared.settings
            PaletteCenter.shared.apply(setting: ThemeCenter.followSoprano)
            EngineFactory.executablePaths.update(current.engineSettings)
            self?.engine?.settings = current.engineSettings
            self?.menuController?.install()
        }

        let controller = AgentsWindowController(engine: engine)
        controller.showTerminals = showTerminals
        windowController = controller

        notifier = ThreadNotifier(
            engine: engine,
            isWatching: { [weak controller] in
                Self.isWatching(agentsWindow: controller?.window, keyWindow: NSApp.keyWindow, isActive: NSApp.isActive)
            },
            poster: UserNotificationPoster.make()
        )

        Task { await engine.refreshProviders() }
        return controller
    }
}
