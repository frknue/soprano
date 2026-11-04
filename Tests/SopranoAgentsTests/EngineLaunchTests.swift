import AppKit
import Testing
@testable import SopranoAgentsCore

@MainActor
struct EngineLaunchTests {
    /// A project folder that exists (the engine refuses to run agents in missing folders).
    private static func repository() -> String {
        EngineHarness.temporaryDirectory().path
    }

    private func image(_ name: String) -> SopranoAgentsCore.Attachment {
        SopranoAgentsCore.Attachment(kind: .image, name: name, path: "/tmp/\(name)", mimeType: "image/png", byteSize: 10)
    }

    @Test func titleSeedsCollapseWhitespaceAndCutLongMessagesAtFiftyCharacters() {
        #expect(TextGeneration.titleSeed(text: "  Fix   the\nlogin  bug ", attachments: []) == "Fix the login bug")
        let long = String(repeating: "a", count: 49) + " bcdef"
        #expect(TextGeneration.titleSeed(text: long, attachments: []) == String(repeating: "a", count: 49) + " ...")
        #expect(TextGeneration.titleSeed(text: String(repeating: "x", count: 50), attachments: []) == String(repeating: "x", count: 50))
    }

    @Test func titleSeedsForAttachmentOnlyMessagesNameTheAttachments() {
        #expect(TextGeneration.titleSeed(text: " ", attachments: [image("a.png")]) == "Attached image")
        #expect(TextGeneration.titleSeed(text: "", attachments: [image("a.png"), image("b.png")]) == "Attached images")
        let file = SopranoAgentsCore.Attachment(kind: .file, name: "notes.txt", path: "/tmp/notes.txt", mimeType: "text/plain", byteSize: 3)
        #expect(TextGeneration.titleSeed(text: "", attachments: [file]) == "File: notes.txt")
    }

    @Test func generatedTitlesAreSanitizedToOneUnquotedLine() {
        #expect(TextGeneration.sanitizeTitle("\"Fix Login Redirect\"\nsecond line") == "Fix Login Redirect")
        #expect(TextGeneration.sanitizeTitle("   ") == "New thread")
        let long = TextGeneration.sanitizeTitle(String(repeating: "word ", count: 40))
        #expect(long.count == 120)
        #expect(long.hasSuffix("..."))
    }

    @Test func generatedBranchNamesGetTheConfiguredPrefix() {
        #expect(TextGeneration.formatGeneratedBranchName("Fix Login Error!", prefix: "soprano") == "soprano/fix-login-error")
        #expect(TextGeneration.formatGeneratedBranchName("  ", prefix: "soprano") == "soprano/update")
        #expect(TextGeneration.temporaryBranchName(prefix: "soprano").wholeMatch(of: /soprano\/[0-9a-f]{8}/) != nil)
    }

    @Test func launchingInANewWorktreeCreatesAPrefixedBranchAndRenamesItAfterTheMessage() async throws {
        let driver = ScriptedDriver()
        driver.generate = { prompt in
            prompt.hasPrefix("You generate concise git branch names.") ? .object(["branch": .string("Fix Login Redirect")]) : .object([:])
        }
        let git = RecordingGit()
        let worktrees = EngineHarness.temporaryDirectory().path
        let engine = EngineHarness.engine(driver: driver, git: git, settings: EngineSettings(branchPrefix: "soprano", worktreesDirectory: worktrees, generateTitles: false))
        let project = engine.addProject(path: Self.repository())
        let draft = ThreadDraft(projectID: project.id, modelSelection: .default(for: .omp), workspace: .newWorktree(baseBranch: "main"))

        let threadID = try await engine.launchThread(draft, text: "Fix the login redirect", attachments: [])
        let temporary = try #require(engine.thread(threadID)?.branch)
        #expect(temporary.wholeMatch(of: /soprano\/[0-9a-f]{8}/) != nil)
        #expect(engine.thread(threadID)?.isRunning == true)

        await engine.runtime.waitForBackgroundWork()

        let thread = try #require(engine.thread(threadID))
        #expect(git.calls.contains("worktree main \(temporary)"))
        #expect(git.calls.contains("rename \(temporary) -> soprano/fix-login-redirect"))
        #expect(thread.worktreePath == "\(worktrees)/repo/\(temporary.replacingOccurrences(of: "/", with: "-"))")
        #expect(thread.branch == "soprano/fix-login-redirect")
        #expect(driver.session?.configs.first?.cwd == thread.worktreePath)
        #expect(driver.session?.turns.map(\.text) == ["Fix the login redirect"])
    }

    @Test func launchingInTheProjectRootRecordsTheCheckedOutBranch() async throws {
        let driver = ScriptedDriver()
        let git = RecordingGit()
        git.currentBranch = "develop"
        let engine = EngineHarness.engine(driver: driver, git: git)
        let project = engine.addProject(path: Self.repository())
        let draft = ThreadDraft(projectID: project.id, modelSelection: .default(for: .omp), runtimeMode: .approvalRequired)

        let threadID = try await engine.launchThread(draft, text: "Do it here", attachments: [])
        await engine.runtime.waitForBackgroundWork()

        let thread = try #require(engine.thread(threadID))
        #expect(thread.branch == "develop")
        #expect(thread.worktreePath == nil)
        #expect(thread.title == "Do it here")
        #expect(driver.session?.configs.first?.runtimeMode == .approvalRequired)
        #expect(!git.calls.contains { $0.hasPrefix("worktree") })
    }

    @Test func aWorktreeThatCannotBeCreatedFailsTheFirstTurnWithoutStartingTheProvider() async throws {
        let driver = ScriptedDriver()
        let git = RecordingGit()
        git.worktreeError = EngineError.message("fatal: invalid reference: nope")
        let engine = EngineHarness.engine(driver: driver, git: git)
        let project = engine.addProject(path: Self.repository())
        let draft = ThreadDraft(projectID: project.id, modelSelection: .default(for: .omp), workspace: .newWorktree(baseBranch: "nope"))

        let threadID = try await engine.launchThread(draft, text: "Do it", attachments: [])
        await engine.runtime.waitForBackgroundWork()

        let turn = try #require(engine.thread(threadID)?.turns.first)
        #expect(turn.status == .failed)
        #expect(turn.failureMessage == "fatal: invalid reference: nope")
        #expect(driver.sessions.isEmpty)
    }

    @Test func interruptingBeforeWorktreeSetupStopsTheLaunchWithoutCreatingIt() async throws {
        let driver = ScriptedDriver()
        let git = RecordingGit()
        let engine = EngineHarness.engine(driver: driver, git: git)
        let project = engine.addProject(path: Self.repository())
        let draft = ThreadDraft(projectID: project.id, modelSelection: .default(for: .omp), workspace: .newWorktree(baseBranch: "main"))

        let threadID = try await engine.launchThread(draft, text: "Do it", attachments: [])
        await engine.interrupt(threadID)
        await engine.runtime.waitForBackgroundWork()

        #expect(engine.thread(threadID)?.turns.first?.status == .interrupted)
        #expect(driver.sessions.isEmpty)
        #expect(git.calls.isEmpty)
    }

    @Test func quittingDuringWorktreeSetupWaitsForItsRollbackBeforeReturning() async throws {
        let git = RecordingGit()
        let entered = Gate()
        let cleanup = Gate()
        let rolledBack = Gate()
        // Like `LiveGitService`: cancelled setup removes what it made before it returns.
        git.worktreeGate = {
            entered.open()
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(2)) }
            await cleanup.wait()
            rolledBack.open()
            throw CancellationError()
        }
        let engine = EngineHarness.engine(git: git)
        let project = engine.addProject(path: Self.repository())
        let draft = ThreadDraft(projectID: project.id, modelSelection: .default(for: .omp), workspace: .newWorktree(baseBranch: "main"))
        _ = try await engine.launchThread(draft, text: "Do it", attachments: [])
        await entered.wait()

        // What the app sees when `shutdown` returns and it approves termination.
        let quit = Task { await engine.shutdown(); return rolledBack.isOpen }
        try await Task.sleep(for: .milliseconds(200))
        cleanup.open()

        #expect(await quit.value)
    }

    @Test func theGeneratedTitleReplacesTheSeedWhileTheUserHasNotRenamedTheThread() async throws {
        let driver = ScriptedDriver()
        driver.generate = { _ in .object(["title": .string("'Login Redirect Loop'"), "needsRefinement": .bool(false)]) }
        let engine = EngineHarness.engine(driver: driver, settings: EngineSettings(generateTitles: true))
        let draft = ThreadDraft(projectID: nil, modelSelection: .default(for: .omp))

        let threadID = try await engine.launchThread(draft, text: "the login page keeps redirecting to itself", attachments: [])
        #expect(engine.thread(threadID)?.title == "the login page keeps redirecting to itself")
        #expect(engine.thread(threadID)?.isGeneratingTitle == true)
        await engine.runtime.waitForBackgroundWork()

        #expect(engine.thread(threadID)?.title == "Login Redirect Loop")
        #expect(engine.thread(threadID)?.isGeneratingTitle == false)
        #expect(driver.prompts.first?.contains("User message:\nthe login page keeps redirecting to itself") == true)
    }

    @Test func aFailedTitleGenerationKeepsTheSeedAfterRetrying() async throws {
        let driver = ScriptedDriver()
        let engine = EngineHarness.engine(driver: driver, settings: EngineSettings(generateTitles: true))
        let draft = ThreadDraft(projectID: nil, modelSelection: .default(for: .omp))

        let threadID = try await engine.launchThread(draft, text: "hello there", attachments: [])
        await engine.runtime.waitForBackgroundWork()

        #expect(engine.thread(threadID)?.title == "hello there")
        #expect(engine.thread(threadID)?.isGeneratingTitle == false)
        #expect(driver.prompts.count == 3)
    }

    @Test func scratchThreadsGetTheirOwnDirectory() async throws {
        let driver = ScriptedDriver()
        let engine = EngineHarness.engine(driver: driver)
        let draft = ThreadDraft(projectID: nil, modelSelection: .default(for: .omp))

        let threadID = try await engine.launchThread(draft, text: "scratch", attachments: [])
        await engine.runtime.waitForBackgroundWork()

        let cwd = try #require(driver.session?.configs.first?.cwd)
        #expect(cwd == engine.environment.dataDirectory.appendingPathComponent("scratch/\(threadID)").path)
        #expect(FileManager.default.fileExists(atPath: cwd))
    }

    @Test func regeneratingATitleSendsTheTranscript() async throws {
        let driver = ScriptedDriver()
        driver.generate = { _ in .object(["title": .string("Better Title"), "needsRefinement": .bool(false)]) }
        let engine = EngineHarness.engine(driver: driver)
        let threadID = EngineHarness.idleThread(in: engine)
        try await engine.send(threadID, text: "why is it slow", attachments: [])
        driver.session?.emit(.assistantDelta(itemID: "m", delta: "The cache is cold.", isFinal: true))
        driver.session?.emit(.turnCompleted(outcome: .completed, error: nil))
        #expect(await EngineHarness.eventually { engine.thread(threadID)?.isRunning == false })

        await engine.regenerateTitle(threadID)

        #expect(engine.thread(threadID)?.title == "Better Title")
        let prompt = try #require(driver.prompts.last)
        #expect(prompt.contains("The previous title was \"Thread\"."))
        #expect(prompt.contains("Thread contents:\nUSER:\nwhy is it slow\n\nASSISTANT:\nThe cache is cold."))
    }
}
