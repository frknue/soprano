import AppKit
import SwiftTerm
import Testing
@testable import Soprano
@testable import SopranoAgentsCore

@MainActor
struct TerminalShellReapTests {
    @Test func closingARunningTerminalEndsItsProcessWithoutLeavingAZombie() async throws {
        let engine = EngineHarness.engine()
        let threadID = EngineHarness.idleThread(in: engine)
        let store = ThreadTerminalStore(engine: engine)
        store.launchShell = { terminal, _, cwd in
            terminal.startProcess(executable: "/bin/sleep", args: ["30"], currentDirectory: cwd)
        }
        let session = try #require(store.create(in: .thread(threadID), placement: .drawer))
        let pid = try #require(store.terminalView(session.id)?.process.shellPid)
        #expect(pid > 0)

        store.close(session.id)

        // A zombie still answers kill(pid, 0); only a reaped process is gone.
        #expect(await EngineHarness.eventually { kill(pid, 0) == -1 && errno == ESRCH })
    }
}
