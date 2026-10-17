import AppKit
import Testing
@testable import Soprano

@MainActor
struct SidebarSelectionScrollTests {
    @Test(arguments: [false, true])
    func switchingWindowsRevealsTheirHeadersInBothDirections(collapsed: Bool) throws {
        try withSidebar(collapsed: collapsed) { manager, sidebar, scrollView in
            let firstWindow = try #require(manager.activeSessionWindows.first)
            let lastWindow = try #require(manager.activeSessionWindows.last)
            let lastPane = try #require(manager.panes[lastWindow.activePaneId])
            let lastTab = try #require(lastPane.activeTab)
            let firstRow = try windowRow(firstWindow.id, in: sidebar)
            let lastRow = try windowRow(lastWindow.id, in: sidebar)
            #expect(!isVisible(lastRow, in: scrollView))

            // The dashboard focuses a terminal tab, while Find Window activates its window.
            manager.focusTab(paneId: lastPane.id, tabId: lastTab.id)
            sidebar.layoutSubtreeIfNeeded()
            #expect(isVisible(lastRow, in: scrollView))

            manager.activateWindow(firstWindow.id)
            sidebar.layoutSubtreeIfNeeded()
            #expect(isVisible(firstRow, in: scrollView))
            #expect(lastWindow.isSidebarCollapsed == collapsed)
        }
    }

    @Test func backgroundRefreshesAndReselectingTheSameWindowPreserveManualScrolling() throws {
        try withSidebar { manager, sidebar, scrollView in
            let lastWindow = try #require(manager.activeSessionWindows.last)
            manager.activateWindow(lastWindow.id)
            sidebar.layoutSubtreeIfNeeded()
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            let manualOrigin = scrollView.contentView.bounds.origin

            manager.renameWindow(lastWindow.id, to: "Renamed window")
            manager.activateWindow(lastWindow.id)
            sidebar.layoutSubtreeIfNeeded()

            #expect(scrollView.contentView.bounds.origin == manualOrigin)
            let lastRow = try windowRow(lastWindow.id, in: sidebar)
            #expect(!isVisible(lastRow, in: scrollView))
        }
    }

    @Test func switchingToAnAlreadyVisibleWindowDoesNotMoveTheList() throws {
        try withSidebar { manager, sidebar, scrollView in
            let secondWindow = manager.activeSessionWindows[1]
            let secondRow = try windowRow(secondWindow.id, in: sidebar)
            #expect(isVisible(secondRow, in: scrollView))
            let originalOrigin = scrollView.contentView.bounds.origin

            manager.activateWindow(secondWindow.id)
            sidebar.layoutSubtreeIfNeeded()

            #expect(scrollView.contentView.bounds.origin == originalOrigin)
        }
    }

    @Test func dashboardSelectionAcrossSessionsRevealsTheWindowAfterItsRowsAreRebuilt() throws {
        try withSidebar { manager, sidebar, scrollView in
            let lastWindow = try #require(manager.activeSessionWindows.last)
            let pane = try #require(manager.panes[lastWindow.activePaneId])
            let tab = try #require(pane.activeTab)
            _ = try #require(manager.createSession(name: "Other session"))
            sidebar.layoutSubtreeIfNeeded()

            manager.focusTab(paneId: pane.id, tabId: tab.id)
            sidebar.layoutSubtreeIfNeeded()

            let row = try windowRow(lastWindow.id, in: sidebar)
            #expect(isVisible(row, in: scrollView))
        }
    }

    private func withSidebar(
        collapsed: Bool = false,
        _ body: (AgentManager, SidebarView, NSScrollView) throws -> Void
    ) throws {
        let suiteName = "SidebarSelectionScrollTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = AgentManager()
        for _ in 0..<19 {
            _ = try #require(manager.createWindow())
        }
        if collapsed {
            for window in manager.activeSessionWindows {
                manager.toggleSidebarWindowCollapsed(window.id)
            }
        }
        manager.activateWindow(try #require(manager.activeSessionWindows.first).id)
        let sidebar = SidebarView(
            agentManager: manager,
            sessionManager: SessionManager(agentManager: manager, defaults: defaults),
            themeManager: ThemeManager(themeId: "gruvbox-dark"),
            gitBranchMonitor: GitBranchMonitor()
        )
        sidebar.frame = NSRect(x: 0, y: 0, width: SidebarWidthStore.left.defaultWidth, height: 360)
        sidebar.layoutSubtreeIfNeeded()
        let scrollView = try #require(descendants(of: sidebar, as: NSScrollView.self).first)
        try body(manager, sidebar, scrollView)
    }

    private func windowRow(_ windowId: String, in sidebar: SidebarView) throws -> NSView {
        let title = try #require(sidebar.agentManager.windows[windowId]?.title)
        return try #require(descendants(of: sidebar, as: NSTextField.self).first {
            $0.stringValue == title
        }?.superview)
    }

    private func isVisible(_ row: NSView, in scrollView: NSScrollView) -> Bool {
        guard let documentView = scrollView.documentView else { return false }
        return scrollView.documentVisibleRect.contains(row.convert(row.bounds, to: documentView))
    }

    private func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        view.subviews.flatMap { subview in
            let current = (subview as? T).map { [$0] } ?? []
            return current + descendants(of: subview, as: type)
        }
    }
}
