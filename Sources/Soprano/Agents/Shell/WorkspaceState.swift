import AppKit
import SopranoAgentsCore

/// UI state of the window: what is selected and which panels are open. Views read it and observe
/// `Change`s; every region writes through its setters. Engine data lives in `AgentEngine`.
@MainActor
final class WorkspaceState {
    enum Change: Equatable {
        /// The selected thread, subagent or the draft changed.
        case selection
        case panels
        /// Sidebar project filter or search.
        case filter
        /// Someone handed the composer a message to take back ("Edit from here").
        case composerRestore
    }

    /// What the chat column shows.
    enum Selection: Equatable {
        /// A new, unsent thread ("draft hero" with the composer centered).
        case draft(projectID: String?)
        case thread(String)
        /// One of a thread's subagents: its runs in the timeline, messages go to it. The panels
        /// keep showing the thread's workspace.
        case subagent(threadID: String, subagentID: String)
    }

    /// One right-panel tab. Diff and Files exist at most once per workspace; a file tab per
    /// workspace-relative path; a terminal tab per terminal session id.
    enum RightPanelSurface: Hashable {
        case diff
        case files
        /// A workspace-relative path ("/"-separated) in the thread's working directory.
        case file(String)
        /// A `TerminalSessionInfo.id` owned by the right panel.
        case terminal(String)

        /// Tab title; terminal tabs take their session title from the terminal store instead.
        var title: String {
            switch self {
            case .diff: "Diff"
            case .files: "Files"
            case let .file(path): path.split(separator: "/").last.map(String.init) ?? path
            case .terminal: "Terminal"
            }
        }
    }

    /// The tabs of one workspace's right panel; `active` nil shows the "Open a surface" launcher.
    private struct RightPanelTabs {
        var surfaces: [RightPanelSurface] = [.diff]
        var active: RightPanelSurface? = .diff
    }

    /// What the diff surface compares.
    enum DiffScope: Equatable {
        /// The whole thread so far.
        case thread
        /// One turn by ordinal.
        case turn(Int)
        /// Uncommitted changes of the working directory.
        case uncommitted
    }

    private(set) var selection: Selection = .draft(projectID: nil)
    private(set) var isSidebarVisible = true
    private(set) var isThreadDetailsVisible = false
    private(set) var isTerminalVisible = false
    private(set) var isRightPanelVisible = false
    /// Right-panel tabs per `WorkspaceRef.key` (`draftPanelKey` for a projectless draft).
    private var panelTabs: [String: RightPanelTabs] = [:]
    private(set) var diffScope: DiffScope = .thread
    /// File the diff surface scrolls to (from a changed-files card click).
    private(set) var diffFocusPath: String?
    /// Empty = all projects.
    private(set) var projectFilter: Set<String> = []
    private(set) var searchText = ""

    /// Message waiting for the composer to take back (text and attachments).
    private(set) var pendingComposerRestore: UserMessage?
    /// The right panel fills the chat column's space ("Maximize panel").
    private(set) var isRightPanelMaximized = false
    /// The statistics board covers the chat column and the right panel. Choosing a thread or a
    /// draft (even the selected one) and opening the terminal, right panel or thread details
    /// close it, and so does opening the Terminal Agents board.
    private(set) var isStatisticsVisible = false
    /// The Terminal Agents board (Soprano's pane agents) covers the chat column and the right
    /// panel like the statistics board, closes on the same occasions, and never shows with it.
    private(set) var isTerminalAgentsVisible = false
    /// The pane agent (`AgentDashboardEntry.id`) the board should select when it shows next.
    private(set) var pendingTerminalAgentSelection: String?

    /// A board covers the chat column and the right panel.
    var isOverlayVisible: Bool { isStatisticsVisible || isTerminalAgentsVisible }

    private let observers = ObserverList<Change>()

    func addObserver(_ owner: AnyObject, _ handler: @escaping @MainActor (Change) -> Void) {
        observers.add(owner, handler)
    }

    /// The thread the selection belongs to: the selected thread, or a selected subagent's thread.
    var selectedThreadID: String? {
        switch selection {
        case let .thread(id), let .subagent(id, _): id
        case .draft: nil
        }
    }

    /// The selected subagent's id; nil unless a subagent is selected.
    var selectedSubagentID: String? {
        if case let .subagent(_, id) = selection { return id }
        return nil
    }

    var draftProjectID: String? {
        if case let .draft(projectID) = selection { return projectID }
        return nil
    }

    var isDraft: Bool {
        if case .draft = selection { return true }
        return false
    }

    /// The selection's workspace: the thread, or the project draft; nil for a projectless draft,
    /// which has no folder until its thread starts.
    var workspace: WorkspaceRef? {
        switch selection {
        case let .thread(id), let .subagent(id, _): .thread(id)
        case let .draft(projectID): projectID.map { .draft(projectID: $0) }
        }
    }

    /// `closingOverlays` false: a selection the app makes on its own (a launched draft becoming
    /// its thread, a deleted thread falling back to a draft) leaves an open board open.
    func select(_ selection: Selection, closingOverlays: Bool = true) {
        let closedOverlay = closingOverlays && closeOverlays()
        guard selection != self.selection else {
            if closedOverlay { observers.notify(.panels) }
            return
        }
        self.selection = selection
        diffFocusPath = nil
        if closedOverlay { observers.notify(.panels) }
        observers.notify(.selection)
    }

    func setSidebarVisible(_ visible: Bool) {
        guard visible != isSidebarVisible else { return }
        isSidebarVisible = visible
        observers.notify(.panels)
    }

    func setThreadDetailsVisible(_ visible: Bool) {
        let closedOverlay = visible && closeOverlays()
        guard visible != isThreadDetailsVisible || closedOverlay else { return }
        isThreadDetailsVisible = visible
        observers.notify(.panels)
    }

    func setTerminalVisible(_ visible: Bool) {
        let closedOverlay = visible && closeOverlays()
        guard visible != isTerminalVisible || closedOverlay else { return }
        isTerminalVisible = visible
        observers.notify(.panels)
    }

    func setRightPanelVisible(_ visible: Bool) {
        let closedOverlay = visible && closeOverlays()
        guard visible != isRightPanelVisible || closedOverlay else { return }
        isRightPanelVisible = visible
        if !visible { isRightPanelMaximized = false }
        observers.notify(.panels)
    }

    /// Showing the statistics board closes the Terminal Agents board.
    func setStatisticsVisible(_ visible: Bool) {
        guard visible != isStatisticsVisible else { return }
        isStatisticsVisible = visible
        if visible { isTerminalAgentsVisible = false }
        observers.notify(.panels)
    }

    /// Showing the Terminal Agents board closes the statistics board.
    func setTerminalAgentsVisible(_ visible: Bool) {
        guard visible != isTerminalAgentsVisible else { return }
        isTerminalAgentsVisible = visible
        if visible { isStatisticsVisible = false }
        observers.notify(.panels)
    }

    /// Shows the Terminal Agents board on the pane agent `entryID` (a sidebar row's click).
    func showTerminalAgents(selecting entryID: String) {
        pendingTerminalAgentSelection = entryID
        isStatisticsVisible = false
        isTerminalAgentsVisible = true
        observers.notify(.panels)
    }

    /// The board takes the pending selection (once).
    func takeTerminalAgentSelection() -> String? {
        defer { pendingTerminalAgentSelection = nil }
        return pendingTerminalAgentSelection
    }

    /// Hides both boards; whether one was showing.
    private func closeOverlays() -> Bool {
        guard isOverlayVisible else { return false }
        isStatisticsVisible = false
        isTerminalAgentsVisible = false
        return true
    }

    /// What a toggle command sets a surface to: shown while a board covers it (the board
    /// closes), else the opposite of `isVisible`.
    func toggledVisibility(_ isVisible: Bool) -> Bool {
        isOverlayVisible || !isVisible
    }

    /// Maximizes the open right panel over the chat column, or restores its width.
    func setRightPanelMaximized(_ maximized: Bool) {
        guard maximized != isRightPanelMaximized else { return }
        isRightPanelMaximized = maximized
        observers.notify(.panels)
    }

    /// Panel key of a projectless draft (never a thread id or a project draft's key).
    static let draftPanelKey = "draft:"

    private var panelKey: String { workspace?.key ?? Self.draftPanelKey }

    /// The selected workspace's right-panel tabs, in order.
    var rightPanelSurfaces: [RightPanelSurface] {
        (panelTabs[panelKey] ?? RightPanelTabs()).surfaces
    }

    /// The selected workspace's active right-panel tab; nil when every tab is closed.
    var rightPanelSurface: RightPanelSurface? {
        (panelTabs[panelKey] ?? RightPanelTabs()).active
    }

    /// The right-panel tabs of any workspace by `WorkspaceRef.key` (terminal tabs of background
    /// workspaces close too).
    func rightPanelSurfaces(for key: String) -> [RightPanelSurface] {
        (panelTabs[key] ?? RightPanelTabs()).surfaces
    }

    /// Opens the right panel on `surface`, adding it as the last tab when the workspace doesn't
    /// have it yet.
    func showRightPanel(_ surface: RightPanelSurface) {
        var tabs = panelTabs[panelKey] ?? RightPanelTabs()
        let changed = tabs.active != surface || !tabs.surfaces.contains(surface) || !isRightPanelVisible
        if !tabs.surfaces.contains(surface) { tabs.surfaces.append(surface) }
        tabs.active = surface
        panelTabs[panelKey] = tabs
        isRightPanelVisible = true
        if closeOverlays() || changed { observers.notify(.panels) }
    }

    /// Removes a tab of the workspace `key` (default: the selected one). The neighbour that takes
    /// its place (or the one before it) becomes active; the last one leaves the launcher.
    func closeRightPanelTab(_ surface: RightPanelSurface, key: String? = nil) {
        let key = key ?? panelKey
        var tabs = panelTabs[key] ?? RightPanelTabs()
        guard let index = tabs.surfaces.firstIndex(of: surface) else { return }
        tabs.surfaces.remove(at: index)
        if tabs.active == surface {
            tabs.active = tabs.surfaces.isEmpty ? nil : tabs.surfaces[min(index, tabs.surfaces.count - 1)]
        }
        panelTabs[key] = tabs
        observers.notify(.panels)
    }

    /// Forgets the tabs of deleted threads and projects (`keys`: the live `WorkspaceRef.key`s).
    func pruneRightPanelTabs(keeping keys: Set<String>) {
        panelTabs = panelTabs.filter { $0.key == Self.draftPanelKey || keys.contains($0.key) }
    }

    /// A project draft became thread `threadID` in the same folder: its tabs (terminals, open
    /// files) move to the thread and the project's next draft starts fresh.
    func moveDraftTabs(projectID: String, to threadID: String) {
        let draftKey = WorkspaceRef.draft(projectID: projectID).key
        guard let tabs = panelTabs.removeValue(forKey: draftKey) else { return }
        panelTabs[threadID] = tabs
    }

    /// Opens the diff surface on `scope`, optionally scrolled to `path`.
    func showDiff(_ scope: DiffScope, focus path: String? = nil) {
        diffScope = scope
        diffFocusPath = path
        var tabs = panelTabs[panelKey] ?? RightPanelTabs()
        if !tabs.surfaces.contains(.diff) { tabs.surfaces.append(.diff) }
        tabs.active = .diff
        panelTabs[panelKey] = tabs
        isRightPanelVisible = true
        _ = closeOverlays()
        observers.notify(.panels)
    }

    /// Puts `message` back into the composer of the selected thread (appended to any draft).
    func restoreComposer(with message: UserMessage) {
        pendingComposerRestore = message
        observers.notify(.composerRestore)
    }

    /// The composer takes the pending message (once).
    func takeComposerRestore() -> UserMessage? {
        defer { pendingComposerRestore = nil }
        return pendingComposerRestore
    }

    func setProjectFilter(_ filter: Set<String>) {
        guard filter != projectFilter else { return }
        projectFilter = filter
        observers.notify(.filter)
    }

    func setSearchText(_ text: String) {
        guard text != searchText else { return }
        searchText = text
        observers.notify(.filter)
    }
}
