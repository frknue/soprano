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

    @Test func eachPaneTabRevealsItsOwnCloseButtonOnHoverAndClosesOnlyItself() throws {
        let manager = AgentManager()
        let paneId = manager.activePaneId
        let firstTabId = try #require(manager.panes[paneId]?.activeTab?.id)
        let secondTabId = try #require(manager.addTabToPane(paneId, type: .terminal))
        let header = PaneHeaderView(
            paneId: paneId,
            agentManager: manager,
            themeManager: ThemeManager(themeId: "gruvbox-dark")
        )

        let buttons = descendants(of: header, as: NSButton.self)
        let firstTab = try #require(buttons.first {
            $0.identifier?.rawValue == "pane-tab-\(firstTabId)"
        })
        let firstClose = try #require(buttons.first {
            $0.identifier?.rawValue == "close-pane-tab-\(firstTabId)"
        })
        let activeClose = try #require(buttons.first {
            $0.identifier?.rawValue == "close-pane-tab-\(secondTabId)"
        })
        #expect(!activeClose.isHidden)
        #expect(firstClose.isHidden)

        let entered = try #require(NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: .zero,
            modifierFlags: [],
            timestamp: 1,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        ))
        firstTab.mouseEntered(with: entered)
        #expect(!firstClose.isHidden)
        firstTab.mouseExited(with: entered)
        #expect(firstClose.isHidden)

        firstClose.performClick(nil)

        #expect(manager.panes[paneId]?.tabs.map(\.id) == [secondTabId])
        #expect(manager.panes[paneId]?.activeTab?.id == secondTabId)
    }

    @Test func clickingAnInactivePaneTabSwitchesThePaneToThatTab() throws {
        let manager = AgentManager()
        let paneId = manager.activePaneId
        let firstTabId = try #require(manager.panes[paneId]?.activeTab?.id)
        _ = try #require(manager.addTabToPane(paneId, type: .terminal))
        let header = PaneHeaderView(
            paneId: paneId,
            agentManager: manager,
            themeManager: ThemeManager(themeId: "gruvbox-dark")
        )
        let firstTab = try #require(descendants(of: header, as: NSButton.self).first {
            $0.identifier?.rawValue == "pane-tab-\(firstTabId)"
        })

        firstTab.performClick(nil)

        #expect(manager.panes[paneId]?.activeTab?.id == firstTabId)
    }

    @Test func thePlusMenuOpensTerminalsBrowsersAgentsAndChatsAsTabsOfThatSplitOnlyUntilItIsFull() throws {
        let manager = AgentManager()
        let leftPaneId = manager.activePaneId
        let rightPaneId = try #require(manager.splitPane(direction: .horizontal, paneId: leftPaneId))
        manager.focusPane(leftPaneId)
        let header = PaneHeaderView(
            paneId: rightPaneId,
            agentManager: manager,
            themeManager: ThemeManager(themeId: "gruvbox-dark")
        )
        let addButton = try #require(descendants(of: header, as: NSButton.self).first {
            $0.identifier?.rawValue == "pane-add-tab-button"
        })
        let chatProfileId = try #require(AgentChatLaunch.chatProfiles.first?.id)
        func choose(_ id: String) throws {
            let menu = header.addTabMenu()
            let index = menu.items.firstIndex { $0.identifier?.rawValue == "pane-add-tab-\(id)" }
            menu.performActionForItem(at: try #require(index, "no \(id) item"))
            header.update()
        }

        try choose("terminal")
        #expect(manager.activePaneId == rightPaneId)
        try choose("browser")
        try choose("agent-claude-code")
        try choose("chat-\(chatProfileId)")

        let right = try #require(manager.panes[rightPaneId])
        let added = right.tabs.dropFirst()
        #expect(added.map(\.type) == [.terminal, .browser, .agent, .agent])
        #expect(added.map(\.isWebBrowser) == [false, true, false, false])
        #expect(added.map { $0.agent?.profileId } == [nil, nil, "claude-code", chatProfileId])
        #expect(added.map(\.isChat) == [false, false, false, true])
        #expect(right.activeTab?.id == added.last?.id)
        #expect(manager.panes[leftPaneId]?.tabs.count == 1)
        // The menu's Markdown item asks for a file, then opens it here.
        #expect(header.addTabMenu().items.contains { $0.identifier?.rawValue == "pane-add-tab-markdown" })
        let readme = FileManager.default.temporaryDirectory.appendingPathComponent("pane-tab-\(UUID().uuidString).md")
        try "# Notes".write(to: readme, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: readme) }
        let reader = try #require(manager.openMarkdown(fileURL: readme, in: rightPaneId))
        #expect(reader.paneId == rightPaneId)
        #expect(right.activeTab?.isMarkdown == true)
        header.update()

        while right.tabs.count < PaneState.maxTabsPerPane {
            try choose("terminal")
        }
        #expect(!addButton.isEnabled)
    }

    @Test func crowdedTabsWithUnequalTitlesKeepTheirCloseButtonsTheHeaderButtonsAndTheActiveTabInView() throws {
        let manager = AgentManager()
        let paneId = manager.activePaneId
        let pane = try #require(manager.panes[paneId])
        for _ in 1..<PaneState.maxTabsPerPane {
            _ = try #require(manager.addTabToPane(paneId, type: .terminal))
        }
        for index in pane.tabs.indices {
            pane.tabs[index].title = index == 3
                ? "a-markdown-file-with-a-very-long-name-that-keeps-going-and-going.md"
                : String(UnicodeScalar(UInt8(97 + index)))
        }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: PaneHeaderView.height))
        let header = PaneHeaderView(
            paneId: paneId,
            agentManager: manager,
            themeManager: ThemeManager(themeId: "gruvbox-dark")
        )
        header.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            header.topAnchor.constraint(equalTo: host.topAnchor),
            header.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            host.widthAnchor.constraint(equalToConstant: 360),
            host.heightAnchor.constraint(equalToConstant: PaneHeaderView.height),
        ])
        header.update()
        host.layoutSubtreeIfNeeded()

        let buttons = descendants(of: header, as: NSButton.self)
        for tab in pane.tabs {
            let tabButton = try #require(buttons.first { $0.identifier?.rawValue == "pane-tab-\(tab.id)" })
            let close = try #require(buttons.first { $0.identifier?.rawValue == "close-pane-tab-\(tab.id)" })
            #expect(tabButton.bounds.contains(close.frame), "close of \(tab.title) leaves its tab")
            #expect(close.frame.minX >= 8 + 14, "\(tab.title) leaves no room for its title")
        }
        for identifier in ["pane-add-tab-button", "pane-close-button"] {
            let button = try #require(buttons.first { $0.identifier?.rawValue == identifier })
            let center = NSPoint(x: button.frame.midX, y: button.frame.midY)
            #expect(header.hitTest(header.convert(center, to: host)) === button, "\(identifier) is covered")
        }

        // The last tab, added last, is active; walking back across every tab
        // and forward again crosses the overflow edge both ways.
        func expectActiveTabFullyVisible() throws {
            header.update()
            host.layoutSubtreeIfNeeded()
            let activeId = try #require(pane.activeTab?.id)
            let active = try #require(buttons.first { $0.identifier?.rawValue == "pane-tab-\(activeId)" })
            let clip = try #require(descendants(of: header, as: NSScrollView.self).first?.contentView)
            #expect(
                clip.bounds.contains(active.convert(active.bounds, to: clip)),
                "\(pane.tabs[pane.activeTabIndex].title) is scrolled out of view"
            )
        }
        #expect(pane.activeTabIndex == PaneState.maxTabsPerPane - 1)
        try expectActiveTabFullyVisible()
        for _ in 1..<PaneState.maxTabsPerPane {
            manager.prevTab(paneId)
            try expectActiveTabFullyVisible()
        }
        #expect(pane.activeTabIndex == 0)
        manager.prevTab(paneId)
        try expectActiveTabFullyVisible()
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
        let eye = try #require(descendants(of: editor, as: ShellGhostButton.self).first {
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
        let palette = PaletteCenter.shared.palette
        #expect(eye.contentTintColor == palette.foreground)

        eye.performClick(nil)
        #expect(manager.panes[target.paneId]?.activeTab?.isMarkdown == true)
        #expect(editor.window == nil)
        let close = try #require(descendants(of: tree, as: NSButton.self).first {
            $0.identifier?.rawValue == "pane-close-button"
        })
        close.performClick(nil)

        #expect(manager.panes[target.paneId]?.activeTab?.id == target.tabId)
        #expect(descendants(of: tree, as: EditorPaneView.self).first === editor)
        #expect(eye.contentTintColor == palette.mutedForeground)

        eye.mouseEntered(with: entered)
        #expect(eye.contentTintColor == palette.foreground)
        eye.mouseExited(with: entered)
        #expect(eye.contentTintColor == palette.mutedForeground)
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
