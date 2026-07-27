import AppKit
import Testing
@testable import Soprano

@MainActor
struct SidebarCollapsePersistenceTests {
    @Test func collapsedWindowsRemainCollapsedAfterTheSavedWorkspaceIsRestored() throws {
        let suiteName = "SidebarCollapsePersistenceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let sourceManager = AgentManager()
        let windowId = sourceManager.activeWindowId
        let sourceSidebar = makeSidebar(manager: sourceManager, defaults: defaults)
        let collapseButton = try #require(
            descendants(of: sourceSidebar, as: NSButton.self).first {
                $0.image?.accessibilityDescription == "Collapse Window"
            }
        )
        collapseButton.performClick(nil)

        #expect(sourceManager.windows[windowId]?.isSidebarCollapsed == true)
        #expect(paneRowCount(in: sourceSidebar) == 0)

        WorkspaceSession.saveLast(
            sourceManager.snapshotWorkspace(),
            defaults: defaults
        )

        let restoredManager = AgentManager()
        restoredManager.restoreWorkspace(
            try #require(WorkspaceSession.loadLast(defaults: defaults))
        )
        let sidebar = makeSidebar(manager: restoredManager, defaults: defaults)

        #expect(restoredManager.windows[windowId]?.isSidebarCollapsed == true)
        #expect(paneRowCount(in: sidebar) == 0)
    }

    @Test func sessionsWithoutSidebarDisclosureStateRestoreExpanded() throws {
        let legacyData = Data(
            """
            {
              "id": "window-1",
              "title": "Terminal",
              "layout": {"leaf": {"_0": "pane-1"}},
              "activePaneId": "pane-1"
            }
            """.utf8
        )

        let savedWindow = try JSONDecoder().decode(
            WorkspaceSession.SavedWindow.self,
            from: legacyData
        )
        let manager = AgentManager()
        manager.restoreWorkspace(
            WorkspaceSession(
                id: "legacy",
                name: "Legacy",
                savedAt: .distantPast,
                layout: savedWindow.layout,
                panes: [
                    .init(
                        id: "pane-1",
                        activeTabIndex: 0,
                        tabs: [.init(id: "tab-2", type: .terminal)]
                    ),
                ],
                activePaneId: "pane-1",
                windows: [savedWindow],
                activeWindowId: savedWindow.id
            )
        )

        #expect(savedWindow.isSidebarCollapsed == nil)
        #expect(manager.windows[savedWindow.id]?.isSidebarCollapsed == false)
    }

    private func makeSidebar(
        manager: AgentManager,
        defaults: UserDefaults
    ) -> SidebarView {
        let sidebar = SidebarView(
            agentManager: manager,
            sessionManager: SessionManager(agentManager: manager, defaults: defaults),
            themeManager: ThemeManager(themeId: "gruvbox-dark"),
            gitBranchMonitor: GitBranchMonitor()
        )
        sidebar.frame = NSRect(
            x: 0,
            y: 0,
            width: SidebarWidthStore.defaultWidth,
            height: 600
        )
        sidebar.layoutSubtreeIfNeeded()
        return sidebar
    }

    private func paneRowCount(in view: NSView) -> Int {
        descendants(of: view, as: NSView.self).count {
            $0.identifier?.rawValue.hasPrefix("sidebar-pane-") == true
        }
    }

    private func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        view.subviews.flatMap { subview in
            let current = (subview as? T).map { [$0] } ?? []
            return current + descendants(of: subview, as: type)
        }
    }
}
