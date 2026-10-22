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

    @Test func theFocusedRowDropsItsPencilTickWhileItsWindowIsNotKey() throws {
        let manager = AgentManager()
        let sidebar = makeSidebar(manager: manager)
        let window = KeyStateWindow()
        window.contentView?.addSubview(sidebar)
        let focusedRow = "sidebar-pane-\(manager.activePaneId)"

        window.changeKeyStatus(to: false)
        #expect(selectedRowIdentifiers(in: sidebar).isEmpty)
        #expect(rowIdentifiers(in: sidebar, style: .selectedUnfocused) == [focusedRow])

        window.changeKeyStatus(to: true)
        #expect(selectedRowIdentifiers(in: sidebar) == [focusedRow])
        #expect(rowIdentifiers(in: sidebar, style: .selectedUnfocused).isEmpty)
    }

    @Test func closeButtonsStayAccessibleButOnlyTakeClicksUnderThePointer() throws {
        let manager = AgentManager()
        let paneId = manager.activePaneId
        _ = try #require(manager.splitPane(direction: .horizontal, paneId: paneId))
        let sidebar = makeSidebar(manager: manager)
        let row = try #require(descendants(of: sidebar, as: NSView.self).first {
            $0.identifier?.rawValue == "sidebar-pane-\(paneId)"
        })
        let close = try #require(descendants(of: row, as: NSButton.self).first {
            $0.accessibilityLabel() == "Close Pane"
        })
        // Faded, not hidden: VoiceOver and Full Keyboard Access still reach it.
        #expect(!close.isHiddenOrHasHiddenAncestor)
        #expect(close.alphaValue == 0)
        let center = row.convert(NSPoint(x: close.frame.midX, y: close.frame.midY), to: row.superview)
        #expect(row.hitTest(center) === row)

        // The list, not the row, tracks the pointer.
        let list = try #require(descendants(of: sidebar, as: NSScrollView.self).first?.documentView)
        let move = try #require(NSEvent.mouseEvent(
            with: .mouseMoved, location: row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
        ))
        list.mouseMoved(with: move)
        #expect(close.alphaValue == 1)
        #expect(row.hitTest(center) === close)

        close.accessibilityPerformPress()
        #expect(manager.panes[paneId] == nil)
    }

    @Test func holdingControlShowsAccentJumpKeycapsAndReleasingItHidesThem() throws {
        let manager = AgentManager()
        _ = try #require(manager.createWindow())
        let sidebar = makeSidebar(manager: manager)
        func visibleCaps() -> [ChromeKeycapView] {
            descendants(of: sidebar, as: ChromeKeycapView.self).filter { !$0.isHiddenOrHasHiddenAncestor }
        }
        #expect(visibleCaps().isEmpty)

        sidebar.setControlKeyHeld(true)
        let caps = visibleCaps()
        #expect(caps.map(\.legend).filter { $0.hasPrefix("⌃") && !$0.hasPrefix("⌃⇧") } == ["⌃1", "⌃2"])
        #expect(caps.allSatisfy { $0.tone == .accent })

        sidebar.setControlKeyHeld(false)
        #expect(visibleCaps().isEmpty)
    }

    @Test func everyPaneRowDownToTheLastWindowShowsItsHintAndATypedLetterNarrowsThem() throws {
        let manager = AgentManager()
        for _ in 0..<29 {
            _ = try #require(manager.createWindow())
        }
        let sidebar = makeSidebar(manager: manager)
        func paneCaps() -> [[String]] {
            descendants(of: sidebar, as: ChromeKeycapGroupView.self)
                .filter { !$0.isHiddenOrHasHiddenAncestor }
                .sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
                .map(\.caps)
        }

        sidebar.setControlKeyHeld(true)
        let caps = paneCaps()
        #expect(caps.count == 30)
        #expect(caps.first == ["⌃⇧B"])
        #expect(caps.last == ["⌃⇧Z", "Q"])

        // After ⌃⇧Z only its panes keep caps, showing the letter left to
        // type, and they stay up once ⌃ is released.
        sidebar.setTypedPaneHint("z")
        sidebar.setControlKeyHeld(false)
        #expect(paneCaps() == ["B", "D", "E", "F", "G", "I", "M", "N", "O", "P", "Q"].map { [$0] })

        sidebar.setTypedPaneHint("")
        #expect(paneCaps().isEmpty)
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

    private func rowIdentifiers(in view: NSView, style: ChromeSelectionPill.Style) -> [String] {
        descendants(of: view, as: ChromeRowBackgroundView.self)
            .filter { $0.style == style }
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

/// A window whose key status the test sets, posting the notifications AppKit
/// would.
@MainActor
private final class KeyStateWindow: NSWindow {
    private var simulatedKeyStatus = false
    override var isKeyWindow: Bool { simulatedKeyStatus }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 800),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
    }

    func changeKeyStatus(to isKey: Bool) {
        simulatedKeyStatus = isKey
        NotificationCenter.default.post(
            name: isKey ? NSWindow.didBecomeKeyNotification : NSWindow.didResignKeyNotification,
            object: self
        )
    }
}
