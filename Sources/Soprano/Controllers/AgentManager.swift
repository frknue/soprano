import Foundation

/// Central controller for pane/tab/agent lifecycle and tiling layout.
/// This is the Swift equivalent of useAgentManager.ts.
final class AgentManager: @unchecked Sendable {
    private(set) var panes: [String: PaneState] = [:]
    private(set) var activePaneId: String = ""
    private(set) var layout: SplitNode?
    private var nextId: Int = 2

    /// Multi-observer notification. Views register closures to receive updates.
    private var observers: [String: () -> Void] = [:]

    /// Tracks whether the layout topology changed (vs just focus/status change).
    private(set) var layoutGeneration: Int = 0
    private var ghosttyCloseObserver: NSObjectProtocol?

    static let maxPanes = 20

    // MARK: - Initialization

    init() {
        let paneId = "pane-1"
        let tabId = "tab-2"
        let tab = PaneTab(id: tabId, type: .terminal, title: "Terminal 1")
        let pane = PaneState(id: paneId, tabs: [tab])
        panes[paneId] = pane
        activePaneId = paneId
        layout = .leaf(paneId)

        ghosttyCloseObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyCloseSurface,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let paneId = notification.userInfo?["paneId"] as? String,
                  let pane = self.panes[paneId],
                  let tab = pane.activeTab,
                  tab.type == .agent,
                  let agent = tab.agent
            else { return }

            agent.status = .stopped
            self.notifyChange()
        }
    }

    deinit {
        if let ghosttyCloseObserver {
            NotificationCenter.default.removeObserver(ghosttyCloseObserver)
        }
    }

    // MARK: - ID Generation

    private func nextPaneId() -> String {
        nextId += 1
        return "pane-\(nextId)"
    }

    private func nextTabId() -> String {
        nextId += 1
        return "tab-\(nextId)"
    }

    // MARK: - Pane Spawning

    @discardableResult
    func spawnAgent(_ profileId: String, cwd: String? = nil) -> String {
        let paneId = nextPaneId()
        let tabId = nextTabId()
        let profile = DefaultAgents.profile(for: profileId)

        let tab: PaneTab
        if let profile, profile.id != "terminal" {
            let dirName = cwd?.split(separator: "/").last.map(String.init)
            let title = dirName.map { "\(profile.name): \($0)" } ?? profile.name
            let agent = AgentInstance(id: tabId, profileId: profile.id)
            tab = PaneTab(id: tabId, type: .agent, title: title, agent: agent, cwd: cwd)
        } else {
            let title = cwd?.split(separator: "/").last.map(String.init) ?? "Terminal"
            tab = PaneTab(id: tabId, type: .terminal, title: title, cwd: cwd)
        }

        let pane = PaneState(id: paneId, tabs: [tab])
        insertPane(pane)
        return paneId
    }

    @discardableResult
    func spawnTerminal(cwd: String? = nil) -> String {
        spawnAgent("terminal", cwd: cwd)
    }

    @discardableResult
    func spawnBrowser() -> String {
        let paneId = nextPaneId()
        let tabId = nextTabId()
        let tab = PaneTab(id: tabId, type: .browser, title: "Browser")
        let pane = PaneState(id: paneId, tabs: [tab])
        insertPane(pane)
        return paneId
    }

    // MARK: - Pane Splitting

    @discardableResult
    func splitPane(direction: SplitDirection, paneId: String) -> String? {
        guard let sourcePane = panes[paneId],
              let sourceTab = sourcePane.activeTab
        else { return nil }

        let newPaneId = nextPaneId()
        let newTabId = nextTabId()
        let newTab: PaneTab

        if sourceTab.type == .agent, let agent = sourceTab.agent {
            let newAgent = AgentInstance(id: newTabId, profileId: agent.profileId)
            newTab = PaneTab(id: newTabId, type: .agent, title: sourceTab.title, agent: newAgent)
        } else {
            newTab = PaneTab(id: newTabId, type: sourceTab.type, title: sourceTab.title)
        }

        let newPane = PaneState(id: newPaneId, tabs: [newTab])
        panes[newPaneId] = newPane

        if let currentLayout = layout,
           let updatedLayout = currentLayout.insertingSplit(
               at: paneId, newId: newPaneId, direction: direction
           )
        {
            layout = updatedLayout
        } else {
            layout = .split(SplitNode.SplitBranch(
                direction: direction,
                first: layout ?? .leaf(paneId),
                second: .leaf(newPaneId)
            ))
        }

        activePaneId = newPaneId
        notifyChange(layoutChanged: true)
        return newPaneId
    }

    // MARK: - Pane Closing

    func closePane(_ paneId: String) {
        guard panes[paneId] != nil else { return }
        panes.removeValue(forKey: paneId)

        if let currentLayout = layout {
            layout = currentLayout.removing(paneId)
        }

        if panes.isEmpty || layout == nil {
            let fallbackId = nextPaneId()
            let tabId = nextTabId()
            let tab = PaneTab(id: tabId, type: .terminal, title: "Terminal")
            let pane = PaneState(id: fallbackId, tabs: [tab])
            panes = [fallbackId: pane]
            activePaneId = fallbackId
            layout = .leaf(fallbackId)
        } else if activePaneId == paneId {
            // Find adjacent or first leaf
            if let adj = layout?.adjacentPane(from: paneId, direction: .right)
                ?? layout?.adjacentPane(from: paneId, direction: .left)
                ?? layout?.adjacentPane(from: paneId, direction: .down)
                ?? layout?.adjacentPane(from: paneId, direction: .up)
                ?? layout?.firstLeaf
            {
                activePaneId = adj
            }
        }

        notifyChange(layoutChanged: true)
    }

    // MARK: - Navigation

    func focusPane(_ paneId: String) {
        guard panes[paneId] != nil, activePaneId != paneId else { return }
        activePaneId = paneId
        notifyChange()
    }

    func navigateToPane(direction: NavigationDirection) {
        guard let currentLayout = layout else { return }

        if let target = currentLayout.adjacentPane(from: activePaneId, direction: direction) {
            activePaneId = target
        } else {
            // Wrap around: go to the boundary leaf on the opposite side
            let opposite: NavigationDirection = switch direction {
            case .left: .left
            case .right: .right
            case .up: .up
            case .down: .down
            }
            if let boundary = currentLayout.adjacentPane(from: activePaneId, direction: opposite) {
                activePaneId = boundary
            }
        }

        notifyChange()
    }

    // MARK: - Resizing

    func resizePane(direction: NavigationDirection, tickPercent: Double = 5) {
        guard let currentLayout = layout,
              let path = currentLayout.pathTo(activePaneId)
        else { return }

        let axisDirection: SplitDirection = direction.isHorizontal ? .horizontal : .vertical
        let delta = (direction == .left || direction == .up) ? -tickPercent : tickPercent

        // Walk up the path to find a split with the matching axis
        for i in stride(from: path.count - 1, through: 0, by: -1) {
            let ancestorPath = Array(path.prefix(i))
            // Verify ancestor has matching direction
            var current = currentLayout
            var valid = false
            for side in ancestorPath {
                guard case .split(let branch) = current else { break }
                current = side == .first ? branch.first : branch.second
            }
            if case .split(let branch) = current, branch.direction == axisDirection {
                valid = true
            }
            guard valid else { continue }

            layout = currentLayout.adjustingSplit(at: ancestorPath, delta: delta)
            notifyChange()
            return
        }
    }

    // MARK: - Layout

    func setLayout(_ newLayout: SplitNode?) {
        layout = newLayout
        if let newLayout, newLayout.pathTo(activePaneId) == nil {
            activePaneId = newLayout.firstLeaf ?? activePaneId
        }
        notifyChange(layoutChanged: true)
    }

    // MARK: - Agent Lifecycle

    func restartAgent(paneId: String) {
        guard let pane = panes[paneId],
              let tab = pane.activeTab,
              tab.type == .agent,
              let agent = tab.agent
        else { return }

        agent.status = .starting
        agent.exitCode = nil
        agent.startedAt = Date()
        agent.restartCount += 1
        notifyChange()
    }

    func stopAgent(paneId: String) {
        guard let pane = panes[paneId],
              let tab = pane.activeTab,
              tab.type == .agent,
              let agent = tab.agent
        else { return }

        agent.status = .stopped
        notifyChange()
    }

    func updateAgentStatus(paneId: String, status: AgentStatus) {
        guard let pane = panes[paneId],
              let tab = pane.activeTab,
              tab.type == .agent,
              let agent = tab.agent,
              agent.status != .stopped,
              agent.status != status
        else { return }

        agent.status = status
        if status == .starting {
            agent.startedAt = Date()
        }
        notifyChange()
    }

    // MARK: - Tabs

    @discardableResult
    func addTabToPane(_ paneId: String, type: PaneType, profileId: String? = nil) -> String? {
        guard let pane = panes[paneId],
              pane.tabs.count < PaneState.maxTabsPerPane
        else { return nil }

        let tabId = nextTabId()
        let tab: PaneTab

        if type == .agent, let profileId, let profile = DefaultAgents.profile(for: profileId) {
            let agent = AgentInstance(id: tabId, profileId: profile.id)
            tab = PaneTab(id: tabId, type: .agent, title: profile.name, agent: agent)
        } else if type == .browser {
            tab = PaneTab(id: tabId, type: .browser, title: "Browser")
        } else {
            tab = PaneTab(id: tabId, type: .terminal, title: "Terminal")
        }

        pane.tabs.append(tab)
        pane.activeTabIndex = pane.tabs.count - 1
        activePaneId = paneId
        notifyChange()
        return tabId
    }

    func removeTabFromPane(_ paneId: String, tabId: String) {
        guard let pane = panes[paneId] else { return }
        guard let index = pane.tabs.firstIndex(where: { $0.id == tabId }) else { return }

        if pane.tabs.count == 1 {
            closePane(paneId)
            return
        }

        pane.tabs.remove(at: index)
        if index < pane.activeTabIndex {
            pane.activeTabIndex -= 1
        } else if index == pane.activeTabIndex {
            pane.activeTabIndex = max(0, pane.activeTabIndex - 1)
        }
        pane.activeTabIndex = pane.clampedActiveIndex()
        notifyChange()
    }

    func switchTab(_ paneId: String, index: Int) {
        guard let pane = panes[paneId], !pane.tabs.isEmpty else { return }
        let clamped = min(max(0, index), pane.tabs.count - 1)
        pane.activeTabIndex = clamped
        activePaneId = paneId
        notifyChange()
    }

    func nextTab(_ paneId: String) {
        guard let pane = panes[paneId], !pane.tabs.isEmpty else { return }
        pane.activeTabIndex = (pane.clampedActiveIndex() + 1) % pane.tabs.count
        activePaneId = paneId
        notifyChange()
    }

    func prevTab(_ paneId: String) {
        guard let pane = panes[paneId], !pane.tabs.isEmpty else { return }
        let current = pane.clampedActiveIndex()
        pane.activeTabIndex = (current - 1 + pane.tabs.count) % pane.tabs.count
        activePaneId = paneId
        notifyChange()
    }

    // MARK: - Agent Profile Lookup

    func agentProfile(for paneId: String) -> AgentProfile? {
        guard let pane = panes[paneId],
              let tab = pane.activeTab,
              tab.type == .agent,
              let agent = tab.agent
        else { return nil }

        return DefaultAgents.profile(for: agent.profileId)
    }

    // MARK: - Workspace Save/Restore

    func snapshotWorkspace() -> WorkspaceSession {
        let leafIds = layout?.leafIds ?? []
        let savedPanes = panes.values
            .filter { leafIds.contains($0.id) }
            .map { pane in
                WorkspaceSession.SavedPane(
                    id: pane.id,
                    activeTabIndex: pane.activeTabIndex,
                    tabs: pane.tabs.map { tab in
                        WorkspaceSession.SavedTab(
                            id: tab.id,
                            type: tab.type,
                            profileId: tab.agent?.profileId,
                            cwd: tab.cwd
                        )
                    }
                )
            }

        return WorkspaceSession(
            id: "last",
            name: "Last Session",
            savedAt: Date(),
            layout: layout,
            panes: savedPanes,
            activePaneId: activePaneId
        )
    }

    func restoreWorkspace(_ session: WorkspaceSession) {
        guard !session.panes.isEmpty else { return }

        var newPanes: [String: PaneState] = [:]
        var maxId = 1

        let effectiveLayout = session.layout ?? .leaf(session.panes[0].id)
        let layoutIds = effectiveLayout.leafIds

        for savedPane in session.panes {
            guard layoutIds.isEmpty || layoutIds.contains(savedPane.id) else { continue }

            if let num = parseIdNumber(savedPane.id) {
                maxId = max(maxId, num)
            }

            let tabs: [PaneTab] = savedPane.tabs.map { savedTab in
                if let num = parseIdNumber(savedTab.id) {
                    maxId = max(maxId, num)
                }
                return createPaneTab(
                    id: savedTab.id,
                    type: savedTab.type,
                    profileId: savedTab.profileId,
                    cwd: savedTab.cwd
                )
            }

            let finalTabs = tabs.isEmpty
                ? [PaneTab(id: "tab-\(maxId + 1)", type: .terminal, title: "Terminal")]
                : tabs
            if tabs.isEmpty { maxId += 1 }

            let pane = PaneState(
                id: savedPane.id,
                tabs: finalTabs,
                activeTabIndex: min(max(0, savedPane.activeTabIndex), finalTabs.count - 1)
            )
            newPanes[savedPane.id] = pane
        }

        nextId = maxId
        panes = newPanes
        layout = effectiveLayout

        if let first = effectiveLayout.firstLeaf, newPanes[first] != nil {
            activePaneId = first
        } else {
            activePaneId = session.panes[0].id
        }

        notifyChange(layoutChanged: true)
    }

    var paneCount: Int { panes.count }

    // MARK: - Private Helpers

    private func insertPane(_ pane: PaneState) {
        guard panes.count < Self.maxPanes else { return }

        panes[pane.id] = pane

        if layout == nil {
            layout = .leaf(pane.id)
            activePaneId = pane.id
        } else if let currentLayout = layout,
                  let updated = currentLayout.insertingSplit(
                      at: activePaneId, newId: pane.id, direction: .horizontal
                  )
        {
            layout = updated
            activePaneId = pane.id
        } else {
            layout = .split(SplitNode.SplitBranch(
                direction: .horizontal,
                first: layout!,
                second: .leaf(pane.id)
            ))
            activePaneId = pane.id
        }

        notifyChange(layoutChanged: true)
    }

    // MARK: - Observer Management

    func addObserver(id: String, handler: @escaping () -> Void) {
        observers[id] = handler
    }

    func removeObserver(id: String) {
        observers.removeValue(forKey: id)
    }

    private func notifyChange(layoutChanged: Bool = false) {
        if layoutChanged { layoutGeneration += 1 }
        for (_, handler) in observers {
            handler()
        }
    }

    private func parseIdNumber(_ id: String) -> Int? {
        let pattern = /^(?:pane|tab)-(\d+)$/
        guard let match = id.firstMatch(of: pattern),
              let num = Int(match.1)
        else { return nil }
        return num
    }

    private func createPaneTab(
        id: String,
        type: PaneType,
        profileId: String? = nil,
        cwd: String? = nil
    ) -> PaneTab {
        if type == .agent, let profileId, let profile = DefaultAgents.profile(for: profileId) {
            let agent = AgentInstance(id: id, profileId: profile.id)
            let dirName = cwd?.split(separator: "/").last.map(String.init)
            let title = dirName.map { "\(profile.name): \($0)" } ?? profile.name
            return PaneTab(id: id, type: .agent, title: title, agent: agent, cwd: cwd)
        }

        if type == .browser {
            return PaneTab(id: id, type: .browser, title: "Browser")
        }

        let title = cwd?.split(separator: "/").last.map(String.init) ?? "Terminal"
        return PaneTab(id: id, type: .terminal, title: title, cwd: cwd)
    }
}
