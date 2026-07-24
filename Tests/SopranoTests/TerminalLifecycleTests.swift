import AppKit
import Testing
@testable import Soprano

struct TerminalLifecycleTests {
    @Test func exactStopAndRestartEmitTheirTargetAfterUpdatingOnlyThatAgent() throws {
        let manager = AgentManager()
        let paneId = manager.activePaneId
        let firstTabId = try #require(
            manager.addTabToPane(paneId, type: .agent, profileId: "codex")
        )
        let secondTabId = try #require(
            manager.addTabToPane(paneId, type: .agent, profileId: "claude-code")
        )
        manager.updateAgentStatus(paneId: paneId, tabId: firstTabId, status: .running)
        manager.updateAgentStatus(paneId: paneId, tabId: secondTabId, status: .running)

        var actions: [TerminalLifecycleAction] = []
        var statusWhenDelivered: [AgentStatus] = []
        manager.addTerminalLifecycleObserver(id: "test-spy") { [weak manager] action in
            actions.append(action)
            let target = action.target
            if let status = manager?.agent(paneId: target.paneId, tabId: target.tabId)?.status {
                statusWhenDelivered.append(status)
            }
        }

        let firstTarget = TerminalTarget(paneId: paneId, tabId: firstTabId)
        manager.stopAgent(target: firstTarget)

        #expect(actions == [.stop(firstTarget)])
        #expect(statusWhenDelivered == [.stopped])
        #expect(manager.agent(paneId: paneId, tabId: firstTabId)?.status == .stopped)
        #expect(manager.agent(paneId: paneId, tabId: secondTabId)?.status == .running)

        manager.restartAgent(target: firstTarget)

        #expect(actions == [.stop(firstTarget), .restart(firstTarget)])
        #expect(statusWhenDelivered == [.stopped, .starting])
        #expect(manager.agent(paneId: paneId, tabId: firstTabId)?.status == .starting)
        #expect(manager.agent(paneId: paneId, tabId: firstTabId)?.restartCount == 1)
        #expect(manager.agent(paneId: paneId, tabId: secondTabId)?.status == .running)
    }

    @Test func activeTabConveniencesResolveAndEmitTheExactTarget() throws {
        let manager = AgentManager()
        let paneId = manager.activePaneId
        _ = try #require(manager.addTabToPane(paneId, type: .agent, profileId: "codex"))
        let activeTabId = try #require(
            manager.addTabToPane(paneId, type: .agent, profileId: "claude-code")
        )
        let expectedTarget = TerminalTarget(paneId: paneId, tabId: activeTabId)
        var actions: [TerminalLifecycleAction] = []
        manager.addTerminalLifecycleObserver(id: "test-spy") { actions.append($0) }

        manager.stopAgent(paneId: paneId)
        manager.restartAgent(paneId: paneId)

        #expect(actions == [.stop(expectedTarget), .restart(expectedTarget)])
    }

    @Test func inactiveAgentCloseStopsOnlyTheSuppliedTab() throws {
        let manager = AgentManager()
        let paneId = manager.activePaneId
        let inactiveTabId = try #require(
            manager.addTabToPane(paneId, type: .agent, profileId: "codex")
        )
        let activeTabId = try #require(
            manager.addTabToPane(paneId, type: .agent, profileId: "claude-code")
        )
        manager.updateAgentStatus(paneId: paneId, tabId: inactiveTabId, status: .running)
        manager.updateAgentStatus(paneId: paneId, tabId: activeTabId, status: .running)

        manager.handleTerminalClose(
            target: TerminalTarget(paneId: paneId, tabId: inactiveTabId)
        )

        #expect(manager.agent(paneId: paneId, tabId: inactiveTabId)?.status == .stopped)
        #expect(manager.agent(paneId: paneId, tabId: activeTabId)?.status == .running)
        #expect(manager.panes[paneId]?.activeTab?.id == activeTabId)

        manager.handleTerminalClose(
            target: TerminalTarget(paneId: paneId, tabId: inactiveTabId)
        )
        #expect(manager.agent(paneId: paneId, tabId: activeTabId)?.status == .running)
    }

    @Test func inactiveRegularTerminalCloseRemovesOnlyTheSuppliedTab() throws {
        let manager = AgentManager()
        let paneId = manager.activePaneId
        let terminalTabId = try #require(manager.panes[paneId]?.activeTab?.id)
        let firstAgentTabId = try #require(
            manager.addTabToPane(paneId, type: .agent, profileId: "codex")
        )
        let activeAgentTabId = try #require(
            manager.addTabToPane(paneId, type: .agent, profileId: "claude-code")
        )

        let terminalTarget = TerminalTarget(paneId: paneId, tabId: terminalTabId)
        manager.handleTerminalClose(target: terminalTarget)

        #expect(manager.panes[paneId]?.tabs.map(\.id) == [firstAgentTabId, activeAgentTabId])
        #expect(manager.panes[paneId]?.activeTab?.id == activeAgentTabId)

        manager.handleTerminalClose(target: terminalTarget)
        #expect(manager.panes[paneId]?.tabs.map(\.id) == [firstAgentTabId, activeAgentTabId])
    }

    @Test func finishedManualAgentDetachesWhenItsShellCommandReturns() throws {
        let manager = AgentManager()
        let paneId = manager.activePaneId
        let tabId = try #require(manager.panes[paneId]?.activeTab?.id)
        manager.renameTab(paneId, tabId: tabId, to: "Terminal")
        let firstAgent = try #require(
            manager.attachAgentIfNeeded(
                paneId: paneId,
                tabId: tabId,
                profileId: "codex"
            )
        )
        manager.updateAgentStatus(
            paneId: paneId,
            tabId: tabId,
            status: .running
        )

        manager.agentProcessDidExit(
            target: TerminalTarget(paneId: paneId, tabId: tabId),
            exitCode: 130
        )

        #expect(firstAgent.status == .stopped)
        #expect(manager.agent(paneId: paneId, tabId: tabId) == nil)
        #expect(manager.panes[paneId]?.activeTab?.title == "Terminal")

        let secondAgent = manager.attachAgentIfNeeded(
            paneId: paneId,
            tabId: tabId,
            profileId: "codex"
        )
        #expect(secondAgent != nil)
        #expect(secondAgent !== firstAgent)
    }

    @Test func finishedDedicatedAgentBecomesStoppedWithoutStoppingItsSurfaceAgain() throws {
        let manager = AgentManager()
        let paneId = manager.activePaneId
        let tabId = try #require(
            manager.addTabToPane(paneId, type: .agent, profileId: "codex")
        )
        let target = TerminalTarget(paneId: paneId, tabId: tabId)
        manager.updateAgentStatus(paneId: paneId, tabId: tabId, status: .running)
        var actions: [TerminalLifecycleAction] = []
        manager.addTerminalLifecycleObserver(id: "test-spy") { actions.append($0) }

        manager.agentProcessDidExit(target: target, exitCode: 130)

        #expect(manager.agent(paneId: paneId, tabId: tabId)?.status == .stopped)
        #expect(manager.agent(paneId: paneId, tabId: tabId)?.exitCode == 130)
        #expect(actions.isEmpty)
    }
}

@MainActor
struct SplitTreeTerminalLifecycleTests {
    @Test func duplicateTabIdsAcrossPanesKeepDistinctExactTargetSurfaces() {
        let firstTarget = TerminalTarget(paneId: "pane-10", tabId: "tab-shared")
        let secondTarget = TerminalTarget(paneId: "pane-11", tabId: "tab-shared")
        let manager = AgentManager()
        manager.restoreWorkspace(WorkspaceSession(
            id: "duplicate-tabs",
            name: "Duplicate tabs",
            savedAt: .distantPast,
            layout: .split(.init(
                direction: .horizontal,
                first: .leaf(firstTarget.paneId),
                second: .leaf(secondTarget.paneId)
            )),
            panes: [
                .init(
                    id: firstTarget.paneId,
                    activeTabIndex: 0,
                    tabs: [
                        .init(
                            id: firstTarget.tabId,
                            type: .agent,
                            profileId: "codex"
                        ),
                    ]
                ),
                .init(
                    id: secondTarget.paneId,
                    activeTabIndex: 0,
                    tabs: [
                        .init(
                            id: secondTarget.tabId,
                            type: .agent,
                            profileId: "claude-code"
                        ),
                    ]
                ),
            ],
            activePaneId: firstTarget.paneId
        ))
        let spy = SurfaceLifecycleSpy()
        let splitTree = makeSplitTree(manager: manager, spy: spy)

        #expect(spy.createdTargets.filter { $0 == firstTarget }.count == 1)
        #expect(spy.createdTargets.filter { $0 == secondTarget }.count == 1)
        spy.destroyedTargets.removeAll()
        spy.restartedTargets.removeAll()

        manager.stopAgent(target: secondTarget)
        manager.restartAgent(target: secondTarget)

        #expect(spy.destroyedTargets == [secondTarget])
        #expect(spy.restartedTargets == [secondTarget])
        #expect(!spy.destroyedTargets.contains(firstTarget))
        #expect(!spy.restartedTargets.contains(firstTarget))
        _ = splitTree
    }

    @Test func stoppedUncachedAgentDoesNotStartWhenItBecomesVisible() throws {
        let manager = AgentManager()
        let paneId = manager.activePaneId
        let stoppedTabId = try #require(
            manager.addTabToPane(paneId, type: .agent, profileId: "codex")
        )
        _ = try #require(
            manager.addTabToPane(paneId, type: .agent, profileId: "claude-code")
        )
        manager.stopAgent(target: TerminalTarget(paneId: paneId, tabId: stoppedTabId))
        let spy = SurfaceLifecycleSpy()
        let splitTree = makeSplitTree(manager: manager, spy: spy)

        #expect(!spy.createdTargets.contains(
            TerminalTarget(paneId: paneId, tabId: stoppedTabId)
        ))

        manager.focusTab(paneId: paneId, tabId: stoppedTabId)

        #expect(spy.createdTargets.last == TerminalTarget(paneId: paneId, tabId: stoppedTabId))
        #expect(spy.createdStartFlags.last == false)
        #expect(spy.restartedTargets.isEmpty)
        _ = splitTree
    }

    @Test func stopAndRestartOperateOnlyOnTheCachedTargetSurface() throws {
        let manager = AgentManager()
        let paneId = manager.activePaneId
        let firstTabId = try #require(
            manager.addTabToPane(paneId, type: .agent, profileId: "codex")
        )
        let secondTabId = try #require(
            manager.addTabToPane(paneId, type: .agent, profileId: "claude-code")
        )
        let spy = SurfaceLifecycleSpy()
        let splitTree = makeSplitTree(manager: manager, spy: spy)
        manager.focusTab(paneId: paneId, tabId: firstTabId)
        spy.destroyedTargets.removeAll()
        spy.restartedTargets.removeAll()

        manager.stopAgent(
            target: TerminalTarget(paneId: paneId, tabId: firstTabId)
        )

        #expect(spy.destroyedTargets == [
            TerminalTarget(paneId: paneId, tabId: firstTabId),
        ])
        #expect(!spy.destroyedTargets.contains(
            TerminalTarget(paneId: paneId, tabId: secondTabId)
        ))
        #expect(spy.restartedTargets.isEmpty)

        manager.stopAgent(
            target: TerminalTarget(paneId: paneId, tabId: firstTabId)
        )
        #expect(spy.destroyedTargets.count == 1)

        manager.restartAgent(
            target: TerminalTarget(paneId: paneId, tabId: firstTabId)
        )

        #expect(spy.restartedTargets == [
            TerminalTarget(paneId: paneId, tabId: firstTabId),
        ])
        #expect(!spy.restartedTargets.contains(
            TerminalTarget(paneId: paneId, tabId: secondTabId)
        ))
        _ = splitTree
    }

    @Test func restartOfUncachedTargetConstructsAndStartsItExactlyOnce() throws {
        let manager = AgentManager()
        let paneId = manager.activePaneId
        let inactiveTabId = try #require(
            manager.addTabToPane(paneId, type: .agent, profileId: "codex")
        )
        _ = try #require(
            manager.addTabToPane(paneId, type: .agent, profileId: "claude-code")
        )
        manager.stopAgent(target: TerminalTarget(paneId: paneId, tabId: inactiveTabId))
        let spy = SurfaceLifecycleSpy()
        let splitTree = makeSplitTree(manager: manager, spy: spy)

        manager.restartAgent(
            target: TerminalTarget(paneId: paneId, tabId: inactiveTabId)
        )

        let target = TerminalTarget(paneId: paneId, tabId: inactiveTabId)
        #expect(spy.createdTargets.filter { $0 == target }.count == 1)
        let creationIndex = try #require(spy.createdTargets.firstIndex(of: target))
        #expect(spy.createdStartFlags[creationIndex])
        #expect(spy.restartedTargets.isEmpty)
        _ = splitTree
    }

    @Test func cachedCodexRestartSchedulesANewReadinessGeneration() throws {
        let manager = AgentManager()
        let paneId = manager.activePaneId
        let tabId = try #require(
            manager.addTabToPane(paneId, type: .agent, profileId: "codex")
        )
        let target = TerminalTarget(paneId: paneId, tabId: tabId)
        let spy = SurfaceLifecycleSpy()
        var readinessCallbacks: [() -> Void] = []
        let splitTree = makeSplitTree(
            manager: manager,
            spy: spy,
            scheduleCodexReadiness: { readinessCallbacks.append($0) }
        )

        #expect(readinessCallbacks.count == 1)
        manager.restartAgent(target: target)
        #expect(spy.restartedTargets == [target])
        #expect(readinessCallbacks.count == 2)

        readinessCallbacks[0]()
        #expect(manager.agent(paneId: paneId, tabId: tabId)?.status == .starting)

        readinessCallbacks[1]()
        #expect(manager.agent(paneId: paneId, tabId: tabId)?.status == .idle)
        _ = splitTree
    }

    @Test func failedCachedRestartDoesNotScheduleReadiness() throws {
        let manager = AgentManager()
        let paneId = manager.activePaneId
        let tabId = try #require(
            manager.addTabToPane(paneId, type: .agent, profileId: "codex")
        )
        let spy = SurfaceLifecycleSpy()
        var readinessCallbacks: [() -> Void] = []
        let splitTree = makeSplitTree(
            manager: manager,
            spy: spy,
            restartSucceeds: false,
            scheduleCodexReadiness: { readinessCallbacks.append($0) }
        )

        #expect(readinessCallbacks.count == 1)
        manager.restartAgent(target: TerminalTarget(paneId: paneId, tabId: tabId))
        #expect(readinessCallbacks.count == 1)
        _ = splitTree
    }

    @Test func sameTargetRestoreIgnoresTheReplacedSurfaceReadinessGeneration() throws {
        let manager = AgentManager()
        let paneId = manager.activePaneId
        let tabId = try #require(
            manager.addTabToPane(paneId, type: .agent, profileId: "codex")
        )
        let target = TerminalTarget(paneId: paneId, tabId: tabId)
        let session = manager.snapshotWorkspace()
        let spy = SurfaceLifecycleSpy()
        var readinessCallbacks: [() -> Void] = []
        let splitTree = makeSplitTree(
            manager: manager,
            spy: spy,
            scheduleCodexReadiness: { readinessCallbacks.append($0) }
        )

        #expect(readinessCallbacks.count == 1)
        manager.restoreWorkspace(session)
        #expect(spy.createdTargets.filter { $0 == target }.count == 2)
        #expect(readinessCallbacks.count == 2)

        readinessCallbacks[0]()
        #expect(manager.agent(paneId: paneId, tabId: tabId)?.status == .starting)

        readinessCallbacks[1]()
        #expect(manager.agent(paneId: paneId, tabId: tabId)?.status == .idle)
        _ = splitTree
    }

    @Test func ordinaryLayoutUpdatePreservesContentWhileSameTargetRestoreReplacesIt() throws {
        let manager = AgentManager()
        let paneId = manager.activePaneId
        let tabId = try #require(manager.panes[paneId]?.activeTab?.id)
        let target = TerminalTarget(paneId: paneId, tabId: tabId)
        let session = manager.snapshotWorkspace()
        let spy = SurfaceLifecycleSpy()
        let splitTree = makeSplitTree(manager: manager, spy: spy)

        let originalView = try #require(spy.createdViewsByTarget[target]?.first)
        manager.setLayout(manager.layout)

        #expect(spy.createdViewsByTarget[target]?.count == 1)
        #expect(spy.destroyedTargets.isEmpty)
        #expect(spy.createdViewsByTarget[target]?.first === originalView)

        manager.restoreWorkspace(session)

        #expect(spy.destroyedTargets == [target])
        #expect(spy.createdViewsByTarget[target]?.count == 2)
        let replacementView = try #require(spy.createdViewsByTarget[target]?.last)
        #expect(replacementView !== originalView)
        _ = splitTree
    }

    @Test func paneDepthNavigationPreservesBothLiveTerminalSurfaces() throws {
        let manager = AgentManager()
        let paneId = manager.activePaneId
        let rootTabId = try #require(manager.panes[paneId]?.activeTab?.id)
        let rootTarget = TerminalTarget(paneId: paneId, tabId: rootTabId)
        let spy = SurfaceLifecycleSpy()
        let splitTree = makeSplitTree(manager: manager, spy: spy)
        let rootView = try #require(spy.createdViewsByTarget[rootTarget]?.first)

        let childTabId = try #require(manager.goIn(paneId))
        let childTarget = TerminalTarget(paneId: paneId, tabId: childTabId)
        let childView = try #require(spy.createdViewsByTarget[childTarget]?.first)

        #expect(spy.destroyedTargets.isEmpty)
        #expect(manager.goOut(paneId))
        #expect(manager.goIn(paneId) == childTabId)
        #expect(spy.createdViewsByTarget[rootTarget]?.count == 1)
        #expect(spy.createdViewsByTarget[childTarget]?.count == 1)
        #expect(spy.createdViewsByTarget[rootTarget]?.first === rootView)
        #expect(spy.createdViewsByTarget[childTarget]?.first === childView)
        #expect(spy.destroyedTargets.isEmpty)
        _ = splitTree
    }

    private func makeSplitTree(
        manager: AgentManager,
        spy: SurfaceLifecycleSpy,
        restartSucceeds: Bool = true,
        scheduleCodexReadiness: @escaping (@escaping () -> Void) -> Void = { _ in }
    ) -> SplitTreeView {
        SplitTreeView(
            agentManager: manager,
            themeManager: ThemeManager(themeId: "gruvbox-dark"),
            terminalViewFactory: { target, _, startsSurface in
                let view = ThemedSplitView(
                    themeManager: ThemeManager(themeId: "gruvbox-dark"),
                    branchPath: []
                )
                spy.createdTargets.append(target)
                spy.createdStartFlags.append(startsSurface)
                spy.targetsByView[ObjectIdentifier(view)] = target
                spy.createdViewsByTarget[target, default: []].append(view)
                return view
            },
            destroyTerminalView: { view in
                if let target = spy.targetsByView[ObjectIdentifier(view)] {
                    spy.destroyedTargets.append(target)
                }
            },
            restartTerminalView: { view in
                if let target = spy.targetsByView[ObjectIdentifier(view)] {
                    spy.restartedTargets.append(target)
                }
                return restartSucceeds
            },
            terminalViewHasLiveSurface: { _ in true },
            scheduleCodexReadiness: scheduleCodexReadiness
        )
    }
}

@MainActor
private final class SurfaceLifecycleSpy {
    var createdTargets: [TerminalTarget] = []
    var createdStartFlags: [Bool] = []
    var targetsByView: [ObjectIdentifier: TerminalTarget] = [:]
    var createdViewsByTarget: [TerminalTarget: [NSView]] = [:]
    var destroyedTargets: [TerminalTarget] = []
    var restartedTargets: [TerminalTarget] = []
}

@MainActor
struct SurfaceDestructionGateTests {
    @Test func reentrantDestructionIsSkippedButLaterSequentialCallRuns() {
        let gate = SurfaceDestructionGate()
        var operations: [String] = []

        gate.perform {
            operations.append("outer")
            gate.perform {
                operations.append("reentrant")
            }
        }
        gate.perform {
            operations.append("sequential")
        }

        #expect(operations == ["outer", "sequential"])
    }
}
