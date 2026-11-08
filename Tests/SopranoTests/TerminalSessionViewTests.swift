import AppKit
import Testing
@testable import Soprano

@MainActor
struct TerminalSessionViewTests {
    @Test func theSidebarSelectorSwitchesSessionsAndListsOnlyTheirPanes() throws {
        let suiteName = "TerminalSessionViewTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = AgentManager()
        let firstSessionId = manager.activeSessionId
        let firstPaneId = manager.activePaneId
        let otherSessionId = try #require(manager.createSession(name: "Another project"))
        let otherPaneId = manager.activePaneId
        let sidebar = SidebarView(
            agentManager: manager,
            sessionManager: SessionManager(agentManager: manager, defaults: defaults),
            themeManager: ThemeManager(themeId: "gruvbox-dark"),
            gitBranchMonitor: GitBranchMonitor()
        )
        sidebar.setContentWidth(160)
        sidebar.frame = NSRect(x: 0, y: 0, width: 160, height: 600)
        sidebar.layoutSubtreeIfNeeded()
        let selector = try #require(descendants(in: sidebar).first { $0.identifier?.rawValue == "session-selector" })
        #expect(selector.accessibilityValue() as? String == "Another project")
        #expect(paneIds(in: sidebar) == ["sidebar-pane-\(otherPaneId)"])
        #expect(selector.frame.width > 0 && selector.frame.width <= 160)

        // Exercise the switcher menu's actual target/action, without showing it.
        let menu = sidebar.makeSessionMenu()
        #expect(menu.items.first { $0.state == .on }?.representedObject as? String == otherSessionId)
        let firstIndex = try #require(menu.items.firstIndex {
            $0.representedObject as? String == firstSessionId
        })
        menu.performActionForItem(at: firstIndex)
        #expect(manager.activeSessionId == firstSessionId)
        #expect(selector.accessibilityValue() as? String == manager.activeSession?.name)
        #expect(paneIds(in: sidebar) == ["sidebar-pane-\(firstPaneId)"])
        let titles = menu.items.map(\.title)
        #expect(titles.contains("New Session…"))
        #expect(titles.contains("Rename Session…"))
        #expect(titles.contains("Close Session…"))

        manager.renameSession(firstSessionId, to: String(repeating: "Long project name ", count: 10))
        sidebar.layoutSubtreeIfNeeded()
        #expect(selector.frame.width > 0 && selector.frame.width <= 160)
    }

    @Test func theStatusBarTracksTheSessionWhenSwitchingWindows() throws {
        let manager = AgentManager()
        let firstSessionId = manager.activeSessionId
        manager.renameSession(firstSessionId, to: "Work")
        manager.renameWindow(manager.activeWindowId, to: "Editor")
        let statusBar = StatusBarView(
            agentManager: manager,
            themeManager: ThemeManager(themeId: "gruvbox-dark")
        )
        let label = try #require(descendants(in: statusBar).compactMap { $0 as? NSTextField }.first {
            $0.identifier?.rawValue == "status-location"
        })
        #expect(label.stringValue.hasPrefix("Work  /  Editor  /  "))
        _ = try #require(manager.createSession(name: "Personal"))
        #expect(label.stringValue.hasPrefix("Personal  /  "))
        manager.activateSession(firstSessionId)
        #expect(label.stringValue.hasPrefix("Work  /  Editor  /  "))
    }

    private func descendants(in view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(in: $0) }
    }

    private func paneIds(in view: NSView) -> Set<String> {
        Set(descendants(in: view).compactMap { $0.identifier?.rawValue }.filter {
            $0.hasPrefix("sidebar-pane-")
        })
    }
}
