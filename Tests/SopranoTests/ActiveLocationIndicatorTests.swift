import AppKit
import Testing
@testable import Soprano

@MainActor
struct ActiveLocationIndicatorTests {
    @Test func everyThemeTintsSelectionDistinctlyFromItsPanelSurface() {
        // Regression guard: selection highlights used bgRaised, which Gruvbox Dark
        // defines as the same color as bgPanel, so nothing looked selected.
        for theme in AppTheme.allThemes {
            let colors = theme.colors
            #expect(colors.selection.alphaComponent > 0)
            #expect(colors.selection != colors.selectionMuted)
            #expect(colors.raised.contrastRatio(with: colors.bgPanel) > 1.0)
        }
    }

    @Test func paperSelectsWithASiennaWashAndDarkThemesWithANeutralInkFill() {
        let paper = AppTheme.folioPaper.colors
        #expect(paper.selection == paper.accent.withAlphaComponent(0.12))
        for theme in AppTheme.allThemes where theme.appearance == .dark {
            #expect(theme.colors.selection == theme.colors.textPrimary.withAlphaComponent(0.11))
        }
    }

    @Test func attentionTurnsYellowWhenTheAccentIsNearlyBlue() {
        #expect(AppTheme.folioPaper.colors.attention == AppTheme.folioPaper.colors.blue)
        #expect(AppTheme.nord.colors.attention == AppTheme.nord.colors.yellow)
    }

    @Test func onlyTheFocusedPaneRowCarriesTheSelectionPillAndNoRowHasARail() throws {
        let manager = AgentManager()
        let firstWindowId = manager.activeWindowId
        let firstPaneId = manager.activePaneId
        let secondWindowId = try #require(manager.createWindow())
        let sidebar = makeSidebar(manager: manager)
        #expect(manager.activeWindowId == secondWindowId)
        #expect(selectedRowIdentifiers(in: sidebar) == ["sidebar-pane-\(manager.activePaneId)"])
        #expect(descendants(of: sidebar, as: NSView.self).allSatisfy {
            $0.identifier?.rawValue != "sidebar-selection-rail"
        })

        manager.activateWindow(firstWindowId)
        #expect(selectedRowIdentifiers(in: sidebar) == ["sidebar-pane-\(firstPaneId)"])
    }

    @Test func holdingControlShowsAccentJumpKeycapsAndReleasingItHidesThem() throws {
        let manager = AgentManager()
        _ = try #require(manager.createWindow())
        let sidebar = makeSidebar(manager: manager)
        func visibleCaps() -> [ChromeKeycapView] {
            descendants(of: sidebar, as: ChromeKeycapView.self).filter { !$0.isHidden }
        }
        #expect(visibleCaps().isEmpty)

        sidebar.setControlKeyHeld(true)
        let caps = visibleCaps()
        #expect(caps.map(\.legend).filter { $0.hasPrefix("⌃") && !$0.hasPrefix("⌃⇧") } == ["⌃1", "⌃2"])
        #expect(caps.allSatisfy { $0.tone == .accent })

        sidebar.setControlKeyHeld(false)
        #expect(visibleCaps().isEmpty)
    }

    @Test func statusBarNamesTheActiveWindowAndPane() throws {
        let manager = AgentManager()
        manager.renameWindow(manager.activeWindowId, to: "Soprano")
        let paneId = manager.activePaneId
        let tabId = try #require(manager.panes[paneId]?.activeTab?.id)
        manager.renameTab(paneId, tabId: tabId, to: "Claude")

        let statusBar = StatusBarView(
            agentManager: manager,
            themeManager: ThemeManager(themeId: "gruvbox-dark")
        )

        #expect(locationText(in: statusBar) == "Session 1 › Soprano › Claude")
    }

    @Test func statusBarNamesTheActiveTabOnlyForWindowsWithSeveralTabs() throws {
        let manager = AgentManager()
        manager.renameWindow(manager.activeWindowId, to: "Soprano")
        let statusBar = StatusBarView(
            agentManager: manager,
            themeManager: ThemeManager(themeId: "gruvbox-dark")
        )
        #expect(locationText(in: statusBar)?.contains("· Tab") == false)

        _ = try #require(manager.createLayoutTab())
        #expect(locationText(in: statusBar)?.hasSuffix("· Tab 2") == true)

        manager.activatePreviousLayoutTab()
        #expect(locationText(in: statusBar)?.hasSuffix("· Tab 1") == true)

        manager.closeLayoutTab(try #require(manager.windows[manager.activeWindowId]?.tabs.last?.id))
        #expect(locationText(in: statusBar)?.contains("· Tab") == false)
    }

    // MARK: - Helpers

    private func makeSidebar(manager: AgentManager) -> SidebarView {
        let sidebar = SidebarView(
            agentManager: manager,
            sessionManager: SessionManager(agentManager: manager),
            themeManager: ThemeManager(themeId: "gruvbox-dark"),
            gitBranchMonitor: GitBranchMonitor()
        )
        sidebar.frame = NSRect(x: 0, y: 0, width: SidebarWidthStore.left.defaultWidth, height: 800)
        sidebar.layoutSubtreeIfNeeded()
        return sidebar
    }

    /// Rows whose background draws the focused-list pill and pencil tick.
    private func selectedRowIdentifiers(in view: NSView) -> [String] {
        descendants(of: view, as: ChromeRowBackgroundView.self)
            .filter { $0.style == .selected }
            .compactMap { $0.superview?.identifier?.rawValue }
    }

    private func locationText(in view: NSView) -> String? {
        descendants(of: view, as: NSTextField.self)
            .first { $0.identifier?.rawValue == "status-location" }?
            .stringValue
    }

    private func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        view.subviews.flatMap { subview in
            let current = (subview as? T).map { [$0] } ?? []
            return current + descendants(of: subview, as: type)
        }
    }
}
