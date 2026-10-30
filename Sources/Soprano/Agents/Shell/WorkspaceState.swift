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

    /// Right panel surfaces (the right-panel tabs).
    enum RightPanelSurface: String, Equatable, CaseIterable {
        case diff

        var title: String {
            switch self {
            case .diff: "Diff"
            }
        }
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
    private(set) var rightPanelSurface: RightPanelSurface = .diff
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

    /// Opens the right panel on `surface`.
    func showRightPanel(_ surface: RightPanelSurface) {
        let changed = surface != rightPanelSurface || !isRightPanelVisible
        rightPanelSurface = surface
        isRightPanelVisible = true
        if changed { observers.notify(.panels) }
    }

    /// Opens the diff surface on `scope`, optionally scrolled to `path`.
    func showDiff(_ scope: DiffScope, focus path: String? = nil) {
        diffScope = scope
        diffFocusPath = path
        rightPanelSurface = .diff
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
