import AppKit
import Testing
@testable import Soprano

/// Runs driven end to end without a display: the terminal "starts" at once,
/// and the agent's hooks are played by setting its status the way
/// `AgentNotificationManager` does.
@MainActor
struct AutomationControllerTests {
    private final class Recorder {
        var started: [TerminalTarget] = []
        var banners: [(title: String, body: String)] = []
    }

    private struct Fixture {
        let controller: AutomationController
        let agentManager: AgentManager
        let recorder: Recorder
        let directory: URL
    }

    private func makeFixture(automation: String, now: @escaping () -> Date = Date.init) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soprano-automation-controller-\(UUID().uuidString)", isDirectory: true)
        let folder = directory.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let configStore = ConfigStore(fileURL: directory.appendingPathComponent("settings.json"))
        try ConfigFile.write("""
        { "automations": { "audit": \(automation.replacingOccurrences(of: "$FOLDER", with: folder.path)) } }
        """, to: configStore.fileURL)
        configStore.start(watching: false, seedSettings: .defaultSettings, seedKeybindings: DefaultKeybindings.config)

        let agentManager = AgentManager()
        let recorder = Recorder()
        let controller = AutomationController(
            store: AutomationStore(fileURL: nil),
            agentManager: agentManager,
            configStore: configStore,
            environment: AutomationController.Environment(
                startTerminal: { target in
                    recorder.started.append(target)
                    return true
                },
                submitPrompt: { _, _ in false },
                visibleText: { _ in nil },
                notify: { title, body, _ in recorder.banners.append((title, body)) },
                displayIsAwake: { true },
                now: now,
                worktreeDirectory: directory.appendingPathComponent("worktrees", isDirectory: true),
                claudeConfig: nil,
                home: directory,
                shell: "/bin/sh"
            )
        )
        return Fixture(controller: controller, agentManager: agentManager, recorder: recorder, directory: directory)
    }

    /// Lets the controller's background preparation hop back to the main actor.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    private let omp = #"{ "name": "Audit", "agent": "omp", "folder": "$FOLDER", "prompt": "Audit the repo.", "schedule": "0 9 * * *" }"#

    @Test func aManualRunOpensItsAgentInTheAutomationsSessionWithoutSwitchingToIt() async throws {
        let fixture = try makeFixture(automation: omp)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let sessionBefore = fixture.agentManager.activeSessionId

        fixture.controller.runNow("audit")
        try await waitUntil { fixture.controller.lastRun(for: "audit")?.target != nil }

        let run = try #require(fixture.controller.lastRun(for: "audit"))
        let target = try #require(run.target)
        let agent = try #require(fixture.agentManager.agent(paneId: target.paneId, tabId: target.tabId))
        let window = try #require(fixture.agentManager.window(containingPane: target.paneId))
        #expect(fixture.agentManager.terminalSessions[window.sessionId]?.name == AgentManager.automationSessionName)
        #expect(fixture.agentManager.activeSessionId == sessionBefore)
        #expect(fixture.recorder.started == [target])
        #expect(agent.launch == AgentLaunch(prompt: "Audit the repo.", model: nil, skipsApprovals: true))
        #expect(agent.automationRunId == run.id)
        #expect(run.trigger == .manual)
        #expect(run.status == .starting)
        #expect(window.title == "Audit #1")
    }

    @Test func aRunCompletesWhenItsAgentFinishesItsTurnKeepsTheReplyAndClosesTheUnseenWindow() async throws {
        let fixture = try makeFixture(automation: omp)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.controller.runNow("audit")
        try await waitUntil { fixture.controller.lastRun(for: "audit")?.target != nil }
        let target = try #require(fixture.controller.lastRun(for: "audit")?.target)
        let agentManager = fixture.agentManager

        agentManager.updateAgentStatus(paneId: target.paneId, tabId: target.tabId, status: .running)
        #expect(fixture.controller.lastRun(for: "audit")?.status == .running)

        agentManager.agent(paneId: target.paneId, tabId: target.tabId)?.lastMessage = "## Findings\nNothing risky."
        agentManager.updateAgentStatus(
            paneId: target.paneId, tabId: target.tabId, status: .waiting, waitingReason: .turnEnded
        )

        let run = try #require(fixture.controller.lastRun(for: "audit"))
        #expect(run.status == .completed)
        #expect(run.output == "## Findings\nNothing risky.")
        #expect(run.finishedAt != nil)
        #expect(run.target == nil)
        #expect(agentManager.panes[target.paneId] == nil)
        #expect(!agentManager.terminalSessions.values.contains { $0.name == AgentManager.automationSessionName })
        #expect(fixture.recorder.banners.map(\.title) == ["Audit is done"])
    }

    @Test func aRunWaitingOnAQuestionIsAnnouncedAndKeepsItsWindow() async throws {
        let fixture = try makeFixture(automation: omp)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.controller.runNow("audit")
        try await waitUntil { fixture.controller.lastRun(for: "audit")?.target != nil }
        let target = try #require(fixture.controller.lastRun(for: "audit")?.target)

        fixture.agentManager.updateAgentStatus(paneId: target.paneId, tabId: target.tabId, status: .running)
        fixture.agentManager.agent(paneId: target.paneId, tabId: target.tabId)?.lastMessage = "Which store?"
        fixture.agentManager.updateAgentStatus(
            paneId: target.paneId, tabId: target.tabId, status: .waiting, waitingReason: .question
        )

        let run = try #require(fixture.controller.lastRun(for: "audit"))
        #expect(run.status == .needsInput)
        #expect(run.message == "Which store?")
        #expect(fixture.agentManager.panes[target.paneId] != nil)
        #expect(fixture.recorder.banners.map(\.title) == ["Audit has a question"])
    }

    @Test func aScheduledRunWhosePrecheckFailsIsSkippedWithoutOpeningAWindow() async throws {
        let calendar = Calendar.current
        let due = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
        let fixture = try makeFixture(
            automation: #"{ "name": "Audit", "agent": "omp", "folder": "$FOLDER", "prompt": "x", "schedule": "0 9 * * *", "precheck": "exit 4" }"#,
            now: { due.addingTimeInterval(30) }
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let automation = try #require(fixture.controller.automation("audit"))
        fixture.controller.store.setSchedule(
            .init(signature: AutomationScheduling.signature(of: automation), nextRunAt: due),
            for: "audit"
        )

        fixture.controller.tick()
        try await waitUntil { fixture.controller.lastRun(for: "audit")?.status.isFinal == true }

        let run = try #require(fixture.controller.lastRun(for: "audit"))
        #expect(run.status == .skipped)
        #expect(run.trigger == .scheduled)
        #expect(run.scheduledFor == due)
        #expect(run.message == "The precheck exited with code 4.")
        #expect(fixture.recorder.started.isEmpty)
        #expect(fixture.recorder.banners.isEmpty)
    }

    @Test func aScheduledRunDueWhileThePreviousOneStillWorksIsSkipped() async throws {
        let calendar = Calendar.current
        let due = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
        let fixture = try makeFixture(automation: omp, now: { due.addingTimeInterval(30) })
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.controller.runNow("audit")
        try await waitUntil { fixture.controller.lastRun(for: "audit")?.target != nil }
        let automation = try #require(fixture.controller.automation("audit"))
        fixture.controller.store.setSchedule(
            .init(signature: AutomationScheduling.signature(of: automation), nextRunAt: due),
            for: "audit"
        )

        fixture.controller.tick()

        let runs = fixture.controller.runs(for: "audit")
        #expect(runs.count == 2)
        #expect(runs.first?.status == .skipped)
        #expect(runs.first?.message == "Run #1 was still working.")
        #expect(runs.last?.status == .starting)
    }

    @Test func runsLeftOpenWhenSopranoQuitAreMarkedFailedOnTheNextLaunch() throws {
        let store = AutomationStore(fileURL: nil)
        var open = AutomationRun(
            id: "run-1", automationId: "audit", number: 1, trigger: .scheduled,
            startedAt: Date(), status: .running, profileId: "omp", folder: "/tmp"
        )
        open.paneId = "pane-9"
        open.tabId = "tab-9"
        store.insert(open)

        _ = AutomationController(
            store: store,
            agentManager: AgentManager(),
            configStore: ConfigStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID().uuidString).json")),
            environment: .init(startTerminal: { _ in true }, submitPrompt: { _, _ in false }, visibleText: { _ in nil }, notify: { _, _, _ in })
        )

        let run = try #require(store.run("run-1"))
        #expect(run.status == .failed)
        #expect(run.message == "Soprano quit before the run finished.")
        #expect(run.target == nil)
    }

    @Test func aFinishedRunFromAnEarlierLaunchNeverTakesOverTheTabThatNowHasItsIds() throws {
        // Pane and tab ids start over on relaunch, so the ids a finished run
        // kept can belong to an unrelated agent of the same CLI by now.
        let manager = AgentManager()
        let paneId = try #require(manager.spawnAgent("omp", cwd: "/tmp"))
        let tabId = try #require(manager.panes[paneId]?.activeTab?.id)
        manager.updateAgentStatus(paneId: paneId, tabId: tabId, status: .idle)
        let store = AutomationStore(fileURL: nil)
        var finished = AutomationRun(
            id: "run-1", automationId: "audit", number: 1, trigger: .scheduled,
            startedAt: Date(), status: .completed, profileId: "omp", folder: "/tmp"
        )
        finished.paneId = paneId
        finished.tabId = tabId
        store.insert(finished)
        var prompts: [String] = []

        let controller = AutomationController(
            store: store,
            agentManager: manager,
            configStore: ConfigStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID().uuidString).json")),
            environment: .init(
                startTerminal: { _ in true },
                submitPrompt: { prompt, _ in prompts.append(prompt); return true },
                visibleText: { _ in nil },
                notify: { _, _, _ in }
            )
        )

        #expect(store.run("run-1")?.target == nil)
        #expect(!controller.openRun("run-1"))
        #expect(prompts.isEmpty)
    }

    /// A repository with one commit in the fixture's automation folder.
    private func initRepository(in fixture: Fixture) throws {
        let folder = fixture.directory.appendingPathComponent("repo").path
        for arguments in [
            ["init", "--quiet", "--initial-branch=main"],
            ["config", "user.email", "test@example.com"],
            ["config", "user.name", "Test"],
            ["commit", "--quiet", "--allow-empty", "-m", "init"],
        ] {
            _ = try Git.output(arguments, in: folder)
        }
    }

    private func finishTurn(_ target: TerminalTarget, in fixture: Fixture) {
        fixture.agentManager.updateAgentStatus(paneId: target.paneId, tabId: target.tabId, status: .running)
        fixture.agentManager.updateAgentStatus(
            paneId: target.paneId, tabId: target.tabId, status: .waiting, waitingReason: .turnEnded
        )
    }

    @Test(.enabled(if: Git.executableURL != nil))
    func anUntouchedWorktreeStaysWhileItsRunsWindowIsOpenAndGoesWithAnUnseenOne() async throws {
        let worktreeAudit = #"{ "name": "Audit", "agent": "omp", "folder": "$FOLDER", "prompt": "Audit.", "schedule": "0 9 * * *", "worktree": true }"#
        let fixture = try makeFixture(automation: worktreeAudit)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try initRepository(in: fixture)
        let controller = fixture.controller

        // Someone opened this run while it worked: its agent stays, in its worktree.
        controller.runNow("audit")
        try await waitUntil { controller.lastRun(for: "audit")?.target != nil }
        let watched = try #require(controller.lastRun(for: "audit"))
        let watchedTarget = try #require(watched.target)
        #expect(controller.openRun(watched.id))
        finishTurn(watchedTarget, in: fixture)
        // The report is read on the background queue that also removes worktrees.
        try await waitUntil { controller.run(watched.id)?.status == .completed }
        try await Task.sleep(for: .milliseconds(300))
        let watchedWorktree = try #require(controller.run(watched.id)?.worktree)
        #expect(!watchedWorktree.removed)
        #expect(FileManager.default.fileExists(atPath: watchedWorktree.path))
        #expect(fixture.agentManager.panes[watchedTarget.paneId] != nil)

        // Nobody looked: the window closes and the untouched worktree goes too.
        controller.runNow("audit")
        try await waitUntil { controller.lastRun(for: "audit")?.id != watched.id && controller.lastRun(for: "audit")?.target != nil }
        let unseen = try #require(controller.lastRun(for: "audit"))
        finishTurn(try #require(unseen.target), in: fixture)
        try await waitUntil { controller.run(unseen.id)?.worktree?.removed == true }
        let unseenWorktree = try #require(controller.run(unseen.id)?.worktree)
        #expect(!FileManager.default.fileExists(atPath: unseenWorktree.path))
    }

    @Test func openingAClosedRunTwiceReturnsToTheConversationItResumedInsteadOfStartingAnother() async throws {
        let fixture = try makeFixture(automation: omp)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let controller = fixture.controller
        controller.runNow("audit")
        try await waitUntil { controller.lastRun(for: "audit")?.target != nil }
        let run = try #require(controller.lastRun(for: "audit"))
        let target = try #require(run.target)
        fixture.agentManager.recordAgentConversation(
            AgentConversation(id: "01a186a9-695e-72bb-abf9-4646ac0bf7ea", cwd: "/tmp"),
            paneId: target.paneId, tabId: target.tabId, profileId: "omp"
        )
        finishTurn(target, in: fixture)
        #expect(controller.run(run.id)?.target == nil)
        let panesBefore = fixture.agentManager.panes.count

        #expect(controller.openRun(run.id))
        #expect(controller.openRun(run.id))

        #expect(fixture.agentManager.panes.count == panesBefore + 1)
        let resumed = try #require(controller.run(run.id)?.target)
        #expect(fixture.agentManager.agent(paneId: resumed.paneId, tabId: resumed.tabId)?.conversation?.id
            == "01a186a9-695e-72bb-abf9-4646ac0bf7ea")
    }
}
