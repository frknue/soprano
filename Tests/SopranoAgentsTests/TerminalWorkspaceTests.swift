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
        drawer.launchShell = { _, _, cwd in launches.append(cwd) }
        drawer.reportMissingWorkspace = { path in reported.append(path) }
        return Harness(engine: built.engine, state: state, drawer: drawer, launches: { launches }, reported: { reported })
    }

    @Test func aProjectScriptForAThreadWhoseWorktreeWasDeletedStartsNoShellAnywhere() throws {
        let missing = "/tmp/soprano-agents-missing-\(UUID().uuidString)"
        let harness = try makeHarness(worktree: missing)

        harness.drawer.run(command: "swift test", in: DemoFixtures.ID.demo)

        #expect(harness.launches().isEmpty)
        #expect(harness.drawer.sessions.sessions(for: DemoFixtures.ID.demo).isEmpty)
        #expect(harness.reported() == [missing])
    }

    @Test func aProjectScriptStartsItsShellInTheThreadsWorktree() throws {
        let worktree = FileManager.default.temporaryDirectory.appendingPathComponent("soprano-agents-wt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: worktree) }
        let harness = try makeHarness(worktree: worktree.path)

        harness.drawer.run(command: "swift test", in: DemoFixtures.ID.demo)

        #expect(harness.launches() == [worktree.path])
        #expect(harness.drawer.sessions.sessions(for: DemoFixtures.ID.demo).count == 1)
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
}
