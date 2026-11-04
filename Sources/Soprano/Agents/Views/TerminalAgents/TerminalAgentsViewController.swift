import AppKit

/// The Terminal Agents board: one agent from Soprano's terminal panes, covering the chat column
/// and the right panel while `WorkspaceState.isTerminalAgentsVisible`. The sidebar's Terminals
/// section is the list; the board is Soprano's Agent Dashboard without its own list and header:
/// the agent's transcript or live terminal text and the reply field (replies type into the
/// agent's terminal). Esc hides the board, Open (↵, the toolbar's Open) shows the agent's pane in
/// Soprano's terminal window.
///
/// The dashboard is built when the board opens and dropped when it closes, so its timers,
/// transcript reading and key handling never run behind the chat.
@MainActor
final class TerminalAgentsViewController: NSViewController {
    let state: WorkspaceState
    let source: TerminalAgentsSource?
    private(set) var dashboard: AgentDashboardViewController?
    /// Brings the sidebar (the list of agents) back while it is hidden, in the empty title-bar
    /// band above the agent, like the statistics board's.
    let sidebarToggle = GhostIconButton(symbol: Icon.sidebarLeft, symbolSize: 14, toolTip: "Toggle sidebar (⌘E)")

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
        sidebarToggle.onClick = { [weak self] in
            (self?.view.window?.windowController as? AgentsWindowController)?.perform("view.toggleSidebar")
        }
        sidebarToggle.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sidebarToggle)
        NSLayoutConstraint.activate([
            sidebarToggle.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Metrics.windowControlsInset + 1),
            sidebarToggle.centerYAnchor.constraint(equalTo: view.topAnchor, constant: Metrics.topbarHeight / 2),
        ])
        ThemeCenter.shared.addObserver(self) { [weak self] theme in
            self?.dashboard?.apply(theme: theme)
        }
        state.addObserver(self) { [weak self] change in
            if change == .panels { self?.updateSidebarState() }
        }
        updateSidebarState()
    }

    var hasFocus: Bool {
        guard let responder = view.window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: view)
    }

    /// The dashboard takes the keyboard (↵ opens the pane, Tab replies, Esc closes).
    func takeFocus() {
        guard let dashboard else { return }
        view.window?.makeFirstResponder(dashboard.view)
    }

    /// The board became visible: builds the dashboard and applies a pending selection.
    func didOpen() {
        guard dashboard == nil, let source else { return }
        let dashboard = source.makeDashboard(themeManager: ThemeCenter.shared.manager)
        dashboard.showsAgentList = false
        dashboard.onDismiss = { [weak self] in
            self?.state.setTerminalAgentsVisible(false)
        }
        dashboard.onAgentSelected = { [weak self] paneId, tabId in
            self?.source?.openInTerminal(TerminalTarget(paneId: paneId, tabId: tabId))
        }
        // The sidebar marks the agent shown here, whoever picked it.
        dashboard.onSelectionChange = { [weak self] entryID in
            self?.state.setShownTerminalAgent(entryID)
        }
        addChild(dashboard)
        let content = dashboard.view
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content, positioned: .below, relativeTo: sidebarToggle)
        let top = content.topAnchor.constraint(equalTo: view.topAnchor)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            top,
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        contentTop = top
        self.dashboard = dashboard
        updateSidebarState()
    }

    private var contentTop: NSLayoutConstraint?

    /// With the sidebar hidden, the window's traffic lights sit over the board's corner: the
    /// agent starts below the title bar, and the band offers the sidebar toggle.
    private func updateSidebarState() {
        contentTop?.constant = state.isSidebarVisible ? 0 : Metrics.topbarHeight
        sidebarToggle.isHidden = state.isSidebarVisible
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
        state.setShownTerminalAgent(nil)
    }
}
