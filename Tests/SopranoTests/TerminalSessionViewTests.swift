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
        let selector = try #require(descendants(in: sidebar).compactMap { $0 as? NSPopUpButton }.first)
        #expect(selector.selectedItem?.representedObject as? String == otherSessionId)
        #expect(paneIds(in: sidebar) == ["sidebar-pane-\(otherPaneId)"])
        #expect(selector.frame.width > 0 && selector.frame.width <= 160)

        // Exercise the menu's actual target/action, without showing a window.
        let firstIndex = try #require(selector.itemArray.firstIndex {
            $0.representedObject as? String == firstSessionId
        })
        selector.menu?.performActionForItem(at: firstIndex)
        #expect(manager.activeSessionId == firstSessionId)
        #expect(selector.selectedItem?.representedObject as? String == firstSessionId)
        #expect(paneIds(in: sidebar) == ["sidebar-pane-\(firstPaneId)"])
        #expect(selector.itemTitles.contains("New Session…"))
        #expect(selector.itemTitles.contains("Rename Session…"))
        #expect(selector.itemTitles.contains("Close Session…"))

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
        #expect(label.stringValue.hasPrefix("Work ▸ Editor ▸ "))
        _ = try #require(manager.createSession(name: "Personal"))
        #expect(label.stringValue.hasPrefix("Personal ▸ "))
        manager.activateSession(firstSessionId)
        #expect(label.stringValue.hasPrefix("Work ▸ Editor ▸ "))
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
