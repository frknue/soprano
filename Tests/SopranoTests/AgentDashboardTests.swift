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
    }

    @Test func focusingADashboardTargetRevealsItsHiddenDepthBranchAndExactTab() throws {
        let manager = AgentManager()
        let rootPaneId = manager.activePaneId
        _ = try #require(manager.goIn(rootPaneId))
        let innerPaneId = manager.activePaneId
        let agentTabId = try #require(
            manager.addTabToPane(
                innerPaneId,
                type: .agent,
                profileId: "codex"
            )
        )
        #expect(manager.goOut(innerPaneId))
        #expect(manager.layout?.leafIds == [rootPaneId])

        manager.focusTab(paneId: innerPaneId, tabId: agentTabId)

        #expect(manager.activePaneId == innerPaneId)
        #expect(manager.activeDepth == 1)
        #expect(manager.layout?.leafIds == [innerPaneId])
        #expect(manager.panes[innerPaneId]?.activeTab?.id == agentTabId)
    }

    private func entry(
        id: String,
        status: AgentStatus,
        needsAttention: Bool = false
    ) -> AgentDashboardEntry {
        AgentDashboardEntry(
            paneId: "pane-\(id)",
            tabId: id,
            tabTitle: id,
            windowTitle: "Window",
            profileId: "codex",
            profileName: "Codex",
            status: status,
            needsAttention: needsAttention,
            startedAt: nil,
            cwd: nil
        )
    }
}

@MainActor
struct AgentDashboardViewTests {
    @Test func dashboardOpensWithoutResizingTheMainWindowAndShowsLiveCounts() throws {
        let suiteName = "AgentDashboardViewTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let agentManager = AgentManager()
        _ = try #require(agentManager.spawnAgent("codex"))
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
        #expect(agentRow?.frame.width ?? 0 > 800)
        let totalCard = allSubviews(in: contentViewController.view)
            .first {
                $0.identifier?.rawValue == "agent-dashboard-summary-total"
            }
        #expect(totalCard?.frame.width ?? 0 > 200)
        #expect(totalCard?.frame.height == 92)

        let paneId = try #require(
            agentManager.agentDashboardSnapshot().entries.first?.paneId
        )
        let tabId = try #require(
            agentManager.agentDashboardSnapshot().entries.first?.tabId
        )
        agentManager.updateAgentStatus(
            paneId: paneId,
            tabId: tabId,
            status: .waiting
        )
        contentViewController.view.layoutSubtreeIfNeeded()
        let needsInputCardLabels = allSubviews(in: contentViewController.view)
            .first {
                $0.identifier?.rawValue == "agent-dashboard-summary-needs-input"
            }?
            .subviews
            .compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(needsInputCardLabels?.contains("1") == true)

        let dashboardRoot = try #require(
            allSubviews(in: contentViewController.view)
                .first { $0.identifier?.rawValue == "agent-dashboard" }
        )
        let escape = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        ))

        #expect(dashboardRoot.performKeyEquivalent(with: escape))

        #expect(window.frame == originalFrame)
        #expect(labels(in: contentViewController.view).contains("Agent Dashboard") == false)
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
}
