import AppKit
import Testing
@testable import Soprano

struct AgentDashboardSnapshotTests {
    @Test func snapshotCountsCurrentStatesAndOrdersAgentsByUrgency() {
        let entries = [
            entry(id: "running", status: .running),
            entry(id: "idle", status: .idle),
            entry(id: "error", status: .error),
            entry(id: "waiting", status: .waiting),
            entry(id: "attention", status: .idle, needsAttention: true),
            entry(id: "starting", status: .starting),
            entry(id: "stopped", status: .stopped),
        ]

        let snapshot = AgentDashboardSnapshot(entries: entries)

        #expect(snapshot.totalCount == 7)
        #expect(snapshot.workingCount == 2)
        #expect(snapshot.needsInputCount == 1)
        #expect(snapshot.errorCount == 1)
        #expect(snapshot.entries.map(\.tabId) == [
            "attention",
            "waiting",
            "error",
            "running",
            "starting",
            "idle",
            "stopped",
        ])
    }

    @Test func sectionsGroupAgentsThatNeedYouAheadOfWorkingReadyAndStoppedOnes() {
        let snapshot = AgentDashboardSnapshot(entries: [
            entry(id: "running", status: .running),
            entry(id: "idle", status: .idle),
            entry(id: "error", status: .error),
            entry(id: "stopped", status: .stopped),
            entry(id: "attention", status: .idle, needsAttention: true),
            entry(id: "starting", status: .starting),
            entry(id: "waiting", status: .waiting),
        ])

        let sections = AgentDashboardSection.group(snapshot.entries)

        #expect(sections.map(\.section) == [.needsYou, .working, .ready, .stopped])
        #expect(sections.map { $0.entries.map(\.tabId) } == [
            ["attention", "waiting", "error"],
            ["running", "starting"],
            ["idle"],
            ["stopped"],
        ])
        #expect(AgentDashboardSection.group([entry(id: "idle", status: .idle)]).map(\.section) == [.ready])
    }

    @Test func managerSnapshotIncludesAgentTabsAcrossLogicalWindows() throws {
        let manager = AgentManager()
        let codexPaneId = try #require(manager.spawnAgent("codex", cwd: "/tmp/one"))
        let codexTabId = try #require(manager.panes[codexPaneId]?.activeTab?.id)
        manager.updateAgentStatus(
            paneId: codexPaneId,
            tabId: codexTabId,
            status: .running
        )

        let secondWindowId = try #require(manager.createWindow(cwd: "/tmp/two"))
        let claudePaneId = try #require(manager.spawnAgent("claude-code"))
        let claudeTabId = try #require(manager.panes[claudePaneId]?.activeTab?.id)
        manager.updateAgentStatus(
            paneId: claudePaneId,
            tabId: claudeTabId,
            status: .waiting,
            needsAttention: true
        )

        let snapshot = manager.agentDashboardSnapshot()

        #expect(snapshot.totalCount == 2)
        #expect(snapshot.entries.map(\.profileId) == ["claude-code", "codex"])
        #expect(snapshot.entries[0].windowTitle == manager.windows[secondWindowId]?.title)
        #expect(snapshot.entries[0].cwd == "/tmp/two")
        #expect(snapshot.entries[1].cwd == "/tmp/one")
        #expect(snapshot.entries.map(\.title) == ["Claude Code", "Codex"])
        #expect(snapshot.entries.map(\.context) == [
            PaneContextLine(context: ["two"]),
            PaneContextLine(context: ["one"]),
        ])

        manager.renameWindow(secondWindowId, to: "Storefront")
        manager.updateWorkingDirectory(paneId: claudePaneId, tabId: claudeTabId, to: "/tmp/two/src")
        let renamed = manager.agentDashboardSnapshot().entries[0]
        #expect(renamed.windowTitle == "Storefront")
        #expect(renamed.context == PaneContextLine(context: ["src"]))
    }

    @Test func anAgentIsNamedByItsTaskOverItsNameFolderAndBranch() {
        var working = entry(id: "omp", status: .running, tabTitle: "π ⠋ \u{F04E1} MIGR: Plan the migration", cwd: "/tmp/ab_tool")
        working.branch = "feat/migration"
        #expect(working.title == "MIGR: Plan the migration")
        #expect(working.context == PaneContextLine(context: ["Codex", "ab_tool"], branch: "feat/migration"))
        #expect(working.location == "Window ▸ MIGR: Plan the migration")

        let fresh = entry(id: "codex", status: .idle, tabTitle: "Codex: ab_tool", cwd: "/tmp/ab_tool")
        #expect(fresh.title == "Codex")
        #expect(fresh.context == PaneContextLine(context: ["ab_tool"]))
    }

    @Test func focusingADashboardTargetShowsItsBackgroundTabAndExactPaneTab() throws {
        let manager = AgentManager()
        let rootPaneId = manager.activePaneId
        _ = try #require(manager.createLayoutTab())
        let agentPaneId = manager.activePaneId
        let agentTabId = try #require(
            manager.addTabToPane(
                agentPaneId,
                type: .agent,
                profileId: "codex"
            )
        )
        manager.switchTab(agentPaneId, index: 0)
        manager.activatePreviousLayoutTab()
        #expect(manager.layout?.leafIds == [rootPaneId])

        manager.focusTab(paneId: agentPaneId, tabId: agentTabId)

        #expect(manager.activePaneId == agentPaneId)
        #expect(manager.windows[manager.activeWindowId]?.activeTabIndex == 1)
        #expect(manager.layout?.leafIds == [agentPaneId])
        #expect(manager.panes[agentPaneId]?.activeTab?.id == agentTabId)
    }

    private func entry(
        id: String,
        status: AgentStatus,
        needsAttention: Bool = false,
        tabTitle: String? = nil,
        cwd: String? = nil
    ) -> AgentDashboardEntry {
        AgentDashboardEntry(
            paneId: "pane-\(id)",
            tabId: id,
            tabTitle: tabTitle ?? id,
            windowTitle: "Window",
            profileId: "codex",
            profileName: "Codex",
            status: status,
            needsAttention: needsAttention,
            startedAt: nil,
            cwd: cwd
        )
    }
}

@MainActor
struct AgentDashboardViewTests {
    @Test func rowsShowTheTaskOverTheAgentAndFolderAndFollowRenamesAndDirectoryChanges() throws {
        let manager = AgentManager()
        let paneId = try #require(manager.spawnAgent("codex", cwd: "/tmp/projects/storefront"))
        let tabId = try #require(manager.panes[paneId]?.activeTab?.id)
        manager.updateAgentStatus(paneId: paneId, tabId: tabId, status: .waiting)
        let controller = AgentDashboardViewController(
            agentManager: manager,
            themeManager: ThemeManager(themeId: "gruvbox-dark"),
            branchProvider: { $0 == "/tmp/projects/payments" ? "feat/refunds" : nil }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 700),
            styleMask: [.titled, .resizable],
            backing: .buffered, defer: false
        )
        window.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()

        let row = try #require(allSubviews(in: controller.view).first {
            $0.identifier?.rawValue == "agent-dashboard-row"
        })
        let fields = allSubviews(in: row).compactMap { $0 as? NSTextField }
        let title = try #require(fields.first { $0.identifier?.rawValue == "agent-dashboard-title" })
        let context = try #require(fields.first { $0.identifier?.rawValue == "agent-dashboard-activity" })
        let status = try #require(fields.first { $0.identifier?.rawValue == "agent-dashboard-status" })
        #expect(row.frame.height == 52)
        // Before Codex titles itself, it goes by its name over its folder.
        #expect(title.stringValue == "Codex")
        #expect(context.stringValue == "storefront")
        #expect(status.stringValue == "NEEDS INPUT")
        #expect(title.frame.minY > context.frame.maxY)
        #expect(title.frame.maxX < status.frame.minX)
        #expect(fields.allSatisfy { row.bounds.contains($0.frame) })
        #expect(row.toolTip?.contains("/tmp/projects/storefront") == true)
        #expect(row.accessibilityLabel()?.hasPrefix("Codex, Codex") == true)

        manager.renameTab(paneId, tabId: tabId, to: "⠙ Fix the checkout total")
        manager.updateWorkingDirectory(paneId: paneId, tabId: tabId, to: "/tmp/projects/payments")
        manager.renameWindow(manager.activeWindowId, to: "Payments App")
        let titles = allSubviews(in: controller.view).compactMap { view -> String? in
            guard let label = view as? NSTextField,
                  ["agent-dashboard-title", "agent-dashboard-detail-title"].contains(label.identifier?.rawValue)
            else { return nil }
            return label.stringValue
        }
        #expect(titles == ["Fix the checkout total", "Fix the checkout total"])
        // The branch glyph is an attachment character before the name.
        #expect(context.stringValue.hasPrefix("Codex · payments · "))
        #expect(context.stringValue.hasSuffix(" feat/refunds"))
        let location = try #require(allSubviews(in: controller.view).compactMap { $0 as? NSTextField }.first {
            $0.identifier?.rawValue == "agent-dashboard-detail-location"
        })
        #expect(location.stringValue.hasPrefix("Payments App ▸ Codex · payments · "))
    }

    @Test func dashboardOpensWithoutResizingTheMainWindowAndShowsLiveCounts() throws {
        let suiteName = "AgentDashboardViewTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let agentManager = AgentManager()
        let paneId = try #require(agentManager.spawnAgent("codex"))
        let tabId = try #require(agentManager.panes[paneId]?.activeTab?.id)
        agentManager.updateAgentStatus(
            paneId: paneId,
            tabId: tabId,
            status: .running
        )
        var submittedPrompts: [String] = []
        let contentViewController = MainContentViewController(
            agentManager: agentManager,
            sessionManager: SessionManager(
                agentManager: agentManager,
                defaults: defaults
            ),
            themeManager: ThemeManager(themeId: "gruvbox-dark"),
            gitBranchMonitor: GitBranchMonitor(),
            defaults: defaults,
            splitTreeViewFactory: { agentManager, themeManager in
                SplitTreeView(
                    agentManager: agentManager,
                    themeManager: themeManager,
                    terminalViewFactory: { _, _, _ in NSView() },
                    terminalViewHasLiveSurface: { _ in true },
                    terminalVisibleText: { _ in "Codex is ready for your reply." },
                    terminalPromptSubmitter: { _, prompt in
                        submittedPrompts.append(prompt)
                        return true
                    }
                )
            }
        )
        let originalFrame = NSRect(x: 160, y: 120, width: 1200, height: 760)
        let window = NSWindow(
            contentRect: originalFrame,
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = contentViewController
        window.setFrame(originalFrame, display: false)

        contentViewController.showDashboard()
        contentViewController.view.layoutSubtreeIfNeeded()

        #expect(window.frame == originalFrame)
        #expect(labels(in: contentViewController.view).contains("Agent Dashboard"))
        #expect(labels(in: contentViewController.view).contains("Monitoring 1 agent across 1 window"))
        let agentRow = allSubviews(in: contentViewController.view)
            .first { $0.identifier?.rawValue == "agent-dashboard-row" }
        #expect(agentRow?.frame.width ?? 0 > 300)
        let detail = allSubviews(in: contentViewController.view)
            .first { $0.identifier?.rawValue == "agent-dashboard-detail" }
        #expect(detail?.frame.width ?? 0 > 500)
        let dashboard = try #require(allSubviews(in: contentViewController.view)
            .first { $0.identifier?.rawValue == "agent-dashboard" })
        let header = try #require(allSubviews(in: dashboard).compactMap { $0 as? SettingsHeaderView }.first)
        #expect(header.frame.height == SettingsHeaderView.height)
        #expect(header.frame.maxY == dashboard.bounds.maxY)
        #expect(header.displayedSubtitle == "Monitoring 1 agent across 1 window")
        #expect(sectionHeadings(in: dashboard) == ["WORKING 1"])

        let terminalScrollView = try #require(
            allSubviews(in: contentViewController.view)
                .compactMap { $0 as? NSScrollView }
                .first {
                    $0.identifier?.rawValue == "agent-dashboard-terminal"
                }
        )
        let terminalText = try #require(
            terminalScrollView.documentView as? NSTextView
        )
        #expect(terminalText.string == "Codex is ready for your reply.")
        let readyRange = (terminalText.string as NSString).range(of: "ready")
        let readyColor = terminalText.textStorage?.attribute(
            .foregroundColor,
            at: readyRange.location,
            effectiveRange: nil
        ) as? NSColor
        let expectedTheme = ThemeManager(themeId: "gruvbox-dark").currentTheme
        #expect(terminalText.isRichText)
        #expect(readyColor?.isEqual(expectedTheme.colors.success) == true)

        let replyField = try #require(
            allSubviews(in: contentViewController.view)
                .compactMap { $0 as? NSTextField }
                .first {
                    $0.identifier?.rawValue == "agent-dashboard-reply"
                }
        )
        #expect(replyField.isEnabled)
        replyField.stringValue = "Run the focused tests"
        _ = NSApp.sendAction(
            try #require(replyField.action),
            to: replyField.target,
            from: replyField
        )
        #expect(submittedPrompts == ["Run the focused tests"])
        #expect(
            agentManager.agent(paneId: paneId, tabId: tabId)?.status == .running
        )
        #expect(replyField.stringValue.isEmpty)

        let stopButton = try #require(
            allSubviews(in: contentViewController.view)
                .compactMap { $0 as? NSButton }
                .first {
                    $0.identifier?.rawValue == "agent-dashboard-stop"
                }
        )
        stopButton.performClick(nil)
        #expect(
            agentManager.agent(paneId: paneId, tabId: tabId)?.status == .stopped
        )
        #expect(sectionHeadings(in: dashboard) == ["STOPPED 1"])

        let restartButton = try #require(
            allSubviews(in: contentViewController.view)
                .compactMap { $0 as? NSButton }
                .first {
                    $0.identifier?.rawValue == "agent-dashboard-restart"
                }
        )
        restartButton.performClick(nil)
        #expect(
            agentManager.agent(paneId: paneId, tabId: tabId)?.status == .starting
        )

        #expect(sectionHeadings(in: dashboard) == ["WORKING 1"])

        let dashboardRoot = try #require(
            allSubviews(in: contentViewController.view)
                .first { $0.identifier?.rawValue == "agent-dashboard" }
        )
        let escape = try #require(keyEvent(
            character: "\u{1b}",
            keyCode: 53,
            window: window
        ))

        #expect(dashboardRoot.performKeyEquivalent(with: escape))

        #expect(window.frame == originalFrame)
        #expect(labels(in: contentViewController.view).contains("Agent Dashboard") == false)
    }

    @Test func jAndKMoveTheSelectionAndReturnFocusesTheChosenAgent() throws {
        let suiteName = "AgentDashboardKeyboardTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let agentManager = AgentManager()
        let codexPaneId = try #require(agentManager.spawnAgent("codex"))
        let claudePaneId = try #require(agentManager.spawnAgent("claude-code"))
        agentManager.focusPane("pane-1")
        let contentViewController = MainContentViewController(
            agentManager: agentManager,
            sessionManager: SessionManager(
                agentManager: agentManager,
                defaults: defaults
            ),
            themeManager: ThemeManager(themeId: "gruvbox-dark"),
            gitBranchMonitor: GitBranchMonitor(),
            defaults: defaults,
            splitTreeViewFactory: { agentManager, themeManager in
                SplitTreeView(
                    agentManager: agentManager,
                    themeManager: themeManager,
                    terminalViewFactory: { _, _, _ in NSView() }
                )
            }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1_100, height: 720),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = contentViewController
        contentViewController.showDashboard()
        contentViewController.view.layoutSubtreeIfNeeded()

        let dashboardRoot = try #require(
            allSubviews(in: contentViewController.view)
                .first { $0.identifier?.rawValue == "agent-dashboard" }
        )
        let rows = allSubviews(in: contentViewController.view)
            .filter { $0.identifier?.rawValue == "agent-dashboard-row" }
        #expect(rows.count == 2)
        #expect(rows.map { $0.isAccessibilitySelected() } == [true, false])

        let j = try #require(keyEvent(character: "j", keyCode: 38, window: window))
        #expect(dashboardRoot.performKeyEquivalent(with: j))
        #expect(rows.map { $0.isAccessibilitySelected() } == [false, true])

        let k = try #require(keyEvent(character: "k", keyCode: 40, window: window))
        #expect(dashboardRoot.performKeyEquivalent(with: k))
        #expect(rows.map { $0.isAccessibilitySelected() } == [true, false])

        #expect(dashboardRoot.performKeyEquivalent(with: j))
        let enter = try #require(keyEvent(character: "\r", keyCode: 36, window: window))
        #expect(dashboardRoot.performKeyEquivalent(with: enter))

        #expect(agentManager.activePaneId == claudePaneId)
        #expect(agentManager.activePaneId != codexPaneId)
        #expect(labels(in: contentViewController.view).contains("Agent Dashboard") == false)
    }

    @Test func jFromTheDetailTextMovesTheSelectionAndGivesTheListKeyboardFocus() throws {
        let suiteName = "AgentDashboardListFocusTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let agentManager = AgentManager()
        _ = try #require(agentManager.spawnAgent("codex"))
        _ = try #require(agentManager.spawnAgent("claude-code"))
        let contentViewController = MainContentViewController(
            agentManager: agentManager,
            sessionManager: SessionManager(
                agentManager: agentManager,
                defaults: defaults
            ),
            themeManager: ThemeManager(themeId: "gruvbox-dark"),
            gitBranchMonitor: GitBranchMonitor(),
            defaults: defaults,
            splitTreeViewFactory: { agentManager, themeManager in
                SplitTreeView(
                    agentManager: agentManager,
                    themeManager: themeManager,
                    terminalViewFactory: { _, _, _ in NSView() }
                )
            }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1_100, height: 720),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = contentViewController
        contentViewController.showDashboard()
        contentViewController.view.layoutSubtreeIfNeeded()

        let dashboardRoot = try #require(
            allSubviews(in: contentViewController.view)
                .first { $0.identifier?.rawValue == "agent-dashboard" }
        )
        let rows = allSubviews(in: contentViewController.view)
            .filter { $0.identifier?.rawValue == "agent-dashboard-row" }
        let detailText = try #require(
            allSubviews(in: dashboardRoot)
                .compactMap { $0 as? NSTextView }
                .first { !$0.isFieldEditor && $0.acceptsFirstResponder }
        )
        #expect(window.makeFirstResponder(detailText))
        #expect(window.firstResponder === detailText)

        let j = try #require(keyEvent(character: "j", keyCode: 38, window: window))
        detailText.keyDown(with: j)

        #expect(rows.map { $0.isAccessibilitySelected() } == [false, true])
        #expect(window.firstResponder === dashboardRoot)
    }

    @Test func tabMovesIntoTheReplyFieldAndShiftTabReturnsToTheAgentListKeepingTheDraft() throws {
        let suiteName = "AgentDashboardReplyFocusTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let agentManager = AgentManager()
        let paneId = try #require(agentManager.spawnAgent("codex"))
        let tabId = try #require(agentManager.panes[paneId]?.activeTab?.id)
        agentManager.updateAgentStatus(paneId: paneId, tabId: tabId, status: .waiting)
        let contentViewController = MainContentViewController(
            agentManager: agentManager,
            sessionManager: SessionManager(agentManager: agentManager, defaults: defaults),
            themeManager: ThemeManager(themeId: "gruvbox-dark"),
            gitBranchMonitor: GitBranchMonitor(),
            defaults: defaults,
            splitTreeViewFactory: { agentManager, themeManager in
                SplitTreeView(
                    agentManager: agentManager,
                    themeManager: themeManager,
                    terminalViewFactory: { _, _, _ in NSView() },
                    terminalViewHasLiveSurface: { _ in true },
                    terminalVisibleText: { _ in "Codex is waiting." },
                    terminalPromptSubmitter: { _, _ in true }
                )
            }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1_100, height: 720),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = contentViewController
        contentViewController.showDashboard()
        contentViewController.view.layoutSubtreeIfNeeded()

        let dashboardRoot = try #require(
            allSubviews(in: contentViewController.view)
                .first { $0.identifier?.rawValue == "agent-dashboard" }
        )
        let replyField = try #require(
            allSubviews(in: contentViewController.view)
                .compactMap { $0 as? NSTextField }
                .first { $0.identifier?.rawValue == "agent-dashboard-reply" }
        )
        #expect(replyField.isEnabled)
        window.makeFirstResponder(dashboardRoot)

        let tab = try #require(keyEvent(character: "\t", keyCode: 48, window: window))
        window.firstResponder?.keyDown(with: tab)
        let editor = try #require(window.firstResponder as? NSTextView)
        #expect(editor.isFieldEditor)
        #expect(editor.delegate === replyField)

        editor.insertText("Run the tests", replacementRange: editor.selectedRange())
        let shiftTab = try #require(keyEvent(
            character: "\u{19}",
            keyCode: 48,
            modifierFlags: .shift,
            window: window
        ))
        window.firstResponder?.keyDown(with: shiftTab)

        #expect(window.firstResponder === dashboardRoot)
        #expect(replyField.stringValue == "Run the tests")
    }

    @Test func busyAgentTitlesRedrawOnlyTheirOwnRowAndKeepTheListScrollPosition() throws {
        let manager = AgentManager()
        var targets: [TerminalTarget] = []
        for index in 0..<12 {
            let paneId = try #require(manager.spawnAgent("codex", cwd: "/tmp/projects/project-\(index)"))
            let tabId = try #require(manager.panes[paneId]?.activeTab?.id)
            targets.append(TerminalTarget(paneId: paneId, tabId: tabId))
        }
        let (controller, _) = openDashboard(for: manager, height: 600)
        let rows = try arrangedRows(in: controller.view)
        #expect(rows.count == 12)
        let scrollView = try #require(rows.first?.enclosingScrollView)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 300))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        // Busy agents retitle their tabs several times a second.
        for frame in ["✳", "✶", "✻"] {
            manager.renameTab(targets[5].paneId, tabId: targets[5].tabId, to: "\(frame) Running the tests")
            controller.view.layoutSubtreeIfNeeded()
        }

        let rowsAfterTitles = try arrangedRows(in: controller.view)
        #expect(rowsAfterTitles.elementsEqual(rows) { $0 === $1 })
        let busyRow = try #require(rowsAfterTitles.first {
            $0.toolTip?.contains("/tmp/projects/project-5") == true
        })
        #expect(busyRow.toolTip?.hasPrefix("Running the tests\n") == true)
        #expect(scrollView.contentView.bounds.origin.y == 300)
    }

    @Test func statusChangesMoveTheExistingRowsIntoUrgencyOrderAndRefreshTheCounts() throws {
        let manager = AgentManager()
        var targets: [TerminalTarget] = []
        for index in 0..<3 {
            let paneId = try #require(manager.spawnAgent("codex", cwd: "/tmp/projects/project-\(index)"))
            let tabId = try #require(manager.panes[paneId]?.activeTab?.id)
            manager.updateAgentStatus(paneId: paneId, tabId: tabId, status: .running)
            targets.append(TerminalTarget(paneId: paneId, tabId: tabId))
        }
        let (controller, _) = openDashboard(for: manager, height: 700)
        let rows = try arrangedRows(in: controller.view)
        #expect(rows.map(folder(of:)) == ["project-0", "project-1", "project-2"])

        manager.updateAgentStatus(paneId: targets[2].paneId, tabId: targets[2].tabId, status: .waiting)
        _ = try #require(manager.spawnAgent("claude-code", cwd: "/tmp/projects/project-3"))

        let reordered = try arrangedRows(in: controller.view)
        #expect(reordered.map(folder(of:)) == ["project-2", "project-0", "project-1", "project-3"])
        #expect(reordered.prefix(3).elementsEqual([rows[2], rows[0], rows[1]]) { $0 === $1 })
        #expect(sectionHeadings(in: controller.view) == ["NEEDS YOU 1", "WORKING 3"])
    }

    @Test func stopAndRestartStayInTheToolbarAndWorkInTheNarrowestWindow() throws {
        let manager = AgentManager()
        let paneId = try #require(manager.spawnAgent("codex", cwd: "/tmp/projects/storefront"))
        let tabId = try #require(manager.panes[paneId]?.activeTab?.id)
        manager.updateAgentStatus(paneId: paneId, tabId: tabId, status: .running)
        let (controller, window) = openDashboard(
            for: manager,
            width: MainWindowSizing.minimumFrameSize.width,
            height: MainWindowSizing.minimumFrameSize.height
        )
        #expect(controller.view.frame.width == MainWindowSizing.minimumFrameSize.width)

        func button(_ id: String) throws -> NSButton {
            try #require(allSubviews(in: controller.view).compactMap { $0 as? NSButton }.first {
                $0.identifier?.rawValue == id
            })
        }
        let stop = try button("agent-dashboard-stop")
        #expect(stop.window === window)
        #expect(controller.view.bounds.contains(stop.convert(stop.bounds, to: controller.view)))
        stop.performClick(nil)
        #expect(manager.agent(paneId: paneId, tabId: tabId)?.status == .stopped)

        controller.view.layoutSubtreeIfNeeded()
        let restart = try button("agent-dashboard-restart")
        #expect(restart.window === window)
        #expect(controller.view.bounds.contains(restart.convert(restart.bounds, to: controller.view)))
        restart.performClick(nil)
        #expect(manager.agent(paneId: paneId, tabId: tabId)?.status == .starting)
    }

    @Test func aNarrowWindowGivesTheSidebarItsShareAndLaysOutUnambiguously() throws {
        let manager = AgentManager()
        _ = try #require(manager.spawnAgent("codex", cwd: "/tmp/projects/storefront"))
        for (width, sidebar) in [(700.0, 280.0), (1_000.0, 380.0)] {
            let (controller, _) = openDashboard(for: manager, width: width, height: 600)
            let list = try #require(allSubviews(in: controller.view).first {
                $0.identifier?.rawValue == "agent-dashboard-list"
            })
            #expect(abs(list.frame.width - sidebar) < 0.5)
            #expect(allSubviews(in: controller.view).filter(\.hasAmbiguousLayout).isEmpty)
        }
    }

    private func openDashboard(
        for manager: AgentManager,
        width: CGFloat = 900,
        height: CGFloat
    ) -> (AgentDashboardViewController, NSWindow) {
        let controller = AgentDashboardViewController(
            agentManager: manager,
            themeManager: ThemeManager(themeId: "gruvbox-dark")
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.setContentSize(NSSize(width: width, height: height))
        controller.view.layoutSubtreeIfNeeded()
        return (controller, window)
    }

    /// The agent rows in the order the list shows them, without the section
    /// headings between them.
    private func arrangedRows(in view: NSView) throws -> [NSView] {
        let row = try #require(allSubviews(in: view).first {
            $0.identifier?.rawValue == "agent-dashboard-row"
        })
        return try #require(row.superview as? NSStackView).arrangedSubviews.filter {
            $0.identifier?.rawValue == "agent-dashboard-row"
        }
    }

    /// The second line of an agent without a task title or activity: its folder.
    private func folder(of row: NSView) -> String? {
        allSubviews(in: row)
            .compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "agent-dashboard-activity" }?
            .stringValue
    }

    /// The list's section headings in order, as `NEEDS YOU 2`.
    private func sectionHeadings(in view: NSView) -> [String] {
        guard let stack = allSubviews(in: view)
            .first(where: { $0.identifier?.rawValue == "agent-dashboard-section" })?
            .superview as? NSStackView
        else { return [] }
        return stack.arrangedSubviews
            .filter { $0.identifier?.rawValue == "agent-dashboard-section" }
            .map { heading in
                let labels = allSubviews(in: heading).compactMap { $0 as? NSTextField }
                let count = labels.first { $0.identifier?.rawValue == "agent-dashboard-section-count" }
                let title = labels.first { $0 !== count }
                return [title?.stringValue, count?.stringValue].compactMap { $0 }.joined(separator: " ")
            }
    }

    private func labels(in view: NSView) -> [String] {
        view.subviews.flatMap { subview -> [String] in
            let current = (subview as? NSTextField).map { [$0.stringValue] } ?? []
            return current + labels(in: subview)
        }
    }

    private func allSubviews(in view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allSubviews(in:))
    }

    private func keyEvent(
        character: String,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags = [],
        window: NSWindow
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: keyCode
        )
    }
}
