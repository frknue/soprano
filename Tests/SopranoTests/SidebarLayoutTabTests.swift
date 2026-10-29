import AppKit
import Testing
@testable import Soprano

/// Pane rows carry no `Tab n`: the list groups itself by spacing instead.
@MainActor
struct SidebarLayoutTabTests {
    private func makeSidebar(_ manager: AgentManager) -> SidebarView {
        let sidebar = SidebarView(
            agentManager: manager,
            sessionManager: SessionManager(agentManager: manager),
            themeManager: ThemeManager(themeId: "gruvbox-dark"),
            gitBranchMonitor: GitBranchMonitor()
        )
        sidebar.frame = NSRect(x: 0, y: 0, width: SidebarWidthStore.left.defaultWidth, height: 600)
        return sidebar
    }

    @Test func panesSharingATabSitCloserThanPanesInSeparateTabsAndSelectingOneShowsItsTab() throws {
        let manager = AgentManager()
        let firstPaneId = manager.activePaneId
        let sidebar = makeSidebar(manager)
        _ = try #require(manager.createLayoutTab())
        let secondTabPaneId = manager.activePaneId
        let splitPaneId = try #require(manager.splitPane(direction: .horizontal, paneId: secondTabPaneId))
        sidebar.layoutSubtreeIfNeeded()

        let first = try row("sidebar-pane-\(firstPaneId)", in: sidebar)
        let second = try row("sidebar-pane-\(secondTabPaneId)", in: sidebar)
        let split = try row("sidebar-pane-\(splitPaneId)", in: sidebar)
        #expect(gap(from: second, to: split, in: sidebar) == SidebarView.rowGap)
        #expect(gap(from: first, to: second, in: sidebar) == SidebarView.tabGap)
        #expect(paneRowMetaTexts(in: sidebar).allSatisfy { !$0.contains("Tab ") })

        first.mouseDown(with: try click(at: NSPoint(x: 4, y: first.bounds.midY), in: first))
        #expect(manager.activePaneId == firstPaneId)
        #expect(manager.windows[manager.activeWindowId]?.activeTabIndex == 0)
    }

    @Test func aNewWindowStartsFurtherDownThanANewTab() throws {
        let manager = AgentManager()
        let firstPaneId = manager.activePaneId
        let sidebar = makeSidebar(manager)
        let windowId = try #require(manager.createWindow())
        sidebar.layoutSubtreeIfNeeded()

        let lastRowOfFirstWindow = try row("sidebar-pane-\(firstPaneId)", in: sidebar)
        let secondWindow = try row("sidebar-window-\(windowId)", in: sidebar)
        #expect(gap(from: lastRowOfFirstWindow, to: secondWindow, in: sidebar) == SidebarView.windowGap)
        #expect(SidebarView.windowGap > SidebarView.tabGap)
    }

    private func row(_ identifier: String, in sidebar: NSView) throws -> NSView {
        try #require(descendants(of: sidebar, as: NSView.self).first { $0.identifier?.rawValue == identifier })
    }

    /// Points between `upper`'s bottom and `lower`'s top. The sidebar is not
    /// flipped, so the lower row has the smaller y.
    private func gap(from upper: NSView, to lower: NSView, in sidebar: NSView) -> CGFloat {
        let upperFrame = upper.convert(upper.bounds, to: sidebar)
        let lowerFrame = lower.convert(lower.bounds, to: sidebar)
        return (upperFrame.minY - lowerFrame.maxY).rounded()
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

    private func paneRowMetaTexts(in view: NSView) -> [String] {
        descendants(of: view, as: NSTextField.self)
            .filter { $0.identifier?.rawValue == "pane-row-meta" && !$0.isHidden }
            .map(\.stringValue)
    }

    private func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        view.subviews.flatMap { subview in
            let current = (subview as? T).map { [$0] } ?? []
            return current + descendants(of: subview, as: type)
        }
    }
}
