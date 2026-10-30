import AppKit
import SwiftTerm
import Testing
@testable import SopranoAgents
@testable import SopranoAgentsCore

@MainActor
struct TerminalWorkspaceTests {
    private struct Harness {
        let engine: AgentEngine
        let state: WorkspaceState
        let drawer: TerminalDrawerViewController
        let launches: () -> [String]
        let reported: () -> [String]
    }

    /// The demo thread with its worktree pointed at `worktree`; shell launches and missing-workspace
    /// reports are recorded instead of spawning shells or showing alerts.
    private func makeHarness(worktree: String) throws -> Harness {
        let built = try DemoFixtures.build("demo")
        built.engine.updateThread(DemoFixtures.ID.demo) { $0.worktreePath = worktree }
        let state = WorkspaceState()
        state.select(.thread(DemoFixtures.ID.demo))
        let drawer = TerminalDrawerViewController(engine: built.engine, state: state)
        var launches: [String] = []
        var reported: [String] = []
        drawer.store.launchShell = { _, _, cwd in launches.append(cwd) }
        drawer.reportMissingWorkspace = { path in reported.append(path) }
        return Harness(engine: built.engine, state: state, drawer: drawer, launches: { launches }, reported: { reported })
    }

    @Test func aProjectScriptForAThreadWhoseWorktreeWasDeletedStartsNoShellAnywhere() throws {
        let missing = "/tmp/soprano-agents-missing-\(UUID().uuidString)"
        let harness = try makeHarness(worktree: missing)

        harness.drawer.run(command: "swift test", in: DemoFixtures.ID.demo)

        #expect(harness.launches().isEmpty)
        #expect(harness.drawer.store.sessions(for: DemoFixtures.ID.demo, placement: .drawer).isEmpty)
        #expect(harness.reported() == [missing])
    }

    @Test func aProjectScriptStartsItsShellInTheThreadsWorktree() throws {
        let worktree = FileManager.default.temporaryDirectory.appendingPathComponent("soprano-agents-wt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: worktree) }
        let harness = try makeHarness(worktree: worktree.path)

        harness.drawer.run(command: "swift test", in: DemoFixtures.ID.demo)

        #expect(harness.launches() == [worktree.path])
        #expect(harness.drawer.store.sessions(for: DemoFixtures.ID.demo, placement: .drawer).count == 1)
        #expect(harness.reported().isEmpty)
    }

    @Test func openingTheDrawerOnAMissingWorkspaceSaysSoAndStartsTheShellOnceTheFolderIsBack() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("soprano-agents-wt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let harness = try makeHarness(worktree: folder.path)
        _ = harness.drawer.view

        harness.state.setTerminalVisible(true)

        #expect(harness.launches().isEmpty)
        #expect(harness.drawer.emptyState.missingWorkspace == folder.path)

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        harness.state.setTerminalVisible(false)
        harness.state.setTerminalVisible(true)

        #expect(harness.launches() == [folder.path])
        #expect(harness.drawer.emptyState.missingWorkspace == nil)
    }

    @Test func anOpenDrawerStartsTheShellWhenTheThreadListChangesAfterItsWorktreeAppears() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("soprano-agents-wt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let harness = try makeHarness(worktree: folder.path)
        _ = harness.drawer.view
        harness.state.setTerminalVisible(true)
        #expect(harness.drawer.emptyState.missingWorkspace == folder.path)

        // A new-worktree launch: the folder appears, then the branch rename / title updates the list.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        harness.engine.rename(DemoFixtures.ID.demo, title: "Renamed")

        #expect(harness.launches() == [folder.path])
        #expect(harness.drawer.emptyState.missingWorkspace == nil)
    }

    private func makeWorktree() throws -> URL {
        let worktree = FileManager.default.temporaryDirectory.appendingPathComponent("soprano-agents-wt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        return worktree
    }

    @Test func panelTerminalsContinueTheDrawersNumberingAndStayOutOfItsList() throws {
        let worktree = try makeWorktree()
        defer { try? FileManager.default.removeItem(at: worktree) }
        let harness = try makeHarness(worktree: worktree.path)
        let store = harness.drawer.store

        let drawer = store.create(in: DemoFixtures.ID.demo, placement: .drawer)
        let panel = store.create(in: DemoFixtures.ID.demo, placement: .panel)

        #expect(drawer?.title == "Terminal 1")
        #expect(panel?.title == "Terminal 2")
        #expect(store.sessions(for: DemoFixtures.ID.demo, placement: .drawer).map(\.id) == [drawer?.id])
        #expect(store.activeSession(for: DemoFixtures.ID.demo, placement: .drawer)?.id == drawer?.id)
        #expect(store.session(panel?.id ?? "")?.placement == .panel)
        #expect(harness.launches() == [worktree.path, worktree.path])
    }

    @Test func closingASessionEndsItsViewAndNotifiesItsThread() throws {
        let worktree = try makeWorktree()
        defer { try? FileManager.default.removeItem(at: worktree) }
        let harness = try makeHarness(worktree: worktree.path)
        let store = harness.drawer.store
        let session = try #require(store.create(in: DemoFixtures.ID.demo, placement: .panel))
        var changes: [ThreadTerminalStore.Change] = []
        store.addObserver(harness.state) { changes.append($0) }

        store.close(session.id)

        #expect(changes == [.sessions(threadID: DemoFixtures.ID.demo)])
        #expect(store.terminalView(session.id) == nil)
        #expect(store.sessions(for: DemoFixtures.ID.demo, placement: .panel).isEmpty)
    }

    @Test func deletingAThreadEndsItsTerminalsInBothPlacements() throws {
        let worktree = try makeWorktree()
        defer { try? FileManager.default.removeItem(at: worktree) }
        let harness = try makeHarness(worktree: worktree.path)
        let store = harness.drawer.store
        let drawer = try #require(store.create(in: DemoFixtures.ID.demo, placement: .drawer))
        let panel = try #require(store.create(in: DemoFixtures.ID.demo, placement: .panel))
        var changes: [ThreadTerminalStore.Change] = []
        store.addObserver(harness.state) { changes.append($0) }

        harness.engine.removeThreadRecord(DemoFixtures.ID.demo)

        #expect(store.terminalView(drawer.id) == nil)
        #expect(store.terminalView(panel.id) == nil)
        #expect(store.sessions(for: DemoFixtures.ID.demo, placement: .drawer).isEmpty)
        #expect(store.sessions(for: DemoFixtures.ID.demo, placement: .panel).isEmpty)
        #expect(changes.contains(.sessions(threadID: DemoFixtures.ID.demo)))
    }
}
