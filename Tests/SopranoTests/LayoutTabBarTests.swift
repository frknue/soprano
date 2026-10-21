import AppKit
import Testing
@testable import Soprano

@MainActor
struct LayoutTabBarTests {
    @Test func theRowShowsTheActiveWindowsTabsNamedAfterTheirFocusedPanes() throws {
        let manager = AgentManager()
        rename(manager.activePaneId, to: "editor", in: manager)
        _ = try #require(manager.createLayoutTab())
        rename(manager.activePaneId, to: "server", in: manager)
        let bar = makeBar(manager: manager)
        #expect(tabs(in: bar).map(\.title) == ["editor", "server"])
        #expect(selectedTabs(in: bar).map(\.title) == ["server"])

        _ = try #require(manager.createWindow())
        rename(manager.activePaneId, to: "logs", in: manager)
        #expect(tabs(in: bar).map(\.title) == ["logs"])
        manager.activatePreviousWindow()
        #expect(tabs(in: bar).map(\.title) == ["editor", "server"])
    }

    @Test func newTabStaysOnScreenWhenTheTabsOverflow() throws {
        let manager = AgentManager()
        for _ in 1...12 { _ = try #require(manager.createLayoutTab()) }
        let bar = makeBar(manager: manager)
        bar.setFrameSize(NSSize(width: 360, height: LayoutTabBarView.height))
        tabs(in: bar)[0].performClick(nil)
        bar.layoutSubtreeIfNeeded()
        let scrollView = try #require(descendants(in: bar).compactMap { $0 as? NSScrollView }.first)
        let addButton = try button(withIdentifier: "new-layout-tab", in: bar)
        #expect(scrollView.documentVisibleRect.minX == 0)
        #expect(bar.bounds.contains(addButton.frame))
        #expect(addButton.frame.minX >= scrollView.frame.maxX)
        #expect(bar.hitTest(NSPoint(x: addButton.frame.midX, y: addButton.frame.midY)) === addButton)
    }

    @Test func clickingSelectsClosesAndAddsTabs() throws {
        let manager = AgentManager()
        let firstPaneId = manager.activePaneId
        let secondLayoutTabId = try #require(manager.createLayoutTab())
        let bar = makeBar(manager: manager)

        tabs(in: bar)[0].performClick(nil)
        #expect(manager.activePaneId == firstPaneId)
        #expect(selectedTabs(in: bar) == [tabs(in: bar)[0]])

        try button(withIdentifier: "close-layout-tab-\(secondLayoutTabId)", in: bar).performClick(nil)
        #expect(manager.windows[manager.activeWindowId]?.tabs.count == 1)
        #expect(tabs(in: bar).count == 1)

        try button(withIdentifier: "new-layout-tab", in: bar).performClick(nil)
        #expect(tabs(in: bar).count == 2)
        #expect(selectedTabs(in: bar) == [tabs(in: bar)[1]])
        #expect(manager.activePaneId != firstPaneId)
    }

    @Test func aBackgroundTabFollowsItsFocusedPanesTitleAndAgents() throws {
        let manager = AgentManager()
        let backgroundPaneId = manager.activePaneId
        _ = try #require(manager.createLayoutTab())
        let bar = makeBar(manager: manager)
        let background = tabs(in: bar)[0]
        #expect(agentBadge(in: background) == nil)

        rename(backgroundPaneId, to: "renamed by its shell", in: manager)
        #expect(background.title == "renamed by its shell")

        let agentTabId = try #require(
            manager.addTabToPane(backgroundPaneId, type: .agent, profileId: "codex")
        )
        // Adding a pane tab brings its layout tab forward; send it back.
        manager.activateNextLayoutTab()
        manager.updateAgentStatus(paneId: backgroundPaneId, tabId: agentTabId, status: .waiting)
        #expect(agentBadge(in: background) != nil)
        #expect(background.toolTip?.hasSuffix("1 agent: 1 needs input") == true)

        manager.stopAgent(target: TerminalTarget(paneId: backgroundPaneId, tabId: agentTabId))
        #expect(agentBadge(in: background) == nil)
    }

    @Test func theTabRowSitsBetweenTheWindowTabsAndThePanes() throws {
        let suiteName = "LayoutTabBarTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = makeContent(manager: AgentManager(), defaults: defaults)
        let views = descendants(in: controller.view)
        let windowTabs = try #require(views.compactMap { $0 as? WindowTabBarView }.first)
        let layoutTabs = try #require(views.compactMap { $0 as? LayoutTabBarView }.first)
        let splitTree = try #require(views.compactMap { $0 as? SplitTreeView }.first)

        #expect(layoutTabs.frame.height == LayoutTabBarView.height)
        #expect(layoutTabs.frame.minX == windowTabs.frame.minX)
        #expect(layoutTabs.frame.width == windowTabs.frame.width)
        #expect(layoutTabs.frame.maxY == windowTabs.frame.minY)
        #expect(splitTree.frame.maxY == layoutTabs.frame.minY)
    }

    @Test func hiddenWindowTabsLeaveTheTabRowOnTopWithTheSidebarToggleAndCatchUpWhenShown() throws {
        let suiteName = "LayoutTabBarTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = AgentManager()
        let controller = makeContent(manager: manager, defaults: defaults)
        let views = descendants(in: controller.view)
        let windowTabs = try #require(views.compactMap { $0 as? WindowTabBarView }.first)
        let layoutTabs = try #require(views.compactMap { $0 as? LayoutTabBarView }.first)
        let rightSidebar = try #require(views.compactMap { $0 as? RightSidebarView }.first)
        let splitTree = try #require(views.compactMap { $0 as? SplitTreeView }.first)

        controller.setWindowTabsHidden(true)
        _ = try #require(manager.createWindow())
        controller.view.layoutSubtreeIfNeeded()

        #expect(windowTabs.isHidden)
        // Its bottom rule continues the right sidebar header's.
        #expect(layoutTabs.frame.maxY == rightSidebar.frame.maxY)
        #expect(layoutTabs.frame.height == RightSidebarView.headerHeight)
        #expect(splitTree.frame.maxY == layoutTabs.frame.minY)
        let toggle = try button(withIdentifier: "right-sidebar-toggle", in: layoutTabs)
        #expect(!toggle.isHidden)
        toggle.performClick(nil)
        #expect(rightSidebar.isOpen)
        #expect(toggle.isHidden)

        controller.setWindowTabsHidden(false)
        controller.view.layoutSubtreeIfNeeded()
        #expect(!windowTabs.isHidden)
        #expect(layoutTabs.frame.height == LayoutTabBarView.height)
        #expect(layoutTabs.frame.maxY == windowTabs.frame.minY)
        #expect(descendants(in: windowTabs).compactMap { $0 as? NSButton }.filter {
            $0.identifier?.rawValue.hasPrefix("window-tab-window-") == true
        }.count == 2)
    }

    /// The real content layout with stand-in terminals and the right sidebar
    /// closed.
    private func makeContent(manager: AgentManager, defaults: UserDefaults) -> MainContentViewController {
        defaults.set(false, forKey: "soprano-right-sidebar-visible")
        let controller = MainContentViewController(
            agentManager: manager,
            sessionManager: SessionManager(agentManager: manager, defaults: defaults),
            themeManager: ThemeManager(themeId: "gruvbox-dark"),
            gitBranchMonitor: GitBranchMonitor(),
            defaults: defaults,
            splitTreeViewFactory: { manager, theme in
                SplitTreeView(
                    agentManager: manager,
                    themeManager: theme,
                    terminalViewFactory: { _, _, _ in NSView() }
                )
            }
        )
        controller.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
        controller.view.layoutSubtreeIfNeeded()
        return controller
    }

    private func rename(_ paneId: String, to title: String, in manager: AgentManager) {
        guard let tabId = manager.panes[paneId]?.activeTab?.id else { return }
        manager.renameTab(paneId, tabId: tabId, to: title)
    }

    private func makeBar(manager: AgentManager) -> LayoutTabBarView {
        let bar = LayoutTabBarView(agentManager: manager, themeManager: ThemeManager(themeId: "gruvbox-dark"))
        bar.frame = NSRect(x: 0, y: 0, width: 800, height: LayoutTabBarView.height)
        bar.layoutSubtreeIfNeeded()
        return bar
    }

    private func descendants(in view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(in: $0) }
    }

    private func tabs(in view: NSView) -> [NSButton] {
        descendants(in: view).compactMap { $0 as? NSButton }.filter {
            $0.identifier?.rawValue.hasPrefix("layout-tab-layout-") == true
        }
    }

    private func selectedTabs(in view: NSView) -> [NSButton] {
        tabs(in: view).filter { $0.accessibilityValue() as? Bool == true }
    }

    private func button(withIdentifier identifier: String, in view: NSView) throws -> NSButton {
        try #require(descendants(in: view).compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == identifier
        })
    }

    private func agentBadge(in view: NSView) -> NSView? {
        descendants(in: view).first {
            $0.identifier?.rawValue == "layout-tab-agent-badge" && !$0.isHidden
        }
    }
}
