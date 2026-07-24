import AppKit
import Testing
@testable import Soprano

@MainActor
struct SidebarPaneDepthTests {
    @Test func paneDisclosureExpandsIntoSelectableDepthRows() throws {
        let manager = AgentManager()
        _ = try #require(manager.goIn(manager.activePaneId))
        let sidebar = SidebarView(
            agentManager: manager,
            sessionManager: SessionManager(agentManager: manager),
            themeManager: ThemeManager(themeId: "gruvbox-dark"),
            gitBranchMonitor: GitBranchMonitor()
        )
        sidebar.frame = NSRect(x: 0, y: 0, width: SidebarView.width, height: 600)
        sidebar.layoutSubtreeIfNeeded()

        let disclosure = try #require(
            descendants(of: sidebar, as: NSButton.self).first {
                $0.identifier?.rawValue == "pane-depth-disclosure"
            }
        )
        #expect(depthBadgeTexts(in: sidebar) == ["Z1/1"])

        disclosure.performClick(nil)
        sidebar.layoutSubtreeIfNeeded()

        #expect(depthBadgeTexts(in: sidebar).sorted() == ["Z0/1", "Z1/1", "Z1/1"])
    }

    private func depthBadgeTexts(in view: NSView) -> [String] {
        descendants(of: view, as: NSTextField.self)
            .filter { $0.identifier?.rawValue == "pane-depth-badge" }
            .map(\.stringValue)
    }

    private func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        view.subviews.flatMap { subview in
            let current = (subview as? T).map { [$0] } ?? []
            return current + descendants(of: subview, as: type)
        }
    }
}
