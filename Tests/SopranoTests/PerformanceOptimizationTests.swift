import AppKit
import Testing
@testable import Soprano

struct PerformanceOptimizationTests {
    @Test func tabMetadataChangesTellObserversExactlyWhichTargetChanged() throws {
        let manager = AgentManager()
        let paneId = manager.activePaneId
        let terminalTabId = try #require(manager.panes[paneId]?.activeTab?.id)
        var changes: [AgentManagerChange] = []
        manager.addObserver(id: "metadata-change-test") { change in
            changes.append(change)
        }
        defer {
            manager.removeObserver(id: "metadata-change-test")
        }

        manager.renameTab(paneId, tabId: terminalTabId, to: "Live title")
        manager.updateWorkingDirectory(
            paneId: paneId,
            tabId: terminalTabId,
            to: "/tmp/live-project"
        )

        #expect(changes == [
            .tabTitle(TerminalTarget(paneId: paneId, tabId: terminalTabId)),
            .tabWorkingDirectory(TerminalTarget(paneId: paneId, tabId: terminalTabId)),
        ])

        let browserTabId = try #require(
            manager.addTabToPane(paneId, type: .browser)
        )
        changes.removeAll()
        manager.updateBrowserURL(
            paneId: paneId,
            tabId: browserTabId,
            to: "https://example.com/updated"
        )

        #expect(changes == [
            .browserURL(TerminalTarget(paneId: paneId, tabId: browserTabId)),
        ])
    }

    @Test @MainActor
    func tabMetadataUpdatesKeepTheExistingSidebarRowAndRefreshItsTitle() throws {
        let manager = AgentManager()
        let paneId = manager.activePaneId
        let tabId = try #require(manager.panes[paneId]?.activeTab?.id)
        let sidebar = SidebarView(
            agentManager: manager,
            sessionManager: SessionManager(agentManager: manager),
            themeManager: ThemeManager(themeId: "gruvbox-dark"),
            gitBranchMonitor: GitBranchMonitor()
        )
        sidebar.frame = NSRect(
            x: 0,
            y: 0,
            width: SidebarWidthStore.defaultWidth,
            height: 600
        )
        sidebar.layoutSubtreeIfNeeded()

        let rowIdentifier = "sidebar-pane-\(paneId)"
        let originalRow = try #require(descendant(
            in: sidebar,
            identifiedBy: rowIdentifier
        ))

        manager.renameTab(paneId, tabId: tabId, to: "Live title")
        manager.updateWorkingDirectory(
            paneId: paneId,
            tabId: tabId,
            to: "/tmp/live-project"
        )

        let updatedRow = try #require(descendant(
            in: sidebar,
            identifiedBy: rowIdentifier
        ))
        #expect(updatedRow === originalRow)
        #expect(
            descendants(of: updatedRow, as: NSTextField.self)
                .contains { $0.stringValue == "Live title" }
        )
    }

    @Test @MainActor
    func terminalRenderingRequiresAnAttachedVisibleUnhiddenWindow() {
        #expect(TerminalSurfaceView.shouldRenderSurface(
            isAttachedToWindow: true,
            windowIsVisible: true,
            isHiddenOrHasHiddenAncestor: false
        ))
        #expect(!TerminalSurfaceView.shouldRenderSurface(
            isAttachedToWindow: false,
            windowIsVisible: true,
            isHiddenOrHasHiddenAncestor: false
        ))
        #expect(!TerminalSurfaceView.shouldRenderSurface(
            isAttachedToWindow: true,
            windowIsVisible: false,
            isHiddenOrHasHiddenAncestor: false
        ))
        #expect(!TerminalSurfaceView.shouldRenderSurface(
            isAttachedToWindow: true,
            windowIsVisible: true,
            isHiddenOrHasHiddenAncestor: true
        ))
    }

    @MainActor
    private func descendant(
        in view: NSView,
        identifiedBy identifier: String
    ) -> NSView? {
        if view.identifier?.rawValue == identifier {
            return view
        }
        for subview in view.subviews {
            if let match = descendant(in: subview, identifiedBy: identifier) {
                return match
            }
        }
        return nil
    }

    @MainActor
    private func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        view.subviews.flatMap { subview in
            let current = (subview as? T).map { [$0] } ?? []
            return current + descendants(of: subview, as: type)
        }
    }
}
