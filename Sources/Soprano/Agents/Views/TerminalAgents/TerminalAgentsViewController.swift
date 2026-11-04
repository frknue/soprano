import AppKit

/// The Terminal Agents board: Soprano's Agent Dashboard over the agents in Soprano's terminal
/// panes, covering the chat column and the right panel while
/// `WorkspaceState.isTerminalAgentsVisible`. It keeps the dashboard's list, detail and reply
/// field (replies type into the agent's terminal); Esc or the close button hides the board, Open
/// (↵, double-click, the toolbar's Open) shows the agent's pane in Soprano's terminal window.
///
/// The dashboard is built when the board opens and dropped when it closes, so its timers,
/// transcript reading and key handling never run behind the chat.
@MainActor
final class TerminalAgentsViewController: NSViewController {
    let state: WorkspaceState
    let source: TerminalAgentsSource?
    private(set) var dashboard: AgentDashboardViewController?

    init(state: WorkspaceState, source: TerminalAgentsSource?) {
        self.state = state
        self.source = source
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        view = WorkspaceRootView(frame: NSRect(x: 0, y: 0, width: Metrics.mainMinWidth, height: 600))
        // Hidden until the board opens, so the first show builds the dashboard.
        view.isHidden = true
        ThemeCenter.shared.addObserver(self) { [weak self] theme in
            self?.dashboard?.apply(theme: theme)
        }
    }

    var hasFocus: Bool {
        guard let responder = view.window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: view)
    }

    /// The dashboard's agent list takes the keyboard (J/K, ↵, Tab to reply).
    func takeFocus() {
        guard let dashboard else { return }
        view.window?.makeFirstResponder(dashboard.view)
    }

    /// The board became visible: builds the dashboard and applies a pending selection.
    func didOpen() {
        guard dashboard == nil, let source else { return }
        let dashboard = source.makeDashboard(themeManager: ThemeCenter.shared.manager)
        dashboard.onDismiss = { [weak self] in
            self?.state.setTerminalAgentsVisible(false)
        }
        dashboard.onAgentSelected = { [weak self] paneId, tabId in
            self?.source?.openInTerminal(TerminalTarget(paneId: paneId, tabId: tabId))
        }
        addChild(dashboard)
        let content = dashboard.view
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        self.dashboard = dashboard
    }

    /// Selects the agent a sidebar row asked for, once.
    func applyPendingSelection() {
        guard let dashboard, let entryID = state.takeTerminalAgentSelection() else { return }
        view.layoutSubtreeIfNeeded()
        dashboard.selectEntry(entryID, scrollIntoView: true)
    }

    /// The board was hidden: drops the dashboard.
    func didClose() {
        guard let dashboard else { return }
        dashboard.view.removeFromSuperview()
        dashboard.removeFromParent()
        self.dashboard = nil
    }
}
