import AppKit
import Testing
@testable import Soprano
@testable import SopranoAgentsCore

struct SidebarTerminalsTests {
    private static let project = Project(id: "app", title: "app", path: "/tmp/app")

    private static func entry(
        _ pane: String,
        profile: String = "codex",
        name: String = "Codex",
        task: String = "Codex",
        window: String = "app",
        status: AgentStatus = .running,
        needsAttention: Bool = false
    ) -> AgentDashboardEntry {
        AgentDashboardEntry(
            paneId: pane,
            tabId: "tab",
            tabTitle: task,
            windowTitle: window,
            profileId: profile,
            profileName: name,
            status: status,
            needsAttention: needsAttention,
            startedAt: nil,
            cwd: "/tmp/app"
        )
    }

    private static func thread(_ id: String) -> AgentThread {
        let started = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let model = ModelSelection(provider: .omp, model: "openai-codex/gpt-6.1-sol")
        return AgentThread(
            id: id,
            projectID: project.id,
            title: "Thread \(id)",
            createdAt: started,
            modelSelection: model,
            branch: nil,
            pinnedAt: nil,
            settledAt: nil,
            lastVisitedAt: started.addingTimeInterval(60),
            turns: [Turn(
                ordinal: 1,
                userMessage: UserMessage(text: "Prompt", createdAt: started),
                modelSelection: model,
                status: .completed,
                startedAt: started,
                completedAt: started.addingTimeInterval(10),
                items: [],
                checkpoint: nil
            )]
        )
    }

    private static func identities(_ items: [SidebarItem]) -> [String] {
        items.map(\.identity)
    }

    @Test func paneAgentsListUnderTerminalsAboveTheThreadSectionsInTheGivenOrder() {
        let entries = [Self.entry("claude", status: .waiting), Self.entry("codex"), Self.entry("omp", status: .idle)]

        let items = SidebarListModel.build(threads: [Self.thread("a")], projects: [Self.project], options: SidebarListOptions(), terminals: entries)

        let ids = Self.identities(items)
        #expect(Array(ids.prefix(4)) == ["terminals", "terminal:claude:tab", "terminal:codex:tab", "terminal:omp:tab"])
        #expect(ids.count > 4 && ids[4].hasPrefix("shelf:"))
        #expect(items.first == .terminalsShelf(count: 3, expanded: true))
        #expect(SidebarListModel.threadOrder(items) == ["a"])
    }

    @Test func withoutPaneAgentsThereIsNoTerminalsSection() {
        let items = SidebarListModel.build(threads: [Self.thread("a")], projects: [Self.project], options: SidebarListOptions(), terminals: [])

        #expect(!Self.identities(items).contains { $0.hasPrefix("terminal") })
    }

    @Test func aClosedTerminalsSectionKeepsOnlyItsHeader() {
        var options = SidebarListOptions()
        options.terminalsExpanded = false

        let items = SidebarListModel.build(threads: [], projects: [Self.project], options: options, terminals: [Self.entry("codex")])

        #expect(Self.identities(items) == ["terminals", "empty:No threads yet"])
        #expect(items.first == .terminalsShelf(count: 1, expanded: false))
    }

    @Test func searchingListsOnlyMatchingThreads() {
        var options = SidebarListOptions()
        options.searchText = "Thread a"

        let items = SidebarListModel.build(threads: [Self.thread("a")], projects: [Self.project], options: options, terminals: [Self.entry("codex")])

        #expect(Self.identities(items) == ["card:a"])
    }

    @Test func aRowShowsTheTaskOverTheAgentAndItsWindow() {
        let row = SidebarTerminalRow(entry: Self.entry("codex", task: "Fix the flaky checkout test", window: "storefront"))
        #expect(row.name == "Codex")
        #expect(row.title == "Fix the flaky checkout test")
        #expect(row.windowTitle == "storefront")

        // Before it has a task, the tab carries only the agent's name.
        #expect(SidebarTerminalRow(entry: Self.entry("codex")).title == nil)
    }

    @Test func statusWordsFollowWhatTheAgentWaitsFor() {
        let cases: [(AgentStatus, Bool, SidebarTerminalStatus, String)] = [
            (.running, false, .working, "Working"),
            (.starting, false, .working, "Working"),
            (.waiting, false, .needsInput, "Needs input"),
            (.idle, true, .needsInput, "Needs input"),
            (.error, false, .failed, "Error"),
            (.idle, false, .ready, "Ready"),
            (.stopped, false, .stopped, "Stopped"),
        ]
        for (status, attention, expected, label) in cases {
            let row = SidebarTerminalRow(entry: Self.entry("p", status: status, needsAttention: attention))
            #expect(row.status == expected, "\(status)")
            #expect(row.status.label == label, "\(status)")
        }
        #expect(SidebarTerminalStatus.needsInput.needsAttention)
        #expect(!SidebarTerminalStatus.working.needsAttention)
    }
}
