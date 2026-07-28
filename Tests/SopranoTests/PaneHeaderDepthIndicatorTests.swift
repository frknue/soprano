import AppKit
import Testing
@testable import Soprano

@MainActor
struct PaneHeaderDepthIndicatorTests {
    @Test func paneHeadersNameTheirDepthAndHighlightOnlyTheFocusedPane() throws {
        let manager = AgentManager()
        let outerPaneId = manager.activePaneId
        _ = try #require(manager.goIn(outerPaneId))
        let innerPaneId = manager.activePaneId
        let themeManager = ThemeManager(themeId: "gruvbox-dark")
        let outerHeader = PaneHeaderView(
            paneId: outerPaneId,
            agentManager: manager,
            themeManager: themeManager
        )
        let innerHeader = PaneHeaderView(
            paneId: innerPaneId,
            agentManager: manager,
            themeManager: themeManager
        )
        let outerLabel = try #require(depthLabel(in: outerHeader))
        let innerLabel = try #require(depthLabel(in: innerHeader))

        #expect(outerLabel.stringValue == "DEPTH 0")
        #expect(innerLabel.stringValue == "DEPTH 1")
        #expect(outerLabel.textColor == themeManager.currentTheme.colors.textMuted)
        #expect(innerLabel.textColor == themeManager.currentTheme.colors.accent)
        #expect(
            depthIndicator(in: innerHeader)?.toolTip
                == "Focused pane · Depth layer 1 of 1"
        )

        #expect(manager.goOut(innerPaneId))
        outerHeader.update()
        innerHeader.update()

        #expect(outerLabel.textColor == themeManager.currentTheme.colors.accent)
        #expect(innerLabel.textColor == themeManager.currentTheme.colors.textMuted)
        #expect(
            depthIndicator(in: outerHeader)?.toolTip
                == "Focused pane · Depth layer 0 of 1"
        )
    }

    private func depthLabel(in view: NSView) -> NSTextField? {
        descendants(of: view, as: NSTextField.self).first {
            $0.identifier?.rawValue == "pane-depth-label"
        }
    }

    private func depthIndicator(in view: NSView) -> NSView? {
        descendants(of: view, as: NSView.self).first {
            $0.identifier?.rawValue == "pane-depth-indicator"
        }
    }

    private func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        view.subviews.flatMap { subview in
            let current = (subview as? T).map { [$0] } ?? []
            return current + descendants(of: subview, as: type)
        }
    }
}
