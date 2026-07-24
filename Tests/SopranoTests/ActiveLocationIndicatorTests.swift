import AppKit
import Testing
@testable import Soprano

@MainActor
struct ActiveLocationIndicatorTests {
    @Test func everyThemeTintsSelectionDistinctlyFromItsPanelSurface() {
        // Regression guard: selection highlights used bgRaised, which Gruvbox Dark
        // defines as the same color as bgPanel, so nothing looked selected.
        for theme in AppTheme.allThemes {
            #expect(theme.colors.bgSelected != theme.colors.bgPanel)
            #expect(theme.colors.bgSelectedStrong != theme.colors.bgPanel)
            #expect(theme.colors.bgSelected != theme.colors.bgSelectedStrong)
        }
    }

    @Test func railMarksOnlyTheActiveWindowsRows() throws {
        let manager = AgentManager()
        let firstWindowPanes = manager.orderedPanes(in: manager.activeWindowId).count
        let secondWindowId = try #require(manager.createWindow())
        let sidebar = makeSidebar(manager: manager)

        // The new window is active: its own window row plus each of its panes.
        let activePanes = manager.orderedPanes(in: secondWindowId).count
        #expect(visibleRailCount(in: sidebar) == activePanes + 1)

        manager.activateWindow(secondWindowId)
        #expect(manager.activeWindowId == secondWindowId)
        #expect(visibleRailCount(in: sidebar) == activePanes + 1)
        #expect(hiddenRailCount(in: sidebar) == firstWindowPanes + 1)
    }

    @Test func statusBarNamesTheActiveWindowAndPane() throws {
        let manager = AgentManager()
        manager.renameWindow(manager.activeWindowId, to: "Soprano")
        let paneId = manager.activePaneId
        let tabId = try #require(manager.panes[paneId]?.activeTab?.id)
        manager.renameTab(paneId, tabId: tabId, to: "Claude")

        let statusBar = StatusBarView(
            agentManager: manager,
            themeManager: ThemeManager(themeId: "gruvbox-dark")
        )

        #expect(locationText(in: statusBar) == "Soprano ▸ Claude")
    }

    @Test func statusBarAppendsTheDepthLayerOnlyForWindowsWithInnerWorkspaces() throws {
        let manager = AgentManager()
        manager.renameWindow(manager.activeWindowId, to: "Soprano")
        let statusBar = StatusBarView(
            agentManager: manager,
            themeManager: ThemeManager(themeId: "gruvbox-dark")
        )
        #expect(locationText(in: statusBar)?.contains("· Z") == false)

        _ = try #require(manager.goIn(manager.activePaneId))
        let innerPaneId = manager.activePaneId
        #expect(locationText(in: statusBar)?.hasSuffix("· Z1") == true)

        // The branch survives Go Out, so the layer stays worth reporting at Z0.
        #expect(manager.goOut(innerPaneId))
        #expect(locationText(in: statusBar)?.hasSuffix("· Z0") == true)
    }

    // MARK: - Helpers

    private func makeSidebar(manager: AgentManager) -> SidebarView {
        let sidebar = SidebarView(
            agentManager: manager,
            sessionManager: SessionManager(agentManager: manager),
            themeManager: ThemeManager(themeId: "gruvbox-dark"),
            gitBranchMonitor: GitBranchMonitor()
        )
        sidebar.frame = NSRect(x: 0, y: 0, width: SidebarWidthStore.defaultWidth, height: 800)
        sidebar.layoutSubtreeIfNeeded()
        return sidebar
    }

    private func rails(in view: NSView) -> [NSView] {
        descendants(of: view, as: NSView.self).filter {
            $0.identifier?.rawValue == "sidebar-selection-rail"
        }
    }

    private func visibleRailCount(in view: NSView) -> Int {
        rails(in: view).filter { !$0.isHidden }.count
    }

    private func hiddenRailCount(in view: NSView) -> Int {
        rails(in: view).filter(\.isHidden).count
    }

    private func locationText(in view: NSView) -> String? {
        descendants(of: view, as: NSTextField.self)
            .first { $0.identifier?.rawValue == "status-location" }?
            .stringValue
    }

    private func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        view.subviews.flatMap { subview in
            let current = (subview as? T).map { [$0] } ?? []
            return current + descendants(of: subview, as: type)
        }
    }
}
