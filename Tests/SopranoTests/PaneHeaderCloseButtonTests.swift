import AppKit
import Testing
@testable import Soprano

@MainActor
struct PaneHeaderCloseButtonTests {
    @Test func closingOnePaneOfASplitTabKeepsItsSiblingAndOnlyTheLastPaneClosesTheTab() throws {
        let manager = AgentManager()
        let rootPaneId = manager.activePaneId
        _ = try #require(manager.createLayoutTab())
        let firstInnerPaneId = manager.activePaneId
        let secondInnerPaneId = try #require(
            manager.splitPane(direction: .horizontal, paneId: firstInnerPaneId)
        )
        let themeManager = ThemeManager(themeId: "gruvbox-dark")

        try clickClose(on: secondInnerPaneId, manager: manager, themeManager: themeManager)

        #expect(manager.panes[secondInnerPaneId] == nil)
        #expect(manager.panes[firstInnerPaneId] != nil)
        #expect(manager.windows[manager.activeWindowId]?.activeTabIndex == 1)
        #expect(manager.layout?.leafIds == [firstInnerPaneId])

        try clickClose(on: firstInnerPaneId, manager: manager, themeManager: themeManager)

        #expect(manager.panes[firstInnerPaneId] == nil)
        #expect(manager.windows[manager.activeWindowId]?.tabs.count == 1)
        #expect(manager.activePaneId == rootPaneId)
        #expect(manager.layout?.leafIds == [rootPaneId])
    }

    @Test func closingInATabClosesOnlyThePanesActivePaneTab() throws {
        let manager = AgentManager()
        _ = try #require(manager.createLayoutTab())
        let innerPaneId = manager.activePaneId
        let firstTabId = try #require(manager.panes[innerPaneId]?.activeTab?.id)
        _ = try #require(manager.addTabToPane(innerPaneId, type: .terminal))

        try clickClose(
            on: innerPaneId,
            manager: manager,
            themeManager: ThemeManager(themeId: "gruvbox-dark")
        )

        #expect(manager.panes[innerPaneId]?.tabs.map(\.id) == [firstTabId])
        #expect(manager.windows[manager.activeWindowId]?.activeTabIndex == 1)
    }

    @Test func closingAMarkdownPreviewClearsTheEditorsEyeHoverTint() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaneHeaderCloseButtonTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("README.md")
        try Data("# Preview\n".utf8).write(to: fileURL)

        let manager = AgentManager()
        let target = try #require(manager.openEditor(
            fileURL: fileURL,
            preview: false,
            in: manager.activePaneId
        ))
        let themeManager = ThemeManager(themeId: "gruvbox-dark")
        let tree = SplitTreeView(
            agentManager: manager,
            themeManager: themeManager,
            terminalViewFactory: { _, _, _ in NSView() }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = tree
        defer { window.contentView = nil }
        let editor = try #require(descendants(of: tree, as: EditorPaneView.self).first)
        let eye = try #require(descendants(of: editor, as: RetroIconButton.self).first {
            $0.toolTip == "Open Markdown Preview"
        })
        let entered = try #require(NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: .zero,
            modifierFlags: [],
            timestamp: 1,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        ))
        eye.mouseEntered(with: entered)
        #expect(eye.contentTintColor == themeManager.currentTheme.colors.accent)

        eye.performClick(nil)
        #expect(manager.panes[target.paneId]?.activeTab?.isMarkdown == true)
        #expect(editor.window == nil)
        let close = try #require(descendants(of: tree, as: NSButton.self).first {
            $0.identifier?.rawValue == "pane-close-button"
        })
        close.performClick(nil)

        #expect(manager.panes[target.paneId]?.activeTab?.id == target.tabId)
        #expect(descendants(of: tree, as: EditorPaneView.self).first === editor)
        #expect(eye.contentTintColor == themeManager.currentTheme.colors.textMuted)

        eye.mouseEntered(with: entered)
        #expect(eye.contentTintColor == themeManager.currentTheme.colors.accent)
        eye.mouseExited(with: entered)
        #expect(eye.contentTintColor == themeManager.currentTheme.colors.textMuted)
    }

    private func clickClose(
        on paneId: String,
        manager: AgentManager,
        themeManager: ThemeManager
    ) throws {
        let header = PaneHeaderView(
            paneId: paneId,
            agentManager: manager,
            themeManager: themeManager
        )
        let closeButton = try #require(
            descendants(of: header, as: NSButton.self).first {
                $0.identifier?.rawValue == "pane-close-button"
            }
        )
        closeButton.performClick(nil)
    }

    private func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        view.subviews.flatMap { subview in
            let current = (subview as? T).map { [$0] } ?? []
            return current + descendants(of: subview, as: type)
        }
    }
}
