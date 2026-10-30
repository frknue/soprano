import AppKit
import SopranoAgentsCore

/// UI state of the window: what is selected and which panels are open. Views read it and observe
/// `Change`s; every region writes through its setters. Engine data lives in `AgentEngine`.
@MainActor
final class WorkspaceState {
    enum Change: Equatable {
        /// The selected thread or the draft changed.
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
    }

    /// One right-panel tab. Diff and Files exist at most once per thread; a file tab per
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

    /// The tabs of one thread's right panel; `active` nil shows the "Open a surface" launcher.
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
    /// Right-panel tabs per thread id ("" for the draft).
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

    private let observers = ObserverList<Change>()

    func addObserver(_ owner: AnyObject, _ handler: @escaping @MainActor (Change) -> Void) {
        observers.add(owner, handler)
    }

    var selectedThreadID: String? {
        if case let .thread(id) = selection { return id }
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

    func select(_ selection: Selection) {
        guard selection != self.selection else { return }
        self.selection = selection
        diffFocusPath = nil
        observers.notify(.selection)
    }

    func setSidebarVisible(_ visible: Bool) {
        guard visible != isSidebarVisible else { return }
        isSidebarVisible = visible
        observers.notify(.panels)
    }

    func setThreadDetailsVisible(_ visible: Bool) {
        guard visible != isThreadDetailsVisible else { return }
        isThreadDetailsVisible = visible
        observers.notify(.panels)
    }

    func setTerminalVisible(_ visible: Bool) {
        guard visible != isTerminalVisible else { return }
        isTerminalVisible = visible
        observers.notify(.panels)
    }

    func setRightPanelVisible(_ visible: Bool) {
        guard visible != isRightPanelVisible else { return }
        isRightPanelVisible = visible
        if !visible { isRightPanelMaximized = false }
        observers.notify(.panels)
    }

    /// Maximizes the open right panel over the chat column, or restores its width.
    func setRightPanelMaximized(_ maximized: Bool) {
        guard maximized != isRightPanelMaximized else { return }
        isRightPanelMaximized = maximized
        observers.notify(.panels)
    }

    private var panelKey: String { selectedThreadID ?? "" }

    /// The selected thread's right-panel tabs, in order.
    var rightPanelSurfaces: [RightPanelSurface] {
        (panelTabs[panelKey] ?? RightPanelTabs()).surfaces
    }

    /// The selected thread's active right-panel tab; nil when every tab is closed.
    var rightPanelSurface: RightPanelSurface? {
        (panelTabs[panelKey] ?? RightPanelTabs()).active
    }

    /// The right-panel tabs of any thread (terminal tabs of background threads close too).
    func rightPanelSurfaces(for threadID: String) -> [RightPanelSurface] {
        (panelTabs[threadID] ?? RightPanelTabs()).surfaces
    }

    /// Opens the right panel on `surface`, adding it as the last tab when the thread doesn't have
    /// it yet.
    func showRightPanel(_ surface: RightPanelSurface) {
        var tabs = panelTabs[panelKey] ?? RightPanelTabs()
        let changed = tabs.active != surface || !tabs.surfaces.contains(surface) || !isRightPanelVisible
        if !tabs.surfaces.contains(surface) { tabs.surfaces.append(surface) }
        tabs.active = surface
        panelTabs[panelKey] = tabs
        isRightPanelVisible = true
        if changed { observers.notify(.panels) }
    }

    /// Removes a tab of `threadID` (default: the selected thread). The neighbour that takes its
    /// place (or the one before it) becomes active; the last one leaves the launcher.
    func closeRightPanelTab(_ surface: RightPanelSurface, threadID: String? = nil) {
        let key = threadID ?? panelKey
        var tabs = panelTabs[key] ?? RightPanelTabs()
        guard let index = tabs.surfaces.firstIndex(of: surface) else { return }
        tabs.surfaces.remove(at: index)
        if tabs.active == surface {
            tabs.active = tabs.surfaces.isEmpty ? nil : tabs.surfaces[min(index, tabs.surfaces.count - 1)]
        }
        panelTabs[key] = tabs
        observers.notify(.panels)
    }

    /// Forgets the tabs of deleted threads.
    func pruneRightPanelTabs(keeping threadIDs: Set<String>) {
        panelTabs = panelTabs.filter { $0.key.isEmpty || threadIDs.contains($0.key) }
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
