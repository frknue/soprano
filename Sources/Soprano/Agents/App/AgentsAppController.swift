import AppKit
import SopranoAgentsCore

/// Soprano Agents inside Soprano: the thread window with its engine, menu bar
/// and notifications.
///
/// Nothing starts until the window first opens; then the engine runs until
/// Soprano quits, so closing the window leaves its threads working. It never
/// starts while the standalone Soprano Agents app runs: both keep their threads
/// in the same folder, and two engines would overwrite each other's thread files.
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
    private let standaloneIsRunning: @MainActor () -> Bool
    private let reportStandaloneRunning: @MainActor () -> Void
    /// Brings Soprano's terminal window forward (Show Terminals).
    let showTerminals: () -> Void
    /// The agents in Soprano's terminal panes, shown in the sidebar and the Terminal Agents board.
    let terminalAgents: TerminalAgentsSource?

    init(
        menuBar: MenuBarSwitcher,
        defaults: UserDefaults = .standard,
        standaloneIsRunning: @escaping @MainActor () -> Bool = AgentsAppController.isStandaloneRunning,
        reportStandaloneRunning: @escaping @MainActor () -> Void = AgentsAppController.alertStandaloneRunning,
        showTerminals: @escaping () -> Void,
        terminalAgents: TerminalAgentsSource? = nil
    ) {
        self.menuBar = menuBar
        self.defaults = defaults
        self.standaloneIsRunning = standaloneIsRunning
        self.reportStandaloneRunning = reportStandaloneRunning
        self.showTerminals = showTerminals
        self.terminalAgents = terminalAgents
    }

    /// The standalone app that shares this build's data folder (`AppPaths`):
    /// installed Soprano pairs with `Soprano Agents.app`, every other build with
    /// its development app.
    nonisolated static func standaloneBundleIdentifier(for bundleIdentifier: String?) -> String {
        bundleIdentifier == AppPaths.installedBundleIdentifier ? "com.soprano.agents" : "com.soprano.agents.dev"
    }

    static func isStandaloneRunning() -> Bool {
        let identifier = standaloneBundleIdentifier(for: Bundle.main.bundleIdentifier)
        return !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty
    }

    static func alertStandaloneRunning() {
        let alert = NSAlert()
        alert.messageText = "Quit Soprano Agents first"
        alert.informativeText = "The Soprano Agents app is still running, and it keeps its threads in the same folder. Quit it, then open Soprano Agents here again (⇧⌘A)."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Reopens the window behind `window` when it was open at the last quit. While
    /// the standalone app runs it stays closed and is still restored next launch.
    func restoreIfNeeded(behind window: NSWindow?) {
        guard defaults.bool(forKey: Self.windowOpenKey), let controller = ensureWindow() else { return }
        controller.prepareToShow()
        if let window {
            controller.window?.order(.below, relativeTo: window.windowNumber)
        } else {
            controller.showWindow(nil)
        }
    }

    /// Shows the window, starting the engine on first use, and makes it key.
    func showWindow() {
        guard let controller = ensureWindow() else {
            reportStandaloneRunning()
            return
        }
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
    /// window, or one hidden with Soprano, counts as open. A window never built
    /// this launch keeps the last answer.
    func recordWindowState() {
        guard let windowController else { return }
        defaults.set(windowController.isOpen, forKey: Self.windowOpenKey)
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

    /// The window, built with its engine on first use; nil while the standalone app
    /// runs, before anything opens the shared thread store.
    private func ensureWindow() -> AgentsWindowController? {
        if let windowController { return windowController }
        guard !standaloneIsRunning() else { return nil }

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

        let controller = AgentsWindowController(engine: engine, terminalAgents: terminalAgents)
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
