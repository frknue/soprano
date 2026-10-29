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
}
