import AppKit
import Testing
@testable import SopranoAgents
@testable import SopranoAgentsCore

@MainActor
struct SidebarNavigationTests {
    private func sidebar(_ scenario: String = "demo") throws -> (SidebarViewController, AgentEngine, WorkspaceState) {
        let built = try DemoFixtures.build(scenario)
        let state = WorkspaceState()
        state.select(built.selection)
        let controller = SidebarViewController(engine: built.engine, state: state)
        _ = controller.view
        return (controller, built.engine, state)
    }

    @Test func nextAndPreviousFollowTheListOrderAndWrap() throws {
        let (sidebar, _, state) = try sidebar()
        let order = sidebar.threadOrder
        let start = try #require(order.firstIndex(of: DemoFixtures.ID.demo))

        sidebar.selectAdjacent(1)
        #expect(state.selectedThreadID == order[start + 1])
        sidebar.selectAdjacent(-1)
        sidebar.selectAdjacent(-1)
        #expect(state.selectedThreadID == order[start - 1])

        sidebar.jump(to: 1)
        sidebar.selectAdjacent(-1)
        #expect(state.selectedThreadID == order.last)
    }

    @Test func jumpingOpensTheNthThreadAndIgnoresMissingPositions() throws {
        let (sidebar, _, state) = try sidebar()
        // Pinned first, then the status sections (Working, Blocked, Failed, Done, Idle).
        sidebar.jump(to: 1)
        #expect(state.selectedThreadID == DemoFixtures.ID.pinned)
        sidebar.jump(to: 2)
        #expect(state.selectedThreadID == sidebar.threadOrder[1])
        sidebar.jump(to: 40)
        #expect(state.selectedThreadID == sidebar.threadOrder[1])
    }

    @Test func openingAThreadClearsItsDonePill() throws {
        let (sidebar, engine, _) = try sidebar()
        let pinned = try #require(engine.thread(DemoFixtures.ID.pinned))
        #expect(ThreadStatus.of(pinned) == .done)
        sidebar.open(DemoFixtures.ID.pinned)
        #expect(engine.thread(DemoFixtures.ID.pinned).map(ThreadStatus.of) == .idle)
    }

    @Test func newThreadsStartInTheProjectInView() throws {
        let (_, engine, state) = try sidebar()
        #expect(ThreadActions.currentProjectID(engine: engine, state: state) == DemoFixtures.ID.app)
        state.select(.thread(DemoFixtures.ID.approval))
        #expect(ThreadActions.currentProjectID(engine: engine, state: state) == DemoFixtures.ID.soprano)
        state.select(.draft(projectID: DemoFixtures.ID.site))
        #expect(ThreadActions.currentProjectID(engine: engine, state: state) == DemoFixtures.ID.site)
        // A scratch thread falls back to the filtered project.
        state.select(.thread(DemoFixtures.ID.scratch))
        state.setProjectFilter([DemoFixtures.ID.site])
        #expect(ThreadActions.currentProjectID(engine: engine, state: state) == DemoFixtures.ID.site)
    }

    @Test func archivingTheOpenThreadLeavesADraftInItsProjectButRunningThreadsStay() throws {
        let (_, engine, state) = try sidebar()
        ThreadActions.archive(DemoFixtures.ID.demo, engine: engine, state: state)
        #expect(engine.thread(DemoFixtures.ID.demo)?.archivedAt != nil)
        #expect(state.selection == .draft(projectID: DemoFixtures.ID.app))

        ThreadActions.archive(DemoFixtures.ID.running, engine: engine, state: state)
        #expect(engine.thread(DemoFixtures.ID.running)?.archivedAt == nil)
    }

    @Test func theProjectFilterAndSearchNarrowTheList() throws {
        let (sidebar, _, state) = try sidebar()
        state.setProjectFilter([DemoFixtures.ID.soprano])
        #expect(Set(sidebar.threadOrder) == [DemoFixtures.ID.approval, DemoFixtures.ID.failed])
        state.setProjectFilter([])
        state.setSearchText("redirect")
        #expect(sidebar.threadOrder == [DemoFixtures.ID.demo])
    }

    @Test func openingASubagentLeavesItsThreadsUnreadStateAlone() throws {
        let (sidebar, engine, state) = try sidebar("subagents")
        engine.markUnread(DemoFixtures.ID.subagents)
        sidebar.openSubagent(DemoFixtures.ID.subagents, "Scout")
        #expect(state.selectedSubagentID == "Scout")
        #expect(engine.thread(DemoFixtures.ID.subagents)?.lastVisitedAt == nil)

        sidebar.open(DemoFixtures.ID.subagents)
        #expect(state.selectedSubagentID == nil)
        #expect(engine.thread(DemoFixtures.ID.subagents)?.lastVisitedAt != nil)
    }
}
