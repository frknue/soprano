import AppKit
import Testing
@testable import SopranoAgentsCore

struct StoreJSONFileTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("soprano-agents-store-\(UUID().uuidString)", isDirectory: true)
    }

    private func thread(title: String, turns: [Turn] = []) -> AgentThread {
        AgentThread(id: "thread-1", projectID: "p1", title: title, createdAt: Date(timeIntervalSince1970: 1000), modelSelection: .default(for: .claude), turns: turns)
    }

    @Test func projectsAndThreadsSurviveARoundTrip() throws {
        let dir = directory()
        let store = JSONFileThreadStore(directory: dir)
        let project = Project(id: "p1", title: "app", path: "/tmp/app", createdAt: Date(timeIntervalSince1970: 5))
        let saved = thread(title: "Fix login", turns: [
            Turn(ordinal: 1, userMessage: UserMessage(text: "hi", createdAt: Date(timeIntervalSince1970: 1001)), modelSelection: .default(for: .claude),
                 status: .completed, startedAt: Date(timeIntervalSince1970: 1001), completedAt: Date(timeIntervalSince1970: 1002.5),
                 items: [TurnItem(id: "m", kind: .assistantMessage(text: "Hello", isFinal: true), status: .completed, startedAt: Date(timeIntervalSince1970: 1001.25))]),
        ])
        store.save(project: project)
        store.save(thread: saved)
        store.flush()

        let loaded = try JSONFileThreadStore(directory: dir).load()

        #expect(loaded.projects == [project])
        #expect(loaded.threads == [saved])
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("threads/thread-1.json").path))
    }

    @Test func rapidSavesOfAThreadCoalesceIntoOneWriteOfTheLatestState() throws {
        let dir = directory()
        let store = JSONFileThreadStore(directory: dir, coalesceInterval: 60)
        let file = dir.appendingPathComponent("threads/thread-1.json")

        for index in 1...50 {
            store.save(thread: thread(title: "Title \(index)"))
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))

        store.flush()

        #expect(try JSONFileThreadStore(directory: dir).load().threads.map(\.title) == ["Title 50"])
    }

    @Test func deletingAThreadRemovesItsFileEvenWithASavePending() throws {
        let dir = directory()
        let store = JSONFileThreadStore(directory: dir, coalesceInterval: 60)
        store.save(thread: thread(title: "Keep?"))
        store.flush()
        store.save(thread: thread(title: "Edited"))

        store.deleteThread(id: "thread-1")
        store.flush()

        #expect(try JSONFileThreadStore(directory: dir).load().threads.isEmpty)
    }

    @Test func turnsThatWereRunningAtQuitComeBackInterrupted() throws {
        let dir = directory()
        let store = JSONFileThreadStore(directory: dir)
        let running = Turn(
            ordinal: 1,
            userMessage: UserMessage(text: "go"),
            modelSelection: .default(for: .claude),
            startedAt: Date(timeIntervalSince1970: 1000),
            items: [TurnItem(id: "cmd", kind: .command(CommandExecution(command: "make")), status: .running, startedAt: Date(timeIntervalSince1970: 1010))]
        )
        var saved = thread(title: "Crash", turns: [running])
        saved.isGeneratingTitle = true
        store.save(thread: saved)
        store.flush()

        let loaded = try #require(try JSONFileThreadStore(directory: dir).load().threads.first)

        #expect(loaded.turns.first?.status == .interrupted)
        #expect(loaded.turns.first?.items.first?.status == .interrupted)
        #expect(loaded.turns.first?.completedAt == Date(timeIntervalSince1970: 1010))
        #expect(loaded.isRunning == false)
        #expect(loaded.isGeneratingTitle == false)
    }

    @Test func anUnreadableThreadFileIsSkippedAndTheRestStillLoads() throws {
        let dir = directory()
        let store = JSONFileThreadStore(directory: dir)
        store.save(thread: thread(title: "Good"))
        store.flush()
        try Data("{ not json".utf8).write(to: dir.appendingPathComponent("threads/broken.json"))

        let loaded = try JSONFileThreadStore(directory: dir).load()

        #expect(loaded.threads.map(\.title) == ["Good"])
    }

    @Test func approvalsAndQuestionsPendingAtACrashComeBackAnsweredAsCancelled() throws {
        let dir = directory()
        let store = JSONFileThreadStore(directory: dir)
        let running = Turn(
            ordinal: 1,
            userMessage: UserMessage(text: "go"),
            modelSelection: .default(for: .codex),
            items: [
                TurnItem(id: "ap1", kind: .approval(ApprovalRequest(id: "ap1", kind: .command, detail: "rm -rf build")), status: .pending),
                TurnItem(id: "q1", kind: .userInput(UserInputRequest(id: "q1", questions: [
                    UserInputQuestion(id: "a", header: "H", question: "Which?", options: [UserInputOption(label: "One")]),
                ])), status: .pending),
            ]
        )
        store.save(thread: thread(title: "Crash", turns: [running]))
        store.flush()

        let loaded = try #require(try JSONFileThreadStore(directory: dir).load().threads.first)
        let turn = try #require(loaded.turns.first)

        #expect(turn.pendingApproval == nil)
        #expect(turn.pendingUserInput == nil)
        if case let .approval(request) = turn.items[0].kind {
            #expect(request.decision == .cancel)
        } else {
            Issue.record("the approval item changed kind")
        }
    }

    @Test func anUnreadableProjectsFileIsKeptAsideInsteadOfBeingOverwritten() throws {
        let dir = directory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let projectsURL = dir.appendingPathComponent("projects.json")
        try Data("[{ truncated".utf8).write(to: projectsURL)
        let store = JSONFileThreadStore(directory: dir)
        _ = try store.load()

        store.save(project: Project(id: "p2", title: "new", path: "/tmp/new"))
        store.flush()

        let kept = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("projects.json.unreadable") }
        #expect(kept.count == 1)
        let original = try kept.first.map { try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8) }
        #expect(original == "[{ truncated")
    }
}
