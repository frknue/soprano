import AppKit
import Testing
@testable import SopranoAgentsCore

/// The composer's `/` menu data: a session's `commands` events per thread, remembered per
/// provider and workspace for drafts and threads without a live session.
@MainActor
struct EngineCommandsTests {
    private final class Recorder {
        var events: [EngineEvent] = []
        var commandChanges: Int { events.filter { $0 == .commandsChanged }.count }
    }

    private static let compact = ProviderCommand(name: "compact", kind: .command, source: "Built-in", insertText: "/compact ")
    private static let review = ProviderCommand(name: "review", kind: .command, source: "Custom", insertText: "/review ")
    private static let tdd = ProviderCommand(name: "tdd", kind: .skill, source: "Skill", insertText: "$tdd ")

    @Test func aSessionsCommandsBecomeItsThreadsMenuAndItsProjectsDraftMenu() async throws {
        let driver = ScriptedDriver()
        let engine = EngineHarness.engine(driver: driver)
        let threadID = EngineHarness.idleThread(in: engine)
        let recorder = Recorder()
        engine.addObserver(recorder) { recorder.events.append($0) }
        try await engine.send(threadID, text: "hi", attachments: [])

        driver.session?.emit(.commands([Self.tdd, Self.review, Self.compact, Self.review]))

        #expect(await EngineHarness.eventually { !engine.commands(forThread: threadID).isEmpty })
        #expect(engine.commands(forThread: threadID) == [Self.compact, Self.review, Self.tdd])
        #expect(recorder.commandChanges == 1)
        let projectID = engine.thread(threadID)?.projectID
        #expect(engine.commands(forDraft: .codex, projectID: projectID) == [Self.compact, Self.review, Self.tdd])
        #expect(engine.commands(forDraft: .claude, projectID: projectID).isEmpty)
        #expect(engine.commands(forDraft: .codex, projectID: nil).isEmpty)
        #expect(engine.commands(forDraft: .codex, projectID: "unknown").isEmpty)
    }

    @Test func onlyAChangedListIsAnnounced() async throws {
        let driver = ScriptedDriver()
        let engine = EngineHarness.engine(driver: driver)
        let threadID = EngineHarness.idleThread(in: engine)
        let recorder = Recorder()
        engine.addObserver(recorder) { recorder.events.append($0) }
        try await engine.send(threadID, text: "hi", attachments: [])
        let session = try #require(driver.session)

        session.emit(.commands([Self.review]))
        session.emit(.commands([Self.review]))
        session.emit(.commands([Self.review, Self.tdd]))

        #expect(await EngineHarness.eventually { engine.commands(forThread: threadID).count == 2 })
        #expect(recorder.commandChanges == 2)
    }

    @Test func aThreadWithoutASessionShowsItsWorkspacesRememberedListForItsProvider() throws {
        let engine = EngineHarness.engine()
        let threadID = EngineHarness.idleThread(in: engine)
        let project = try #require(engine.project(engine.thread(threadID)?.projectID))
        let recorder = Recorder()
        engine.addObserver(recorder) { recorder.events.append($0) }

        engine.rememberCommands([Self.tdd, Self.compact], provider: .codex, workingDirectory: project.path)
        engine.rememberCommands([Self.compact, Self.tdd], provider: .codex, workingDirectory: project.path + "/")

        #expect(engine.commands(forThread: threadID) == [Self.compact, Self.tdd])
        #expect(recorder.commandChanges == 1)
        engine.setModelSelection(threadID, .default(for: .claude))
        #expect(engine.commands(forThread: threadID).isEmpty)
    }

    @Test func scratchWorkspacesShareOneList() {
        let engine = EngineHarness.engine()
        let scratch = engine.environment.dataDirectory.appendingPathComponent("scratch/thread-a").path

        engine.rememberCommands([Self.review], provider: .omp, workingDirectory: scratch)

        #expect(engine.commands(forDraft: .omp, projectID: nil) == [Self.review])
        #expect(engine.commands(forDraft: .codex, projectID: nil).isEmpty)
    }

    @Test func aWorktreeThreadsListIsRememberedForItsProjectToo() async throws {
        let driver = ScriptedDriver()
        let engine = EngineHarness.engine(driver: driver)
        let project = engine.addProject(path: EngineHarness.temporaryDirectory().path)
        let worktree = EngineHarness.temporaryDirectory().path
        let thread = AgentThread(projectID: project.id, modelSelection: .default(for: .codex), branch: "soprano/x", worktreePath: worktree)
        engine.insertThread(thread)
        try await engine.send(thread.id, text: "hi", attachments: [])

        driver.session?.emit(.commands([Self.review]))

        #expect(await EngineHarness.eventually { engine.commands(forDraft: .codex, projectID: project.id) == [Self.review] })
        #expect(engine.commands(forThread: thread.id) == [Self.review])
    }
}
