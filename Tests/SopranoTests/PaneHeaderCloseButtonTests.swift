import AppKit
import Testing
@testable import Soprano

@MainActor
struct PaneHeaderCloseButtonTests {
    @Test func closingOnePaneOfASplitTabKeepsItsSiblingAndOnlyTheLastPaneClosesTheTab() throws {
        let manager = AgentManager()
        let rootPaneId = manager.activePaneId
        _ = try #require(manager.createLayoutTab())
        let firstInnerPaneId = manager.activePaneId
        let secondInnerPaneId = try #require(
            manager.splitPane(direction: .horizontal, paneId: firstInnerPaneId)
        )
        let themeManager = ThemeManager(themeId: "gruvbox-dark")

        try clickClose(on: secondInnerPaneId, manager: manager, themeManager: themeManager)

        #expect(manager.panes[secondInnerPaneId] == nil)
        #expect(manager.panes[firstInnerPaneId] != nil)
        #expect(manager.windows[manager.activeWindowId]?.activeTabIndex == 1)
        #expect(manager.layout?.leafIds == [firstInnerPaneId])

        try clickClose(on: firstInnerPaneId, manager: manager, themeManager: themeManager)

        #expect(manager.panes[firstInnerPaneId] == nil)
        #expect(manager.windows[manager.activeWindowId]?.tabs.count == 1)
        #expect(manager.activePaneId == rootPaneId)
        #expect(manager.layout?.leafIds == [rootPaneId])
    }

    @Test func closingInATabClosesOnlyThePanesActivePaneTab() throws {
        let manager = AgentManager()
        _ = try #require(manager.createLayoutTab())
        let innerPaneId = manager.activePaneId
        let firstTabId = try #require(manager.panes[innerPaneId]?.activeTab?.id)
        _ = try #require(manager.addTabToPane(innerPaneId, type: .terminal))

        try clickClose(
            on: innerPaneId,
            manager: manager,
            themeManager: ThemeManager(themeId: "gruvbox-dark")
        )

        #expect(manager.panes[innerPaneId]?.tabs.map(\.id) == [firstTabId])
        #expect(manager.windows[manager.activeWindowId]?.activeTabIndex == 1)
    }

    private func clickClose(
        on paneId: String,
        manager: AgentManager,
        themeManager: ThemeManager
    ) throws {
        let header = PaneHeaderView(
            paneId: paneId,
            agentManager: manager,
            themeManager: themeManager
        )
        let closeButton = try #require(
            descendants(of: header, as: NSButton.self).first {
                $0.identifier?.rawValue == "pane-close-button"
            }
        )
        closeButton.performClick(nil)
    }

    private func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        view.subviews.flatMap { subview in
            let current = (subview as? T).map { [$0] } ?? []
            return current + descendants(of: subview, as: type)
        }
    }
}
