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

    @Test func statusWordsAreTheBoardsWordsForEveryStatusWithOrWithoutAttention() {
        let statuses: [AgentStatus] = [.idle, .starting, .running, .waiting, .error, .stopped]
        for status in statuses {
            for attention in [false, true] {
                let row = SidebarTerminalRow(entry: Self.entry("p", status: status, needsAttention: attention))
                // The board's detail header shows `status.chromeStatus.label` ("NEEDS INPUT").
                #expect(row.status.label.uppercased() == status.chromeStatus.label, "\(status) attention: \(attention)")
            }
        }
    }

    @Test func attentionEmphasizesTheStatusWordWithoutChangingIt() {
        let asked = SidebarTerminalRow(entry: Self.entry("p", status: .idle, needsAttention: true))
        #expect(asked.status == .ready)
        #expect(asked.needsAttention)
        #expect(SidebarTerminalRow(entry: Self.entry("p", status: .waiting)).needsAttention)
        #expect(SidebarTerminalRow(entry: Self.entry("p", status: .error)).needsAttention)
        #expect(!SidebarTerminalRow(entry: Self.entry("p", status: .running)).needsAttention)
    }

    @Test func theAgentTheBoardShowsIsTheOnlySelectedRow() {
        var options = SidebarListOptions()
        options.selectedThreadID = "a"
        let entries = [Self.entry("claude"), Self.entry("codex")]
        func selected(_ items: [SidebarItem]) -> [String] {
            items.compactMap { item in
                switch item {
                case let .terminalAgent(row): row.isSelected ? row.entryID : nil
                case let .card(row), let .slim(row): row.isSelected ? row.threadID : nil
                default: nil
                }
            }
        }

        #expect(selected(SidebarListModel.build(threads: [Self.thread("a")], projects: [Self.project], options: options, terminals: entries)) == ["a"])

        options.shownTerminalAgentID = "codex:tab"
        #expect(selected(SidebarListModel.build(threads: [Self.thread("a")], projects: [Self.project], options: options, terminals: entries)) == ["codex:tab"])
    }
}
