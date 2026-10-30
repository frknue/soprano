import AppKit
import SwiftTerm
import Testing
@testable import SopranoAgents
@testable import SopranoAgentsCore

@MainActor
struct TerminalWorkspaceTests {
    private struct Harness {
        let engine: AgentEngine
        let drawer: TerminalDrawerViewController
        let launches: () -> [String]
        let reported: () -> [String]
    }

    /// The demo thread with its worktree pointed at `worktree`; shell launches and missing-workspace
    /// reports are recorded instead of spawning shells or showing alerts.
    private func makeHarness(worktree: String) throws -> Harness {
        let built = try DemoFixtures.build("demo")
        built.engine.updateThread(DemoFixtures.ID.demo) { $0.worktreePath = worktree }
        let drawer = TerminalDrawerViewController(engine: built.engine, state: WorkspaceState())
        var launches: [String] = []
        var reported: [String] = []
        drawer.launchShell = { _, _, cwd in launches.append(cwd) }
        drawer.reportMissingWorkspace = { path in reported.append(path) }
        return Harness(engine: built.engine, drawer: drawer, launches: { launches }, reported: { reported })
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
}
