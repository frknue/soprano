import Foundation

/// One tab of a logical window: a complete split layout of its own. Hidden
/// tabs keep their panes, and so their terminals, alive.
struct LayoutTab: Identifiable, Equatable {
    let id: String
    var layout: SplitNode?
    var activePaneId: String
}

/// A logical terminal window: an ordered row of tabs, each holding its own
/// split layout. Only the active tab's layout is on screen.
final class WorkspaceWindowState: Identifiable {
    let id: String
    let sessionId: String
    var title: String
    var isTitleCustom: Bool
    var isSidebarCollapsed: Bool
    /// Never empty: closing a window's last tab closes the window instead.
    private(set) var tabs: [LayoutTab]
    private(set) var activeTabIndex: Int

    var activeTab: LayoutTab { tabs[activeTabIndex] }

    /// The active tab's split layout.
    var layout: SplitNode? {
        get { tabs[activeTabIndex].layout }
        set { tabs[activeTabIndex].layout = newValue }
    }

    /// The focused pane of the active tab.
    var activePaneId: String {
        get { tabs[activeTabIndex].activePaneId }
        set { tabs[activeTabIndex].activePaneId = newValue }
    }

    init(
        id: String,
        sessionId: String = TerminalSessionState.defaultID,
        title: String,
        isTitleCustom: Bool = false,
        isSidebarCollapsed: Bool = false,
        tabs: [LayoutTab],
        activeTabIndex: Int = 0
    ) {
        precondition(!tabs.isEmpty, "A window always has at least one tab")
        self.id = id
        self.sessionId = sessionId
        self.title = title
        self.isTitleCustom = isTitleCustom
        self.isSidebarCollapsed = isSidebarCollapsed
        self.tabs = tabs
        self.activeTabIndex = min(max(0, activeTabIndex), tabs.count - 1)
    }

    /// Every pane in every tab.
    var paneIds: Set<String> {
        var ids = Set<String>()
        for tab in tabs {
            tab.layout?.insertLeafIds(into: &ids)
        }
        return ids
    }

    /// Every pane, tab by tab, in each tab's on-screen order.
    var orderedPaneIds: [String] {
        tabs.flatMap { $0.layout?.orderedLeafIds ?? [] }
    }

    /// True once the last pane of the last tab has gone.
    var isEmpty: Bool {
        tabs.allSatisfy { $0.layout == nil }
    }

    func containsPane(_ paneId: String) -> Bool {
        tabIndex(containingPane: paneId) != nil
    }

    func tabIndex(containingPane paneId: String) -> Int? {
        tabs.firstIndex { $0.layout?.containsLeaf(paneId) == true }
    }

    func tabIndex(of tabId: String) -> Int? {
        tabs.firstIndex { $0.id == tabId }
    }

    /// Brings the tab at `index` to the front. Returns whether the visible
    /// tab changed.
    @discardableResult
    func activateTab(at index: Int) -> Bool {
        guard tabs.indices.contains(index), index != activeTabIndex else { return false }
        activeTabIndex = index
        return true
    }

    /// Brings the tab holding `paneId` to the front.
    @discardableResult
    func activateTab(containingPane paneId: String) -> Bool {
        guard let index = tabIndex(containingPane: paneId) else { return false }
        return activateTab(at: index)
    }

    /// Brings the tab `offset` places away to the front, wrapping around the
    /// ends of the row.
    @discardableResult
    func activateTab(offset: Int) -> Bool {
        let count = tabs.count
        guard count > 1 else { return false }
        return activateTab(at: ((activeTabIndex + offset) % count + count) % count)
    }

    /// Adds `tab` at the end of the row and brings it to the front.
    func appendTab(_ tab: LayoutTab) {
        tabs.append(tab)
        activeTabIndex = tabs.count - 1
    }

    /// Removes the tab at `index` and returns the panes it held. Removing the
    /// active tab shows its right neighbor, or the new last tab. The last tab
    /// is never removed; closing it closes the window.
    @discardableResult
    func removeTab(at index: Int) -> Set<String> {
        guard tabs.count > 1, tabs.indices.contains(index) else { return [] }
        let removed = tabs.remove(at: index)
        if index < activeTabIndex {
            activeTabIndex -= 1
        } else {
            activeTabIndex = min(activeTabIndex, tabs.count - 1)
        }
        return removed.layout?.leafIds ?? []
    }

    @discardableResult
    func insertSplit(
        at paneId: String,
        newPaneId: String,
        direction: SplitDirection
    ) -> Bool {
        guard let index = tabIndex(containingPane: paneId),
              let currentLayout = tabs[index].layout,
              let updated = currentLayout.insertingSplit(
                at: paneId,
                newId: newPaneId,
                direction: direction
              )
        else { return false }
        tabs[index].layout = updated
        tabs[index].activePaneId = newPaneId
        return true
    }

    /// Removes `paneId` from its tab without bringing that tab to the front.
    /// A tab left without panes goes too, unless it is the last one: an empty
    /// window is for the caller to close.
    func removePane(_ paneId: String) {
        guard let index = tabIndex(containingPane: paneId),
              let currentLayout = tabs[index].layout
        else { return }
        guard let updated = currentLayout.removing(paneId) else {
            tabs[index].layout = nil
            removeTab(at: index)
            return
        }
        tabs[index].layout = updated
        if tabs[index].activePaneId == paneId, let firstPaneId = updated.firstLeaf {
            tabs[index].activePaneId = firstPaneId
        }
    }

    @discardableResult
    func setSplitPercentage(
        at path: [SplitBranchSide],
        to percentage: Double
    ) -> Bool {
        guard let currentLayout = layout else { return false }
        let updated = currentLayout.settingSplitPercentage(at: path, to: percentage)
        guard updated != currentLayout else { return false }
        layout = updated
        return true
    }

    @discardableResult
    func adjustSplit(at path: [SplitBranchSide], delta: Double) -> Bool {
        guard let currentLayout = layout else { return false }
        let updated = currentLayout.adjustingSplit(at: path, delta: delta)
        guard updated != currentLayout else { return false }
        layout = updated
        return true
    }
}
