import AppKit
import Testing
@testable import Soprano

@MainActor
struct WindowTabBarTests {
    @Test func numberedTabsFollowWindowCreationSelectionRenamingAndClosing() throws {
        let manager = AgentManager()
        let firstWindowId = manager.activeWindowId
        manager.renameWindow(firstWindowId, to: "Editor")
        let secondWindowId = try #require(manager.createWindow())
        manager.renameWindow(secondWindowId, to: "Logs")
        let bar = makeBar(manager: manager)
        #expect(tabs(in: bar).map(\.title) == ["1:Editor", "2:Logs"])
        #expect(selectedTabs(in: bar).map(\.title) == ["2:Logs"])

        tabs(in: bar)[0].performClick(nil)
        #expect(manager.activeWindowId == firstWindowId)
        #expect(selectedTabs(in: bar).map(\.title) == ["1:Editor"])
        manager.renameWindow(firstWindowId, to: "Code")
        #expect(tabs(in: bar)[0].title == "1:Code")

        let addButton = try #require(descendants(in: bar).compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == "new-window-tab"
        })
        addButton.performClick(nil)
        #expect(tabs(in: bar).count == 3)
        #expect(selectedTabs(in: bar).first?.identifier?.rawValue == "window-tab-\(manager.activeWindowId)")
        manager.closeWindow(secondWindowId)
        #expect(tabs(in: bar).count == 2)
        #expect(tabs(in: bar)[1].title.hasPrefix("2:"))
    }

    @Test func theRowShowsOnlyTheCurrentSessionsWindows() throws {
        let manager = AgentManager()
        let firstSessionId = manager.activeSessionId
        manager.renameWindow(manager.activeWindowId, to: "Work")
        let bar = makeBar(manager: manager)
        _ = try #require(manager.createSession(name: "Personal"))
        manager.renameWindow(manager.activeWindowId, to: "Notes")
        #expect(tabs(in: bar).map(\.title) == ["1:Notes"])
        manager.activateSession(firstSessionId)
        #expect(tabs(in: bar).map(\.title) == ["1:Work"])
    }

    @Test func activityIndicatorsFollowAgentLifecycleWithoutChangingTheWindowTitle() throws {
        let manager = AgentManager()
        manager.renameWindow(manager.activeWindowId, to: "Editor")
        let bar = makeBar(manager: manager)
        let button = try #require(tabs(in: bar).first)
        #expect(button.image == nil)
        let paneId = manager.activePaneId
        let tabId = try #require(manager.addTabToPane(paneId, type: .agent, profileId: "codex"))

        for status: AgentStatus in [.starting, .running, .idle, .waiting, .error, .running, .stopped] {
            manager.updateAgentStatus(paneId: paneId, tabId: tabId, status: status)
            let isWorking = status == .starting || status == .running
            #expect((button.image != nil) == isWorking)
            let description = isWorking
                ? "Window 1: Editor — 1 agent starting or working"
                : "Window 1: Editor"
            #expect(button.toolTip == description)
            #expect(button.accessibilityLabel() == description)
            #expect(button.title == "1:Editor")
            #expect(selectedTabs(in: bar) == [button])
        }

        manager.restartAgent(target: TerminalTarget(paneId: paneId, tabId: tabId))
        #expect(button.image != nil)
        manager.removeTabFromPane(paneId, tabId: tabId)
        #expect(button.image == nil)
    }

    @Test func backgroundWindowsCountAgentsInInactiveTabsAndHiddenDepthLayers() throws {
        let manager = AgentManager()
        let windowId = manager.activeWindowId
        manager.renameWindow(windowId, to: "Work")
        let paneId = manager.activePaneId
        let agentTabId = try #require(manager.addTabToPane(paneId, type: .agent, profileId: "codex"))
        manager.updateAgentStatus(paneId: paneId, tabId: agentTabId, status: .running)
        manager.switchTab(paneId, index: 0)
        _ = try #require(manager.goIn(paneId))
        let innerPaneId = manager.activePaneId
        let innerTabId = try #require(manager.addTabToPane(innerPaneId, type: .agent, profileId: "claude-code"))
        #expect(manager.goOut(innerPaneId))
        _ = try #require(manager.createWindow())
        let bar = makeBar(manager: manager)
        let button = tabs(in: bar)[0]
        #expect(button.image != nil)
        #expect(button.toolTip == "Window 1: Work — 2 agents starting or working")
        #expect(tabs(in: bar)[1].image == nil)

        manager.updateAgentStatus(paneId: paneId, tabId: agentTabId, status: .idle)
        #expect(button.image != nil)
        #expect(button.toolTip == "Window 1: Work — 1 agent starting or working")
        manager.removeTabFromPane(innerPaneId, tabId: innerTabId)
        #expect(button.image == nil)
        #expect(button.toolTip == "Window 1: Work")
    }

    @Test func agentsAttachedToShellsOnlyIndicateActivityInTheirOwnSessionAndClearOnExit() throws {
        let manager = AgentManager()
        let sessionId = manager.activeSessionId
        let paneId = manager.activePaneId
        let tabId = try #require(manager.panes[paneId]?.activeTab?.id)
        let bar = makeBar(manager: manager)
        _ = try #require(manager.attachAgentIfNeeded(paneId: paneId, tabId: tabId, profileId: "codex"))
        manager.updateAgentStatus(paneId: paneId, tabId: tabId, status: .running)
        #expect(tabs(in: bar)[0].image != nil)

        _ = try #require(manager.createSession(name: "Personal"))
        #expect(tabs(in: bar).count == 1)
        #expect(tabs(in: bar)[0].image == nil)
        manager.activateSession(sessionId)
        #expect(tabs(in: bar)[0].image != nil)
        manager.agentProcessDidExit(target: TerminalTarget(paneId: paneId, tabId: tabId))
        #expect(tabs(in: bar)[0].image == nil)
    }

    @Test func overflowingTabsScrollToKeepTheKeyboardSelectedWindowVisible() throws {
        let manager = AgentManager()
        for index in 1...12 {
            _ = try #require(manager.createWindow())
            manager.renameWindow(manager.activeWindowId, to: "Window \(index)")
        }
        let bar = makeBar(manager: manager, width: 360)
        let scrollView = try #require(descendants(in: bar).compactMap { $0 as? NSScrollView }.first)
        let selected = try #require(selectedTabs(in: bar).first)
        #expect(scrollView.documentVisibleRect.contains(selected.frame))
        #expect(scrollView.documentVisibleRect.minX > 0)

        manager.activateWindow(number: 1)
        bar.layoutSubtreeIfNeeded()
        #expect(scrollView.documentVisibleRect.minX == 0)
        #expect(scrollView.documentVisibleRect.contains(tabs(in: bar)[0].frame))
        manager.activatePreviousWindow()
        bar.setFrameSize(NSSize(width: 260, height: WindowTabBarView.height))
        bar.layoutSubtreeIfNeeded()
        #expect(scrollView.documentVisibleRect.contains(try #require(selectedTabs(in: bar).first).frame))
    }

    @Test func tabsStayVisibleAboveTheTerminalWhenBothWindowBarAndSidebarAreHidden() throws {
        let suiteName = "WindowTabBarTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: "soprano-sidebar-visible")
        let manager = AgentManager()
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
                    terminalViewFactory: { _, _, _ in WindowTabInputView() }
                )
            }
        )
        let window = MainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        MainWindowAppearance.apply(hideWindowBar: true, to: window)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1000, height: 600))
        controller.view.layoutSubtreeIfNeeded()
        let bar = try #require(descendants(in: controller.view).compactMap { $0 as? WindowTabBarView }.first)
        let splitTree = try #require(descendants(in: controller.view).compactMap { $0 as? SplitTreeView }.first)
        #expect(!bar.isHidden)
        #expect(bar.frame.height == WindowTabBarView.height)
        #expect(bar.frame.width == controller.view.bounds.width)
        #expect(!bar.frame.intersects(splitTree.frame))
        #expect(tabs(in: bar).count == 1)

        let input = try #require(descendants(in: splitTree).compactMap { $0 as? WindowTabInputView }.first)
        #expect(window.makeFirstResponder(input))
        tabs(in: bar)[0].performClick(nil)
        #expect(window.firstResponder === input)
        #expect(window.canBecomeKey)
    }

    private func makeBar(manager: AgentManager, width: CGFloat = 800) -> WindowTabBarView {
        let bar = WindowTabBarView(agentManager: manager, themeManager: ThemeManager(themeId: "gruvbox-dark"))
        bar.frame = NSRect(x: 0, y: 0, width: width, height: WindowTabBarView.height)
        bar.layoutSubtreeIfNeeded()
        return bar
    }

    private func descendants(in view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(in: $0) }
    }

    private func tabs(in view: NSView) -> [NSButton] {
        descendants(in: view).compactMap { $0 as? NSButton }.filter {
            $0.identifier?.rawValue.hasPrefix("window-tab-window-") == true
        }
    }

    private func selectedTabs(in view: NSView) -> [NSButton] {
        tabs(in: view).filter { $0.accessibilityValue() as? Bool == true }
    }
}

private final class WindowTabInputView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
