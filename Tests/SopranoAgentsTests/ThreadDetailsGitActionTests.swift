import AppKit
import SopranoAgentsCore
import Testing
@testable import Soprano

@MainActor
struct ThreadDetailsGitActionTests {
    @Test func aSecondRequestWhileTheFirstIsStillReadingTheStatusDoesNotRunTheActionTwice() async {
        let driver = ScriptedDriver()
        driver.generate = { _ in .object(["subject": .string("Update readme"), "body": .string("")]) }
        let engine = EngineHarness.engine(driver: driver)
        let threadID = EngineHarness.idleThread(in: engine)
        let state = WorkspaceState()
        state.select(.thread(threadID))
        let card = ThreadDetailsCardController(engine: engine, state: state)

        // A double click, or a click and the palette: both arrive before the status read returns.
        card.run(.commit)
        card.run(.commit)

        #expect(await EngineHarness.eventually(timeout: .seconds(30)) { !driver.prompts.isEmpty && !card.isGitActionRunning })
        #expect(driver.prompts.count == 1)
    }

    @Test func theCommitDialogDoesNotOpenForAThreadTheUserLeftWhileItsStatusWasRead() async throws {
        let git = RecordingGit()
        let gate = Gate()
        let reads = Gate()
        git.statusGate = { reads.open(); await gate.wait() }
        let engine = EngineHarness.engine(git: git)
        let first = EngineHarness.idleThread(in: engine)
        let second = EngineHarness.idleThread(in: engine)
        let state = WorkspaceState()
        state.select(.thread(first))
        let card = ThreadDetailsCardController(engine: engine, state: state)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = card.view
        window.orderFrontRegardless()
        defer { window.close() }

        card.openCommitDialog()
        await reads.wait()
        state.select(.thread(second))
        gate.open()
        try await Task.sleep(for: .milliseconds(300))

        let dialog = window.childWindows?.first { $0 is CommitDialogPanel }
        dialog?.cancelOperation(nil)
        #expect(dialog == nil)
    }
}
