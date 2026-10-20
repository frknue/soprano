import AppKit
import Testing
@testable import Soprano

@MainActor
struct SidebarCollapseAllTests {
    @Test func collapseAllButtonCollapsesEveryWindowAndDisablesItselfUntilOneIsExpandedAgain() throws {
        let suiteName = "SidebarCollapseAllTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = AgentManager()
        for _ in 0..<2 {
            _ = try #require(manager.createWindow())
        }
        let windows = manager.activeSessionWindows
        manager.toggleSidebarWindowCollapsed(try #require(windows.first).id)

        let sidebar = SidebarView(
            agentManager: manager,
            sessionManager: SessionManager(agentManager: manager, defaults: defaults),
            themeManager: ThemeManager(themeId: "gruvbox-dark"),
            gitBranchMonitor: GitBranchMonitor()
        )
        sidebar.frame = NSRect(x: 0, y: 0, width: SidebarWidthStore.left.defaultWidth, height: 600)
        sidebar.layoutSubtreeIfNeeded()
        let collapseAll = try #require(
            descendants(of: sidebar, as: NSButton.self).first {
                $0.accessibilityLabel() == "Collapse All Windows"
            }
        )
        #expect(collapseAll.isEnabled)
        #expect(paneRowCount(in: sidebar) > 0)

        collapseAll.performClick(nil)

        #expect(windows.allSatisfy { manager.windows[$0.id]?.isSidebarCollapsed == true })
        #expect(paneRowCount(in: sidebar) == 0)
        #expect(!collapseAll.isEnabled)

        manager.toggleSidebarWindowCollapsed(try #require(windows.last).id)
        #expect(collapseAll.isEnabled)
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
