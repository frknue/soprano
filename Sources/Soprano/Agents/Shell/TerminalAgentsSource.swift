import AppKit

/// The agents running in Soprano's terminal panes (Codex, Claude Code, OpenCode, omp TUIs), as
/// the Agents window sees them: the sidebar's Terminals section and the Terminal Agents board.
/// Soprano's `AppDelegate` builds the live one over its `AgentManager` and terminal views; the
/// snapshot harness and tests use `DemoFixtures.terminalAgents()`. Nothing in the Agents subtree
/// reaches Soprano's controllers except through this.
@MainActor
final class TerminalAgentsSource {
    private let readEntries: () -> [AgentDashboardEntry]
    private let buildDashboard: (ThemeManager) -> AgentDashboardViewController
    private let focusInTerminal: (TerminalTarget) -> Void
    private let observers = ObserverList<Void>()

    /// - Parameters:
    ///   - entries: every pane agent, most urgent first (`AgentDashboardSnapshot` order).
    ///   - makeDashboard: Soprano's Agent Dashboard over the same agents, colored by the theme.
    ///   - openInTerminal: shows the agent's pane in Soprano's terminal window and brings it forward.
    init(
        entries: @escaping () -> [AgentDashboardEntry],
        makeDashboard: @escaping (ThemeManager) -> AgentDashboardViewController,
        openInTerminal: @escaping (TerminalTarget) -> Void
    ) {
        readEntries = entries
        buildDashboard = makeDashboard
        focusInTerminal = openInTerminal
    }

    var entries: [AgentDashboardEntry] { readEntries() }

    /// A fresh dashboard; the caller embeds it and sets its callbacks.
    func makeDashboard(themeManager: ThemeManager) -> AgentDashboardViewController {
        buildDashboard(themeManager)
    }

    func openInTerminal(_ target: TerminalTarget) {
        focusInTerminal(target)
    }

    /// `handler` runs after the agents changed (status, title, folder, added, gone) until `owner`
    /// is deallocated.
    func addObserver(_ owner: AnyObject, _ handler: @escaping @MainActor () -> Void) {
        observers.add(owner) { _ in handler() }
    }

    /// The agents changed; the backing model calls this.
    func notifyChange() {
        observers.notify(())
    }
}
