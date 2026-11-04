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
}
