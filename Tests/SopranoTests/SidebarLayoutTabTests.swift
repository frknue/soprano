import AppKit
import Testing
@testable import Soprano

@MainActor
struct SidebarLayoutTabTests {
    @Test func paneRowsNameTheirTabOnlyInWindowsWithSeveralTabsAndSelectingOneShowsIt() throws {
        let manager = AgentManager()
        let firstPaneId = manager.activePaneId
        let sidebar = SidebarView(
            agentManager: manager,
            sessionManager: SessionManager(agentManager: manager),
            themeManager: ThemeManager(themeId: "gruvbox-dark"),
            gitBranchMonitor: GitBranchMonitor()
        )
        sidebar.frame = NSRect(x: 0, y: 0, width: SidebarWidthStore.left.defaultWidth, height: 600)
        sidebar.layoutSubtreeIfNeeded()
        #expect(tabBadgeTexts(in: sidebar).isEmpty)

        _ = try #require(manager.createLayoutTab())
        _ = try #require(manager.splitPane(direction: .horizontal, paneId: manager.activePaneId))
        #expect(tabBadgeTexts(in: sidebar) == ["TAB 1", "TAB 2", "TAB 2"])

        let firstRow = try #require(
            descendants(of: sidebar, as: NSView.self).first {
                $0.identifier?.rawValue == "sidebar-pane-\(firstPaneId)"
            }
        )
        firstRow.mouseDown(with: try click(at: NSPoint(x: 4, y: firstRow.bounds.midY), in: firstRow))
        #expect(manager.activePaneId == firstPaneId)
        #expect(manager.windows[manager.activeWindowId]?.activeTabIndex == 0)
    }

    private func click(at point: NSPoint, in view: NSView) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: view.convert(point, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }

    private func tabBadgeTexts(in view: NSView) -> [String] {
        descendants(of: view, as: NSTextField.self)
            .filter { $0.identifier?.rawValue == "pane-layout-tab-badge" }
            .map(\.stringValue)
    }

    private func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        view.subviews.flatMap { subview in
            let current = (subview as? T).map { [$0] } ?? []
            return current + descendants(of: subview, as: type)
        }
    }
}
