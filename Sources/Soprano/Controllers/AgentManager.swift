import Foundation

struct TerminalTarget: Hashable, Sendable {
    let paneId: String
    let tabId: String
}

struct AgentReadinessGeneration: Equatable, Sendable {
    let target: TerminalTarget
    fileprivate let value: Int
}

enum TerminalLifecycleAction: Equatable {
    case stop(TerminalTarget)
    case restart(TerminalTarget)

    var target: TerminalTarget {
        switch self {
        case .stop(let target), .restart(let target):
            return target
        }
    }
}

/// Central controller for pane/tab/agent lifecycle and tiling layout.
/// This is the Swift equivalent of useAgentManager.ts.
final class AgentManager: @unchecked Sendable {
    private(set) var panes: [String: PaneState] = [:]
    private(set) var windows: [String: WorkspaceWindowState] = [:]
    private(set) var activeWindowId: String = ""
    private(set) var activePaneId: String {
        get { windows[activeWindowId]?.activePaneId ?? "" }
        set { windows[activeWindowId]?.activePaneId = newValue }
    }
    private(set) var layout: SplitNode? {
        get { windows[activeWindowId]?.layout }
        set { windows[activeWindowId]?.layout = newValue }
    }
    /// Pane rendered full-size instead of the split tree (nil = normal).
    /// Transient view state — never persisted in sessions.
    private(set) var maximizedPaneId: String?
    private var nextId: Int = 2

    /// Multi-observer notification. Views register closures to receive updates.
    private var observers: [String: () -> Void] = [:]
    /// Exact-target terminal lifecycle work, separate from ordinary model updates.
    private var terminalLifecycleObservers: [String: (TerminalLifecycleAction) -> Void] = [:]
    /// Monotonic tokens prevent an older surface's readiness fallback from
    /// completing a restarted or same-ID replacement agent.
    private var nextAgentReadinessGeneration: Int = 0
    private var activeAgentReadinessGenerations: [TerminalTarget: Int] = [:]

    /// Tracks whether the layout topology changed (vs just focus/status change).
    private(set) var layoutGeneration: Int = 0
    /// Advances after a workspace has been successfully restored so views can
    /// discard cached terminal surfaces even when restored IDs collide.
    private(set) var workspaceRestoreGeneration: Int = 0
    private var ghosttyCloseObserver: NSObjectProtocol?

    static let maxPanes = 20
    private static let paneShortcutKeys = Array("bdefgimnopqrstuvwxyz")

    // MARK: - Initialization

    init() {
        let windowId = "window-1"
        let paneId = "pane-1"
        let tabId = "tab-2"
        let tab = PaneTab(id: tabId, type: .terminal, title: "Terminal 1")
        let pane = PaneState(id: paneId, tabs: [tab])
        panes[paneId] = pane
        windows[windowId] = WorkspaceWindowState(
            id: windowId,
            title: Self.suggestedWindowTitle(for: tab),
            layout: .leaf(paneId),
            activePaneId: paneId
        )
        activeWindowId = windowId

        ghosttyCloseObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyCloseSurface,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let paneId = notification.userInfo?["paneId"] as? String,
                  let tabId = notification.userInfo?["tabId"] as? String
            else { return }

            self.handleTerminalClose(target: TerminalTarget(paneId: paneId, tabId: tabId))
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

    private func nextWindowId() -> String {
        nextId += 1
        return "window-\(nextId)"
    }

    // MARK: - Windows

    @discardableResult
    func createWindow(cwd: String? = nil) -> String? {
        guard panes.count < Self.maxPanes else { return nil }
        let windowId = nextWindowId()
        let paneId = nextPaneId()
        let tabId = nextTabId()
        let title = cwd?.split(separator: "/").last.map(String.init) ?? "Terminal"
        let tab = PaneTab(id: tabId, type: .terminal, title: title, cwd: cwd)
        panes[paneId] = PaneState(id: paneId, tabs: [tab])
        let windowTitle = uniqueAutomaticWindowTitle(Self.suggestedWindowTitle(for: tab))
        windows[windowId] = WorkspaceWindowState(
            id: windowId,
            title: windowTitle,
            layout: .leaf(paneId),
            activePaneId: paneId
        )
        activeWindowId = windowId
        maximizedPaneId = nil
        notifyChange(layoutChanged: true)
        return windowId
    }

    func activateWindow(_ windowId: String) {
        guard windows[windowId] != nil, activeWindowId != windowId else { return }
        activeWindowId = windowId
        maximizedPaneId = nil
        notifyChange(layoutChanged: true)
    }

    func activatePreviousWindow() {
        activateWindow(offset: -1)
    }

    func activateNextWindow() {
        activateWindow(offset: 1)
    }

    func activateWindow(number: Int) {
        let orderedWindows = sortedWindows()
        guard number >= 1, number <= orderedWindows.count else { return }
        activateWindow(orderedWindows[number - 1].id)
    }

    func closeWindow(_ windowId: String) {
        guard let terminalWindow = windows[windowId] else { return }
        for paneId in terminalWindow.paneIds {
            cancelAgentReadinessGenerations(in: paneId)
            panes.removeValue(forKey: paneId)
        }
        windows.removeValue(forKey: windowId)

        if windows.isEmpty {
            _ = createWindow()
            return
        }

        if activeWindowId == windowId {
            activeWindowId = sortedWindows().first?.id ?? ""
        }
        maximizedPaneId = nil
        notifyChange(layoutChanged: true)
    }

    func window(containingPane paneId: String) -> WorkspaceWindowState? {
        windows.values.first { $0.paneIds.contains(paneId) }
    }

    func renameWindow(_ windowId: String, to title: String) {
        guard let terminalWindow = windows[windowId] else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, terminalWindow.title != trimmed else { return }
        terminalWindow.title = trimmed
        terminalWindow.isTitleCustom = true
        notifyChange()
    }

    func resetWindowTitle(_ windowId: String) {
        guard let terminalWindow = windows[windowId],
              let firstPaneId = terminalWindow.layout?.firstLeaf,
              let tab = panes[firstPaneId]?.tabs.first
        else { return }
        terminalWindow.title = uniqueAutomaticWindowTitle(
            Self.suggestedWindowTitle(for: tab),
            excluding: windowId
        )
        terminalWindow.isTitleCustom = false
        notifyChange()
    }

    // MARK: - Pane Spawning

    @discardableResult
    func spawnAgent(_ profileId: String, cwd: String? = nil) -> String? {
        guard panes.count < Self.maxPanes else { return nil }
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
        return insertPane(pane) ? paneId : nil
    }

    @discardableResult
    func spawnTerminal(cwd: String? = nil) -> String? {
        spawnAgent("terminal", cwd: cwd)
    }

    // MARK: - Pane Splitting

    @discardableResult
    func splitPane(direction: SplitDirection, paneId: String) -> String? {
        guard let sourcePane = panes[paneId],
              let sourceTab = sourcePane.activeTab,
              let terminalWindow = window(containingPane: paneId),
              panes.count < Self.maxPanes
        else { return nil }
        activeWindowId = terminalWindow.id
        terminalWindow.activePaneId = paneId
        exitMaximize()

        let newPaneId = nextPaneId()
        let newTabId = nextTabId()
        let newTab: PaneTab

        if sourceTab.type == .agent, let agent = sourceTab.agent {
            let newAgent = AgentInstance(id: newTabId, profileId: agent.profileId)
            newTab = PaneTab(
                id: newTabId,
                type: .agent,
                title: sourceTab.title,
                agent: newAgent,
                cwd: sourceTab.cwd
            )
        } else {
            newTab = PaneTab(
                id: newTabId,
                type: .terminal,
                title: sourceTab.title,
                cwd: sourceTab.cwd
            )
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
        guard panes[paneId] != nil,
              let terminalWindow = window(containingPane: paneId)
        else { return }
        exitMaximize()
        cancelAgentReadinessGenerations(in: paneId)
        panes.removeValue(forKey: paneId)

        if let currentLayout = terminalWindow.layout {
            terminalWindow.layout = currentLayout.removing(paneId)
        }

        guard terminalWindow.layout != nil else {
            closeWindow(terminalWindow.id)
            return
        }

        if terminalWindow.activePaneId == paneId,
           let firstPaneId = terminalWindow.layout?.firstLeaf
        {
            terminalWindow.activePaneId = firstPaneId
        }

        notifyChange(layoutChanged: true)
    }

    // MARK: - Navigation

    func focusPane(_ paneId: String) {
        guard panes[paneId] != nil,
              let terminalWindow = window(containingPane: paneId)
        else { return }
        if activeWindowId == terminalWindow.id, activePaneId == paneId {
            guard clearAttentionWithoutNotification(paneId: paneId) else { return }
            notifyChange()
            return
        }
        exitMaximize()
        let windowChanged = activeWindowId != terminalWindow.id
        activeWindowId = terminalWindow.id
        terminalWindow.activePaneId = paneId
        _ = clearAttentionWithoutNotification(paneId: paneId)
        notifyChange(layoutChanged: windowChanged)
    }

    func orderedPanes(in windowId: String) -> [PaneState] {
        guard let layout = windows[windowId]?.layout else { return [] }
        return layout.orderedLeafIds.compactMap { panes[$0] }
    }

    var paneShortcutAssignments: [(key: String, paneId: String)] {
        let orderedPaneIds = orderedWindows.flatMap { terminalWindow in
            orderedPanes(in: terminalWindow.id).map(\.id)
        }
        return zip(Self.paneShortcutKeys, orderedPaneIds).map {
            (key: String($0.0), paneId: $0.1)
        }
    }

    @discardableResult
    func focusPane(shortcutKey: String) -> Bool {
        guard let assignment = paneShortcutAssignments.first(where: {
            $0.key == shortcutKey.lowercased()
        }) else {
            return false
        }
        focusPane(assignment.paneId)
        return true
    }

    func navigateToPane(direction: NavigationDirection) {
        guard let currentLayout = layout else { return }
        exitMaximize()

        if let target = currentLayout.adjacentPane(from: activePaneId, direction: direction) {
            activePaneId = target
        } else if let target = currentLayout.wrappingPane(from: activePaneId, direction: direction) {
            activePaneId = target
        }

        notifyChange()
    }

    // MARK: - Resizing

    func setSplitPercentage(at path: [SplitBranchSide], to percentage: Double) {
        guard let currentLayout = layout else { return }
        let updatedLayout = currentLayout.settingSplitPercentage(at: path, to: percentage)
        guard updatedLayout != currentLayout else { return }

        layout = updatedLayout
        notifyChange()
    }

    func resizePane(direction: NavigationDirection, tickPercent: Double = 5) {
        guard let currentLayout = layout,
              let path = currentLayout.pathTo(activePaneId)
        else { return }
        exitMaximize()

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
        exitMaximize()
        layout = newLayout
        if let newLayout, newLayout.pathTo(activePaneId) == nil {
            activePaneId = newLayout.firstLeaf ?? activePaneId
        }
        notifyChange(layoutChanged: true)
    }

    // MARK: - Maximize

    func toggleMaximize() {
        if maximizedPaneId != nil {
            maximizedPaneId = nil
            notifyChange(layoutChanged: true)
            return
        }
        guard (windows[activeWindowId]?.paneIds.count ?? 0) > 1,
              panes[activePaneId] != nil
        else { return }
        maximizedPaneId = activePaneId
        notifyChange(layoutChanged: true)
    }

    /// Restore the full layout before a topology-affecting operation so
    /// nothing operates blind on hidden panes. Notifies immediately —
    /// callers notify again after their own mutation, which is harmless.
    private func exitMaximize() {
        guard maximizedPaneId != nil else { return }
        maximizedPaneId = nil
        notifyChange(layoutChanged: true)
    }

    // MARK: - Agent Lifecycle

    func restartAgent(paneId: String) {
        guard let tabId = panes[paneId]?.activeTab?.id else { return }
        restartAgent(target: TerminalTarget(paneId: paneId, tabId: tabId))
    }

    func restartAgent(target: TerminalTarget) {
        guard let agent = agentTab(for: target)?.agent else { return }

        cancelAgentReadinessGeneration(for: target)
        agent.status = .starting
        agent.needsAttention = false
        agent.exitCode = nil
        agent.startedAt = Date()
        agent.restartCount += 1
        notifyTerminalLifecycle(.restart(target))
        notifyChange()
    }

    func stopAgent(paneId: String) {
        guard let tabId = panes[paneId]?.activeTab?.id else { return }
        stopAgent(target: TerminalTarget(paneId: paneId, tabId: tabId))
    }

    func stopAgent(target: TerminalTarget) {
        cancelAgentReadinessGeneration(for: target)
        guard let agent = agentTab(for: target)?.agent,
              agent.status != .stopped
        else { return }

        agent.status = .stopped
        agent.needsAttention = false
        notifyTerminalLifecycle(.stop(target))
        notifyChange()
    }

    /// Routes Ghostty's close request by the surface's immutable pane/tab IDs.
    /// Kept internal so exact-target behavior can be tested without posting a
    /// process-global notification.
    func handleTerminalClose(target: TerminalTarget) {
        guard let pane = panes[target.paneId],
              let tab = pane.tabs.first(where: { $0.id == target.tabId })
        else { return }

        if tab.type == .agent {
            guard let agent = tab.agent, agent.status != .stopped else { return }
            cancelAgentReadinessGeneration(for: target)
            agent.status = .stopped
            agent.needsAttention = false
            notifyChange()
        } else {
            removeTabFromPane(target.paneId, tabId: target.tabId)
        }
    }

    /// Reconciles an agent process that exited on its own. Agent tabs remain
    /// restartable in the stopped state, while agents launched inside a regular
    /// terminal are detached because the terminal has returned to its shell.
    func agentProcessDidExit(target: TerminalTarget, exitCode: Int32? = nil) {
        guard let pane = panes[target.paneId],
              let tabIndex = pane.tabs.firstIndex(where: { $0.id == target.tabId }),
              let agent = pane.tabs[tabIndex].agent
        else { return }

        cancelAgentReadinessGeneration(for: target)
        if pane.tabs[tabIndex].type == .terminal {
            agent.status = .stopped
            agent.needsAttention = false
            agent.exitCode = exitCode
            if pane.tabs[tabIndex].title == agentName(for: agent.profileId) {
                pane.tabs[tabIndex].title = pane.tabs[tabIndex].cwd?
                    .split(separator: "/").last.map(String.init) ?? "Terminal"
            }
            pane.tabs[tabIndex].agent = nil
        } else {
            guard agent.status != .stopped || agent.exitCode != exitCode else { return }
            agent.status = .stopped
            agent.needsAttention = false
            agent.exitCode = exitCode
        }
        notifyChange()
    }

    private func agentTab(for target: TerminalTarget) -> PaneTab? {
        guard let tab = panes[target.paneId]?.tabs.first(where: { $0.id == target.tabId }),
              tab.type == .agent
        else { return nil }
        return tab
    }

    func updateAgentStatus(paneId: String, status: AgentStatus) {
        guard let tabId = panes[paneId]?.activeTab?.id else { return }
        updateAgentStatus(paneId: paneId, tabId: tabId, status: status)
    }

    func updateAgentStatus(
        paneId: String,
        tabId: String,
        status: AgentStatus,
        needsAttention: Bool? = nil
    ) {
        guard let agent = agent(paneId: paneId, tabId: tabId),
              agent.status != .stopped
        else { return }

        let attentionChanged = needsAttention.map { agent.needsAttention != $0 } ?? false
        guard agent.status != status || attentionChanged else { return }

        agent.status = status
        if let needsAttention {
            agent.needsAttention = needsAttention
        }
        if status == .starting {
            agent.startedAt = Date()
        } else {
            cancelAgentReadinessGeneration(
                for: TerminalTarget(paneId: paneId, tabId: tabId)
            )
        }
        notifyChange()
    }

    func agent(paneId: String, tabId: String) -> AgentInstance? {
        panes[paneId]?.tabs.first(where: { $0.id == tabId })?.agent
    }

    /// Associate an agent started manually inside a regular terminal tab with
    /// Soprano's lifecycle model. The tab remains a terminal for persistence,
    /// so restoring the workspace does not unexpectedly relaunch the agent.
    @discardableResult
    func attachAgentIfNeeded(paneId: String, tabId: String, profileId: String) -> AgentInstance? {
        guard profileId != "terminal",
              let profile = DefaultAgents.profile(for: profileId),
              let pane = panes[paneId],
              let tabIndex = pane.tabs.firstIndex(where: { $0.id == tabId })
        else { return nil }

        if let existingAgent = pane.tabs[tabIndex].agent {
            guard existingAgent.profileId != profile.id,
                  pane.tabs[tabIndex].type == .terminal
            else { return existingAgent }
        }

        let agent = AgentInstance(id: tabId, profileId: profile.id)
        pane.tabs[tabIndex].agent = agent
        if pane.tabs[tabIndex].title == "Terminal" {
            pane.tabs[tabIndex].title = profile.name
        }
        notifyChange()
        return agent
    }

    func focusTab(paneId: String, tabId: String) {
        guard let pane = panes[paneId],
              let index = pane.tabs.firstIndex(where: { $0.id == tabId })
        else { return }
        switchTab(paneId, index: index)
        clearAttention(paneId: paneId, tabId: tabId)
    }

    func clearAttention(paneId: String, tabId: String) {
        guard let agent = agent(paneId: paneId, tabId: tabId), agent.needsAttention else { return }
        agent.needsAttention = false
        notifyChange()
    }

    func beginAgentReadinessGeneration(
        for target: TerminalTarget
    ) -> AgentReadinessGeneration? {
        guard let agent = agent(paneId: target.paneId, tabId: target.tabId),
              agent.profileId == "codex",
              agent.status == .starting
        else {
            return nil
        }

        nextAgentReadinessGeneration += 1
        activeAgentReadinessGenerations[target] = nextAgentReadinessGeneration
        return AgentReadinessGeneration(
            target: target,
            value: nextAgentReadinessGeneration
        )
    }

    func markAgentReadyIfStarting(generation: AgentReadinessGeneration) {
        guard activeAgentReadinessGenerations[generation.target] == generation.value else {
            return
        }
        activeAgentReadinessGenerations.removeValue(forKey: generation.target)

        let target = generation.target
        guard let agent = agent(paneId: target.paneId, tabId: target.tabId),
              agent.status == .starting
        else {
            return
        }
        agent.status = .idle
        notifyChange()
    }

    private func clearAttentionWithoutNotification(paneId: String) -> Bool {
        guard let tab = panes[paneId]?.activeTab,
              let agent = tab.agent,
              agent.needsAttention
        else { return false }
        agent.needsAttention = false
        return true
    }

    // MARK: - Tabs

    @discardableResult
    func addTabToPane(_ paneId: String, type: PaneType, profileId: String? = nil) -> String? {
        guard let pane = panes[paneId],
              let terminalWindow = window(containingPane: paneId),
              pane.tabs.count < PaneState.maxTabsPerPane
        else { return nil }

        let tabId = nextTabId()
        let tab: PaneTab

        if type == .agent, let profileId, let profile = DefaultAgents.profile(for: profileId) {
            let agent = AgentInstance(id: tabId, profileId: profile.id)
            tab = PaneTab(id: tabId, type: .agent, title: profile.name, agent: agent)
        } else {
            tab = PaneTab(id: tabId, type: .terminal, title: "Terminal")
        }

        pane.tabs.append(tab)
        pane.activeTabIndex = pane.tabs.count - 1
        let windowChanged = activeWindowId != terminalWindow.id
        activeWindowId = terminalWindow.id
        terminalWindow.activePaneId = paneId
        notifyChange(layoutChanged: windowChanged)
        return tabId
    }

    func removeTabFromPane(_ paneId: String, tabId: String) {
        guard let pane = panes[paneId] else { return }
        guard let index = pane.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        cancelAgentReadinessGeneration(
            for: TerminalTarget(paneId: paneId, tabId: tabId)
        )

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
        guard let pane = panes[paneId],
              let terminalWindow = window(containingPane: paneId),
              !pane.tabs.isEmpty
        else { return }
        let clamped = min(max(0, index), pane.tabs.count - 1)
        pane.activeTabIndex = clamped
        let windowChanged = activeWindowId != terminalWindow.id
        activeWindowId = terminalWindow.id
        terminalWindow.activePaneId = paneId
        _ = clearAttentionWithoutNotification(paneId: paneId)
        notifyChange(layoutChanged: windowChanged)
    }

    func nextTab(_ paneId: String) {
        guard let pane = panes[paneId],
              let terminalWindow = window(containingPane: paneId),
              !pane.tabs.isEmpty
        else { return }
        pane.activeTabIndex = (pane.clampedActiveIndex() + 1) % pane.tabs.count
        let windowChanged = activeWindowId != terminalWindow.id
        activeWindowId = terminalWindow.id
        terminalWindow.activePaneId = paneId
        _ = clearAttentionWithoutNotification(paneId: paneId)
        notifyChange(layoutChanged: windowChanged)
    }

    func prevTab(_ paneId: String) {
        guard let pane = panes[paneId],
              let terminalWindow = window(containingPane: paneId),
              !pane.tabs.isEmpty
        else { return }
        let current = pane.clampedActiveIndex()
        pane.activeTabIndex = (current - 1 + pane.tabs.count) % pane.tabs.count
        let windowChanged = activeWindowId != terminalWindow.id
        activeWindowId = terminalWindow.id
        terminalWindow.activePaneId = paneId
        _ = clearAttentionWithoutNotification(paneId: paneId)
        notifyChange(layoutChanged: windowChanged)
    }

    func renameTab(_ paneId: String, tabId: String, to title: String) {
        guard let pane = panes[paneId],
              let index = pane.tabs.firstIndex(where: { $0.id == tabId })
        else { return }

        let sanitized = title
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty, pane.tabs[index].title != sanitized else { return }

        pane.tabs[index].title = sanitized
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
        let savedPanes = panes.values
            .map { pane in
                WorkspaceSession.SavedPane(
                    id: pane.id,
                    activeTabIndex: pane.activeTabIndex,
                    tabs: pane.tabs.map { tab in
                        WorkspaceSession.SavedTab(
                            id: tab.id,
                            type: tab.type,
                            profileId: tab.agent?.profileId,
                            cwd: tab.cwd,
                            title: tab.title
                        )
                    }
                )
            }
        let savedWindows = orderedWindows.map { terminalWindow in
            WorkspaceSession.SavedWindow(
                id: terminalWindow.id,
                title: terminalWindow.title,
                isTitleCustom: terminalWindow.isTitleCustom,
                layout: terminalWindow.layout,
                activePaneId: terminalWindow.activePaneId
            )
        }

        return WorkspaceSession(
            id: "last",
            name: "Last Session",
            savedAt: Date(),
            layout: layout,
            panes: savedPanes,
            activePaneId: activePaneId,
            windows: savedWindows,
            activeWindowId: activeWindowId
        )
    }

    func restoreWorkspace(_ session: WorkspaceSession) {
        guard !session.panes.isEmpty else { return }

        var newPanes: [String: PaneState] = [:]
        var maxId = 1

        for savedPane in session.panes {
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
                    cwd: savedTab.cwd,
                    title: savedTab.title
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

        var newWindows: [String: WorkspaceWindowState] = [:]
        if let savedWindows = session.windows, !savedWindows.isEmpty {
            for savedWindow in savedWindows {
                if let num = parseIdNumber(savedWindow.id) {
                    maxId = max(maxId, num)
                }
                guard let restoredLayout = savedWindow.layout,
                      let firstPaneId = restoredLayout.leafIds.first(where: { newPanes[$0] != nil })
                else { continue }
                let activePaneId = restoredLayout.leafIds.contains(savedWindow.activePaneId)
                    ? savedWindow.activePaneId
                    : firstPaneId
                let wasGeneratedPlaceholder = Self.isGeneratedWindowTitle(savedWindow.title)
                let isTitleCustom = savedWindow.isTitleCustom ?? !wasGeneratedPlaceholder
                let baseTitle = wasGeneratedPlaceholder
                    ? Self.suggestedWindowTitle(for: newPanes[firstPaneId]?.tabs.first)
                    : savedWindow.title
                let restoredTitle = isTitleCustom
                    ? savedWindow.title
                    : Self.uniqueAutomaticWindowTitle(
                        baseTitle,
                        existingTitles: newWindows.values.map(\.title)
                    )
                newWindows[savedWindow.id] = WorkspaceWindowState(
                    id: savedWindow.id,
                    title: restoredTitle,
                    isTitleCustom: isTitleCustom,
                    layout: restoredLayout,
                    activePaneId: activePaneId
                )
            }
        } else {
            let windowId = "window-1"
            let effectiveLayout = session.layout ?? .leaf(session.panes[0].id)
            let firstPaneId = effectiveLayout.leafIds.first(where: { newPanes[$0] != nil })
                ?? session.panes[0].id
            let restoredActivePaneId = effectiveLayout.leafIds.contains(session.activePaneId)
                ? session.activePaneId
                : firstPaneId
            let title = Self.suggestedWindowTitle(for: newPanes[firstPaneId]?.tabs.first)
            newWindows[windowId] = WorkspaceWindowState(
                id: windowId,
                title: title,
                layout: effectiveLayout,
                activePaneId: restoredActivePaneId
            )
        }

        guard !newWindows.isEmpty else { return }

        activeAgentReadinessGenerations.removeAll()
        let referencedPaneIds = Set(newWindows.values.flatMap(\.paneIds))
        panes = newPanes.filter { referencedPaneIds.contains($0.key) }
        windows = newWindows
        activeWindowId = session.activeWindowId.flatMap { newWindows[$0] }?.id
            ?? sortedWindows().first?.id
            ?? ""
        nextId = maxId

        maximizedPaneId = nil
        workspaceRestoreGeneration += 1
        notifyChange(layoutChanged: true)
    }

    var paneCount: Int { panes.count }
    var windowCount: Int { windows.count }
    var orderedWindows: [WorkspaceWindowState] { sortedWindows() }
    var readyAgentCount: Int {
        panes.values.flatMap(\.tabs).filter { $0.agent?.status == .idle }.count
    }
    var attentionCount: Int {
        panes.values.flatMap(\.tabs).filter { $0.agent?.needsAttention == true }.count
    }

    // MARK: - Private Helpers

    private func insertPane(_ pane: PaneState) -> Bool {
        guard panes.count < Self.maxPanes else { return false }
        exitMaximize()

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
        return true
    }

    private func cancelAgentReadinessGeneration(for target: TerminalTarget) {
        activeAgentReadinessGenerations.removeValue(forKey: target)
    }

    private func cancelAgentReadinessGenerations(in paneId: String) {
        activeAgentReadinessGenerations = activeAgentReadinessGenerations.filter {
            $0.key.paneId != paneId
        }
    }

    // MARK: - Observer Management

    func addObserver(id: String, handler: @escaping () -> Void) {
        observers[id] = handler
    }

    func removeObserver(id: String) {
        observers.removeValue(forKey: id)
    }

    func addTerminalLifecycleObserver(
        id: String,
        handler: @escaping (TerminalLifecycleAction) -> Void
    ) {
        terminalLifecycleObservers[id] = handler
    }

    func removeTerminalLifecycleObserver(id: String) {
        terminalLifecycleObservers.removeValue(forKey: id)
    }

    private func notifyTerminalLifecycle(_ action: TerminalLifecycleAction) {
        for (_, handler) in terminalLifecycleObservers {
            handler(action)
        }
    }

    private func notifyChange(layoutChanged: Bool = false) {
        if layoutChanged { layoutGeneration += 1 }
        for (_, handler) in observers {
            handler()
        }
    }

    private func parseIdNumber(_ id: String) -> Int? {
        let pattern = /^(?:window|pane|tab)-(\d+)$/
        guard let match = id.firstMatch(of: pattern),
              let num = Int(match.1)
        else { return nil }
        return num
    }

    private func sortedWindows() -> [WorkspaceWindowState] {
        windows.values.sorted { lhs, rhs in
            (parseIdNumber(lhs.id) ?? Int.max) < (parseIdNumber(rhs.id) ?? Int.max)
        }
    }

    private func activateWindow(offset: Int) {
        let orderedWindows = sortedWindows()
        guard orderedWindows.count > 1,
              let currentIndex = orderedWindows.firstIndex(where: { $0.id == activeWindowId })
        else { return }

        let nextIndex = (currentIndex + offset + orderedWindows.count) % orderedWindows.count
        activateWindow(orderedWindows[nextIndex].id)
    }

    private func uniqueAutomaticWindowTitle(
        _ baseTitle: String,
        excluding windowId: String? = nil
    ) -> String {
        let existingTitles = windows.values
            .filter { $0.id != windowId }
            .map(\.title)
        return Self.uniqueAutomaticWindowTitle(
            baseTitle,
            existingTitles: existingTitles
        )
    }

    private static func uniqueAutomaticWindowTitle(
        _ baseTitle: String,
        existingTitles: [String]
    ) -> String {
        let normalizedTitles = Set(existingTitles.map { $0.lowercased() })
        guard normalizedTitles.contains(baseTitle.lowercased()) else { return baseTitle }

        var suffix = 2
        while normalizedTitles.contains("\(baseTitle) (\(suffix))".lowercased()) {
            suffix += 1
        }
        return "\(baseTitle) (\(suffix))"
    }

    private static func suggestedWindowTitle(for tab: PaneTab?) -> String {
        let profile = tab?.agent.flatMap { DefaultAgents.profile(for: $0.profileId) }
        let cwd = tab?.cwd
            ?? profile?.cwd
            ?? FileManager.default.currentDirectoryPath

        if let directoryName = projectDirectoryName(for: cwd) {
            return directoryName
        }
        if let profile {
            return profile.name
        }
        return tab?.type == .agent ? "Agent" : "Terminal"
    }

    private static func projectDirectoryName(for path: String) -> String? {
        let fileManager = FileManager.default
        let original = URL(
            fileURLWithPath: (path as NSString).expandingTildeInPath,
            isDirectory: true
        ).standardizedFileURL
        var directory = original

        while true {
            let gitPath = directory.appendingPathComponent(".git").path
            if fileManager.fileExists(atPath: gitPath), !directory.lastPathComponent.isEmpty {
                return directory.lastPathComponent
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }

        let fallback = original.lastPathComponent
        return fallback.isEmpty || fallback == "/" ? nil : fallback
    }

    private static func isGeneratedWindowTitle(_ title: String) -> Bool {
        title.wholeMatch(of: /^Window \d+$/) != nil
    }

    private func agentName(for profileId: String) -> String {
        DefaultAgents.profile(for: profileId)?.name ?? "Agent"
    }

    private func createPaneTab(
        id: String,
        type: PaneType,
        profileId: String? = nil,
        cwd: String? = nil,
        title: String? = nil
    ) -> PaneTab {
        if type == .agent, let profileId, let profile = DefaultAgents.profile(for: profileId) {
            let agent = AgentInstance(id: id, profileId: profile.id)
            let dirName = cwd?.split(separator: "/").last.map(String.init)
            let restoredTitle = title ?? dirName.map { "\(profile.name): \($0)" } ?? profile.name
            return PaneTab(
                id: id,
                type: .agent,
                title: restoredTitle,
                agent: agent,
                cwd: cwd
            )
        }

        let restoredTitle = title
            ?? cwd?.split(separator: "/").last.map(String.init)
            ?? "Terminal"
        return PaneTab(id: id, type: .terminal, title: restoredTitle, cwd: cwd)
    }
}
