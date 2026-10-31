import Foundation
import SopranoAgentsCore

/// Deterministic sample state for the snapshot harness and UI tests. Every item kind the
/// timeline renders appears at least once. Times are relative to `now`.
@MainActor
enum DemoFixtures {
    /// Scenario names accepted by `snapshot --fixture`.
    static let scenarios = ["demo", "running", "stopping", "approval", "input", "failed", "background", "answered", "subagents", "subagent", "draft", "empty"]

    struct Built {
        let engine: AgentEngine
        let selection: WorkspaceState.Selection
    }

    static func build(_ scenario: String, now: Date = Date()) throws -> Built {
        guard scenarios.contains(scenario) else {
            throw FixtureError(message: "Unknown fixture \"\(scenario)\". Known: \(scenarios.joined(separator: ", ")).")
        }
        let extra: [AgentThread] = switch scenario {
        case "background": [backgroundThread(now)]
        case "answered": [answeredThread(now)]
        case "subagents", "subagent": [subagentsThread(now)]
        default: []
        }
        var sample = threads(now) + extra
        if scenario == "stopping", let index = sample.firstIndex(where: { $0.id == ID.running }) {
            sample[index].turns[sample[index].turns.count - 1].stopRequestedAt = now.addingTimeInterval(-2)
        }
        let snapshot = scenario == "empty" ? StoreSnapshot() : StoreSnapshot(projects: projects(now), threads: sample)
        let dataDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("soprano-agents-fixture", isDirectory: true)
        let environment = EngineEnvironment(
            drivers: [:],
            git: FixtureGitService(),
            store: InMemoryThreadStore(snapshot),
            dataDirectory: dataDirectory,
            files: FixtureWorkspaceFiles(),
            usage: FixtureUsageStatistics(now: now),
            now: { now }
        )
        let engine = AgentEngine(environment: environment)
        engine.setProviderStatus(ProviderStatus(kind: .omp, health: .ready, version: "18.14.0", models: ompModels))
        // The `/` menu's list for omp in the demo thread's worktree and in the app project (drafts).
        for directory in [demoWorktree, "/Users/demo/code/app"] {
            engine.rememberCommands(ompCommands, provider: .omp, workingDirectory: directory)
        }
        let selection: WorkspaceState.Selection = switch scenario {
        case "running", "stopping": .thread(ID.running)
        case "approval": .thread(ID.approval)
        case "input": .thread(ID.input)
        case "failed": .thread(ID.failed)
        case "background": .thread(ID.background)
        case "answered": .thread(ID.answered)
        case "subagents": .thread(ID.subagents)
        case "subagent": .subagent(threadID: ID.subagents, subagentID: "Reader")
        case "draft": .draft(projectID: ID.app)
        case "empty": .draft(projectID: nil)
        default: .thread(ID.demo)
        }
        return Built(engine: engine, selection: selection)
    }

    static let demoWorktree = "/Users/demo/.soprano-agents/worktrees/app/soprano-fix-login-redirect"

    /// A slice of omp's `get_available_commands`: built-ins, an extension command and skills.
    static let ompCommands: [ProviderCommand] = [
        ProviderCommand(name: "compact", kind: .command, description: "Summarize earlier messages to free context", argumentHint: "[focus]", source: "Built-in", insertText: "/compact "),
        ProviderCommand(name: "double-check", kind: .command, description: "Re-check the last answer with a second model", source: "Extension", insertText: "/double-check "),
        ProviderCommand(name: "handoff", kind: .command, description: "Write a handoff note and start a fresh session", argumentHint: "[goal]", source: "Built-in", insertText: "/handoff "),
        ProviderCommand(name: "model", kind: .command, description: "Switch the model for this session", argumentHint: "<provider/id>", source: "Built-in", insertText: "/model "),
        ProviderCommand(name: "plan", kind: .command, description: "Plan before making changes", source: "Built-in", insertText: "/plan "),
        ProviderCommand(name: "review", kind: .command, description: "Review the working tree changes", argumentHint: "[path]", source: "Built-in", insertText: "/review "),
        ProviderCommand(name: "skill:pr", kind: .skill, description: "Write pull request descriptions and commit messages", source: "Skill", insertText: "/skill:pr "),
        ProviderCommand(name: "skill:refactor", kind: .skill, description: "Restructure code without changing behavior, one safe step at a time", source: "Skill", insertText: "/skill:refactor "),
    ]

    struct FixtureError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    enum ID {
        static let app = "project-app"
        static let soprano = "project-soprano"
        static let site = "project-site"
        static let demo = "thread-login"
        static let running = "thread-dark-mode"
        static let approval = "thread-jsonc"
        static let input = "thread-flaky"
        static let failed = "thread-renderer"
        static let pinned = "thread-release"
        static let scratch = "thread-scratch"
        static let background = "thread-background"
        static let answered = "thread-answered"
        static let subagents = "thread-subagents"
    }

    static func projects(_ now: Date) -> [Project] {
        [
            Project(id: ID.app, title: "app", path: "/Users/demo/code/app", createdAt: now.addingTimeInterval(-86400 * 30), scripts: [
                ProjectScript(id: "test", name: "Test", command: "swift test", icon: .test),
                ProjectScript(id: "dev", name: "Dev", command: "./scripts/dev.sh", icon: .play),
            ]),
            Project(id: ID.soprano, title: "soprano", path: "/Users/demo/code/soprano", createdAt: now.addingTimeInterval(-86400 * 20)),
            Project(id: ID.site, title: "site", path: "/Users/demo/code/site", createdAt: now.addingTimeInterval(-86400 * 10)),
        ]
    }

    static let omp = ModelSelection(provider: .omp, model: "anthropic/claude-opus-5-5", options: [ModelOptionID.effort: "high"])
    static let sonnet = ModelSelection(provider: .omp, model: "anthropic/claude-sonnet-5-5", options: [ModelOptionID.effort: "medium"])
    static let sol = ModelSelection(provider: .omp, model: "openai-codex/gpt-6.1-sol", options: [ModelOptionID.effort: "high"])

    /// A slice of omp's catalog as `get_available_models` reports it (`provider/id`, "<name> · <provider>").
    static let ompModels: [ProviderModel] = {
        let efforts = ProviderCatalog.effortOption(["off", "low", "medium", "high", "xhigh", "max"], default: "high")
        let entries: [(String, String)] = [
            ("anthropic/claude-opus-5-5", "Claude Opus 5.5 · anthropic"),
            ("anthropic/claude-sonnet-5-5", "Claude Sonnet 5.5 · anthropic"),
            ("anthropic/claude-haiku-5-5", "Claude Haiku 5.5 · anthropic"),
            ("openai-codex/gpt-6.1-sol", "GPT-6.1 Sol · openai-codex"),
            ("github-copilot/gpt-6-luna", "GPT-6 Luna · github-copilot"),
            ("openrouter/qwen/qwen3-coder", "Qwen3 Coder · openrouter"),
        ]
        return [ProviderModel(slug: ModelSelection.ompDefaultModel, name: "Claude Opus 5.5 · configured", isDefault: true, options: [efforts])]
            + entries.map { ProviderModel(slug: $0.0, name: $0.1, options: [efforts]) }
    }()

    static func threads(_ now: Date) -> [AgentThread] {
        func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
        var result: [AgentThread] = []

        // 1. Completed thread with every common item kind (selected in "demo").
        let loginTurn1 = Turn(
            id: "turn-login-1",
            ordinal: 1,
            userMessage: UserMessage(id: "msg-login-1", text: "Users get stuck in a redirect loop after logging in with SSO. Find out why and fix it, with a regression test.", createdAt: ago(1500)),
            modelSelection: omp,
            status: .completed,
            startedAt: ago(1500),
            completedAt: ago(1308),
            items: [
                TurnItem(id: "r1", kind: .reasoning(text: "**Tracing the redirect.** The loop likely comes from the session cookie not being set before the redirect to `/dashboard`."), status: .completed, startedAt: ago(1499), completedAt: ago(1495)),
                TurnItem(id: "c1", kind: .command(CommandExecution(command: "rg -n \"redirectAfterLogin\" Sources", cwd: "/Users/demo/code/app", output: "Sources/Auth/LoginController.swift:42:    redirectAfterLogin(to: target)\nSources/Auth/LoginController.swift:88:  func redirectAfterLogin(to target: URL) {", exitCode: 0, durationMs: 120)), status: .completed, startedAt: ago(1494), completedAt: ago(1493)),
                TurnItem(id: "t1", kind: .toolCall(ToolCall(name: "Read", category: .read, title: "Read Sources/Auth/LoginController.swift")), status: .completed, startedAt: ago(1492), completedAt: ago(1491)),
                TurnItem(id: "t2", kind: .toolCall(ToolCall(name: "Read", category: .read, title: "Read Sources/Auth/SessionStore.swift")), status: .completed, startedAt: ago(1490), completedAt: ago(1489)),
                TurnItem(id: "a1", kind: .assistantMessage(text: "The session is persisted asynchronously, so the dashboard request races the cookie write. I'll await the store before redirecting.", isFinal: false), status: .completed, startedAt: ago(1480), completedAt: ago(1479)),
                TurnItem(id: "f1", kind: .fileChange([
                    FileChange(path: "Sources/Auth/LoginController.swift", kind: .update, diff: sampleDiff),
                    FileChange(path: "Sources/Auth/SessionStore.swift", kind: .update),
                ]), status: .completed, startedAt: ago(1470), completedAt: ago(1468)),
                TurnItem(id: "f2", kind: .fileChange([FileChange(path: "Tests/AuthTests/LoginRedirectTests.swift", kind: .add)]), status: .completed, startedAt: ago(1460), completedAt: ago(1459)),
                TurnItem(id: "c2", kind: .command(CommandExecution(command: "swift test --filter LoginRedirectTests", cwd: "/Users/demo/code/app", output: "Test Suite 'LoginRedirectTests' passed.\n  Executed 3 tests, with 0 failures in 0.412 seconds", exitCode: 0, durationMs: 18_400)), status: .completed, startedAt: ago(1440), completedAt: ago(1421)),
                TurnItem(id: "w1", kind: .webSearch(query: "ASWebAuthenticationSession cookie timing"), status: .completed, startedAt: ago(1415), completedAt: ago(1412)),
                TurnItem(id: "a2", kind: .assistantMessage(text: loginAnswer, isFinal: true), status: .completed, startedAt: ago(1320), completedAt: ago(1308)),
            ],
            checkpoint: TurnCheckpoint(ref: CheckpointRef.ref(threadID: ID.demo, ordinal: 1), status: .ready, files: [
                ChangedFileStat(path: "Sources/Auth/LoginController.swift", additions: 18, deletions: 6),
                ChangedFileStat(path: "Sources/Auth/SessionStore.swift", additions: 9, deletions: 2),
                ChangedFileStat(path: "Tests/AuthTests/LoginRedirectTests.swift", additions: 41, deletions: 0),
            ])
        )
        let loginTurn2 = Turn(
            id: "turn-login-2",
            ordinal: 2,
            userMessage: UserMessage(id: "msg-login-2", text: "Nice. Also log the redirect target at debug level.", createdAt: ago(600)),
            modelSelection: omp,
            status: .completed,
            startedAt: ago(600),
            completedAt: ago(548),
            items: [
                TurnItem(id: "f3", kind: .fileChange([FileChange(path: "Sources/Auth/LoginController.swift", kind: .update)]), status: .completed, startedAt: ago(590), completedAt: ago(589)),
                TurnItem(id: "a3", kind: .assistantMessage(text: "Added a `logger.debug(\"Redirecting to \\(target, privacy: .public)\")` call right before the redirect.", isFinal: true), status: .completed, startedAt: ago(560), completedAt: ago(548)),
            ],
            checkpoint: TurnCheckpoint(ref: CheckpointRef.ref(threadID: ID.demo, ordinal: 2), status: .ready, files: [
                ChangedFileStat(path: "Sources/Auth/LoginController.swift", additions: 2, deletions: 0),
            ])
        )
        var login = AgentThread(
            id: ID.demo, projectID: ID.app, title: "Fix SSO login redirect loop", createdAt: ago(1500), updatedAt: ago(548),
            modelSelection: omp, branch: "soprano/fix-login-redirect", worktreePath: demoWorktree,
            lastVisitedAt: ago(30), providerThreadID: "01a18ca6-e395-70f2-aa8c-32a625c98cc3", turns: [loginTurn1, loginTurn2]
        )
        login.contextUsage = TokenUsage(usedTokens: 124_000, contextWindow: 200_000)
        result.append(login)

        // 2. Running thread with a live command (Working).
        result.append(AgentThread(
            id: ID.running, projectID: ID.app, title: "Add dark mode toggle to settings", createdAt: ago(200), updatedAt: ago(5),
            modelSelection: sonnet, branch: "soprano/dark-mode-toggle", worktreePath: "/Users/demo/.soprano-agents/worktrees/app/soprano-dark-mode-toggle",
            lastVisitedAt: ago(100),
            turns: [Turn(
                id: "turn-dark-1", ordinal: 1,
                userMessage: UserMessage(text: "Add a dark mode toggle to the settings screen that follows the system by default.", createdAt: ago(134)),
                modelSelection: sonnet, status: .running, startedAt: ago(134),
                items: [
                    TurnItem(id: "dr1", kind: .reasoning(text: "Looking for the settings screen and how themes are applied."), status: .completed, startedAt: ago(132), completedAt: ago(128)),
                    TurnItem(id: "dt1", kind: .toolCall(ToolCall(name: "Grep", category: .search, title: "Searched \"ThemeManager\" in Sources")), status: .completed, startedAt: ago(127), completedAt: ago(126)),
                    TurnItem(id: "df1", kind: .fileChange([FileChange(path: "Sources/Settings/AppearanceSection.swift", kind: .add)]), status: .completed, startedAt: ago(90), completedAt: ago(88)),
                    TurnItem(id: "dc1", kind: .command(CommandExecution(command: "swift build", cwd: "/Users/demo/code/app", output: "Compiling App AppearanceSection.swift\n")), status: .running, startedAt: ago(12)),
                ]
            )]
        ))

        // 3. Waiting on a command approval (Approval).
        result.append(AgentThread(
            id: ID.approval, projectID: ID.soprano, title: "Migrate settings to JSONC", createdAt: ago(900), updatedAt: ago(40),
            modelSelection: sol, runtimeMode: .approvalRequired, branch: "main", lastVisitedAt: ago(60),
            turns: [Turn(
                id: "turn-jsonc-1", ordinal: 1,
                userMessage: UserMessage(text: "Switch the settings parser to JSONC so comments survive saves.", createdAt: ago(120)),
                modelSelection: sol, status: .running, startedAt: ago(120),
                items: [
                    TurnItem(id: "ja1", kind: .assistantMessage(text: "I'll add the parser and run the existing settings tests first.", isFinal: false), status: .completed, startedAt: ago(110), completedAt: ago(109)),
                    TurnItem(id: "approval-1", kind: .approval(ApprovalRequest(id: "approval-1", kind: .command, detail: "swift test --filter SettingsTests", reason: "Run the settings test suite"))),
                ]
            )]
        ))

        // 4. Waiting on answers (Input).
        result.append(AgentThread(
            id: ID.input, projectID: ID.app, title: "Investigate flaky upload test", createdAt: ago(3000), updatedAt: ago(300),
            modelSelection: sonnet, lastVisitedAt: ago(400),
            turns: [Turn(
                id: "turn-flaky-1", ordinal: 1,
                userMessage: UserMessage(text: "UploadTests.testResume fails about 1 in 10 runs on CI. Dig in.", createdAt: ago(900)),
                modelSelection: sonnet, status: .running, startedAt: ago(900),
                items: [
                    TurnItem(id: "fi1", kind: .command(CommandExecution(command: "for i in $(seq 20); do swift test --filter testResume || break; done", output: "…\nTest Case 'UploadTests.testResume' failed (2.104 seconds).", exitCode: 1, durationMs: 41_000)), status: .failed, startedAt: ago(880), completedAt: ago(839)),
                    TurnItem(id: "fq1", kind: .userInput(UserInputRequest(id: "input-1", questions: [
                        UserInputQuestion(id: "q1", header: "Fix approach", question: "The race is between the resume request and the chunk cache flush. How should I fix it?", options: [
                            UserInputOption(label: "Await the flush", description: "Simplest; adds ~20 ms to resume"),
                            UserInputOption(label: "Serialize on an actor", description: "Moves the cache behind an actor"),
                            UserInputOption(label: "Retry in the test", description: "Hides the race; not recommended"),
                        ]),
                    ]))),
                ]
            )]
        ))

        // 5. Failed turn (Failed).
        result.append(AgentThread(
            id: ID.failed, projectID: ID.soprano, title: "Refactor diff renderer", createdAt: ago(10000), updatedAt: ago(5000),
            modelSelection: sol, lastVisitedAt: ago(9000),
            turns: [Turn(
                id: "turn-renderer-1", ordinal: 1,
                userMessage: UserMessage(text: "Split DiffRows.swift into one file per row type.", createdAt: ago(5200)),
                modelSelection: sol, status: .failed, failureMessage: "omp exited unexpectedly (exit code 1).", startedAt: ago(5200), completedAt: ago(5000),
                items: [TurnItem(id: "fe1", kind: .error(message: "omp exited unexpectedly (exit code 1)."), status: .failed, startedAt: ago(5000), completedAt: ago(5000))]
            )]
        ))

        // 6. Pinned, unread completion (Done).
        result.append(AgentThread(
            id: ID.pinned, projectID: ID.app, title: "Release checklist for 2.4", createdAt: ago(86400 * 2), updatedAt: ago(7200),
            modelSelection: sol, pinnedAt: ago(86400), lastVisitedAt: ago(86400),
            turns: [Turn(
                ordinal: 1, userMessage: UserMessage(text: "Draft the 2.4 release checklist.", createdAt: ago(7400)),
                modelSelection: sol, status: .completed, startedAt: ago(7400), completedAt: ago(7200),
                items: [TurnItem(id: "rc1", kind: .assistantMessage(text: "Here's the checklist:\n\n- [ ] Bump versions\n- [ ] Changelog\n- [ ] Tag", isFinal: true), status: .completed)]
            )]
        ))

        // 7. Scratch thread without a project.
        result.append(AgentThread(
            id: ID.scratch, projectID: nil, title: "Explain Swift actors vs locks", createdAt: ago(86400 * 3), updatedAt: ago(86400 * 3),
            modelSelection: sonnet, lastVisitedAt: ago(86400),
            turns: [Turn(
                ordinal: 1, userMessage: UserMessage(text: "When should I use an actor instead of a lock?", createdAt: ago(86400 * 3)),
                modelSelection: sonnet, status: .completed, startedAt: ago(86400 * 3), completedAt: ago(86400 * 3 - 40),
                items: [TurnItem(id: "sa1", kind: .assistantMessage(text: "Use an actor when the state is accessed from async code…", isFinal: true), status: .completed)]
            )]
        ))

        // 8. Settled history.
        let settledTitles = ["Bump swift-markdown to 0.8", "Fix terminal resize flicker", "Add CHANGELOG entry", "Rename AgentManager APIs", "Document keybindings"]
        for (index, title) in settledTitles.enumerated() {
            let created = ago(Double(86400 * (4 + index)))
            result.append(AgentThread(
                id: "thread-settled-\(index)", projectID: index.isMultiple(of: 2) ? ID.soprano : ID.app, title: title, createdAt: created, updatedAt: created,
                modelSelection: index.isMultiple(of: 2) ? sol : sonnet, settledAt: created.addingTimeInterval(3600), lastVisitedAt: created.addingTimeInterval(3600),
                turns: [Turn(ordinal: 1, userMessage: UserMessage(text: title, createdAt: created), modelSelection: sol, status: .completed, startedAt: created, completedAt: created.addingTimeInterval(300))]
            ))
        }

        // 9. Archived (Settings › Archive).
        let archived: [(String, String?, Double, Double)] = [
            ("Prototype onboarding carousel", ID.app, 86400 * 2, 86400 * 12),
            ("Try SwiftData for thread storage", ID.soprano, 86400 * 6, 86400 * 15),
            ("Sketch a pricing page", nil, 86400 * 9, 86400 * 20),
        ]
        for (index, (title, projectID, archivedAgo, createdAgo)) in archived.enumerated() {
            let created = ago(createdAgo)
            result.append(AgentThread(
                id: "thread-archived-\(index)", projectID: projectID, title: title, createdAt: created, updatedAt: created,
                modelSelection: sol, archivedAt: ago(archivedAgo), lastVisitedAt: created.addingTimeInterval(600),
                turns: [Turn(ordinal: 1, userMessage: UserMessage(text: title, createdAt: created), modelSelection: sol, status: .completed, startedAt: created, completedAt: created.addingTimeInterval(240))]
            ))
        }
        return result
    }

    /// An omp turn that yielded while a background job it started still runs ("background"
    /// scenario only): its answer is final, a muted note says the job is still running.
    static func backgroundThread(_ now: Date) -> AgentThread {
        func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
        return AgentThread(
            id: ID.background, projectID: ID.app, title: "Run the test suite in the background", createdAt: ago(400), updatedAt: ago(60),
            modelSelection: omp, branch: "main", lastVisitedAt: ago(30),
            turns: [Turn(
                id: "turn-background-1", ordinal: 1,
                userMessage: UserMessage(text: "Start the full test suite as a background job, then tighten the retry delay in UploadClient.", createdAt: ago(300)),
                modelSelection: omp, status: .running, startedAt: ago(300),
                items: [
                    TurnItem(id: "bg1", kind: .command(CommandExecution(command: "swift test", cwd: "/Users/demo/code/app", output: "Started background job bg-1\n", exitCode: 0, durationMs: 140)), status: .completed, startedAt: ago(280), completedAt: ago(279)),
                    TurnItem(id: "bg2", kind: .fileChange([FileChange(path: "Sources/Upload/UploadClient.swift", kind: .update)]), status: .completed, startedAt: ago(250), completedAt: ago(249)),
                    TurnItem(id: "bg3", kind: .assistantMessage(text: "The retry delay now starts at 250 ms and doubles up to 4 s. The full test suite is still running in the background; I'll report back when it finishes.", isFinal: false), status: .completed, startedAt: ago(240), completedAt: ago(232)),
                ],
                yieldedAt: ago(232)
            )]
        )
    }

    /// An omp turn whose final answer arrived while omp still wraps up (advisor review, stop
    /// hooks) before `prompt_result` ("answered" scenario only): still running, no "Thinking".
    static func answeredThread(_ now: Date) -> AgentThread {
        func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
        return AgentThread(
            id: ID.answered, projectID: ID.app, title: "Tighten the upload retry delay", createdAt: ago(200), updatedAt: ago(5),
            modelSelection: omp, branch: "main", lastVisitedAt: ago(5),
            turns: [Turn(
                id: "turn-answered-1", ordinal: 1,
                userMessage: UserMessage(text: "Tighten the retry delay in UploadClient.", createdAt: ago(60)),
                modelSelection: omp, status: .running, startedAt: ago(60),
                items: [
                    TurnItem(id: "an1", kind: .fileChange([FileChange(path: "Sources/Upload/UploadClient.swift", kind: .update)]), status: .completed, startedAt: ago(40), completedAt: ago(39)),
                    TurnItem(id: "an2", kind: .assistantMessage(text: "The retry delay now starts at 250 ms and doubles up to 4 s.", isFinal: true), status: .completed, startedAt: ago(10), completedAt: ago(8)),
                ]
            )]
        )
    }

    /// A yielded omp turn whose agent started two subagents ("subagents" selects the thread,
    /// "subagent" its running subagent Reader): Reader still works (steered once), Scout is done.
    static func subagentsThread(_ now: Date) -> AgentThread {
        func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
        let reader = Subagent(
            id: "Reader", agent: "sonic",
            assignment: "Read Sources/Upload/UploadClient.swift and UploadTests.swift, then list every retry path.",
            status: .running, model: "anthropic/claude-haiku-5-5", lastIntent: "Reading UploadTests.swift",
            parentToolCallID: "task-1", isDetached: true, startedAt: ago(90), updatedAt: ago(4),
            turns: [Turn(
                id: "reader-1", ordinal: 1,
                userMessage: UserMessage(text: "Complete assignment thoroughly:\n\nRead Sources/Upload/UploadClient.swift and UploadTests.swift, then list every retry path.", createdAt: ago(88)),
                modelSelection: omp, status: .running, startedAt: ago(88),
                items: [
                    TurnItem(id: "r1", kind: .assistantMessage(text: "I'll read both files.", isFinal: false), status: .completed, startedAt: ago(80), completedAt: ago(79)),
                    TurnItem(id: "r2", kind: .command(CommandExecution(command: "sed -n 1,120p Sources/Upload/UploadClient.swift", cwd: "/Users/demo/code/app", output: "import Foundation\n", exitCode: 0, durationMs: 12)), status: .completed, startedAt: ago(70), completedAt: ago(70)),
                    TurnItem(id: "r3", kind: .toolCall(ToolCall(name: "read", category: .read, title: "Read Tests/UploadTests.swift")), status: .running, startedAt: ago(4)),
                ],
                steers: [UserMessage(text: "Also note which paths have no test.", createdAt: ago(30), isSteer: true)]
            )]
        )
        let scout = Subagent(
            id: "Scout", agent: "scout", description: "Map the upload client",
            assignment: "Find every caller of UploadClient.retry.",
            status: .completed, model: "anthropic/claude-haiku-5-5", lastIntent: "Searching callers",
            parentToolCallID: "task-1", isDetached: true, startedAt: ago(90), updatedAt: ago(60), completedAt: ago(60),
            turns: [Turn(
                id: "scout-1", ordinal: 1,
                userMessage: UserMessage(text: "Find every caller of UploadClient.retry.", createdAt: ago(88)),
                modelSelection: omp, status: .completed, startedAt: ago(88), completedAt: ago(60),
                items: [
                    TurnItem(id: "s1", kind: .toolCall(ToolCall(name: "grep", category: .search, title: "Searched retry( in Sources")), status: .completed, startedAt: ago(80), completedAt: ago(79)),
                    TurnItem(id: "s2", kind: .assistantMessage(text: "Two callers: `UploadQueue.resume()` and `BackgroundUploader.handle(_:)`.", isFinal: true), status: .completed, startedAt: ago(62), completedAt: ago(60)),
                ]
            )]
        )
        return AgentThread(
            id: ID.subagents, projectID: ID.app, title: "Audit the upload retry paths", createdAt: ago(120), updatedAt: ago(4),
            modelSelection: omp, branch: "main", lastVisitedAt: ago(4),
            turns: [Turn(
                id: "turn-subagents-1", ordinal: 1,
                userMessage: UserMessage(text: "Audit every retry path in the upload client. Use helpers for the reading.", createdAt: ago(100)),
                modelSelection: omp, status: .running, startedAt: ago(100),
                items: [
                    TurnItem(id: "sa1", kind: .toolCall(ToolCall(name: "task", category: .subagent, title: "Subagent: Reader, Scout")), status: .completed, startedAt: ago(92), completedAt: ago(90)),
                    TurnItem(id: "sa2", kind: .assistantMessage(text: "Reader and Scout are on it; I'll combine their findings when they report back.", isFinal: false), status: .completed, startedAt: ago(89), completedAt: ago(86)),
                ],
                yieldedAt: ago(86)
            )],
            subagents: [reader, scout]
        )
    }

    nonisolated static let loginAnswer = """
    Fixed. The loop came from a race between the session write and the redirect:

    1. `SessionStore.persist(_:)` wrote the cookie on a background queue.
    2. `LoginController` redirected to `/dashboard` immediately, before the cookie existed.
    3. The dashboard saw no session and bounced back to `/login`.

    ### Changes

    - `SessionStore.persist(_:)` is now `async` and returns after the cookie is stored.
    - `LoginController.redirectAfterLogin(to:)` awaits it before redirecting:

    ```swift
    func redirectAfterLogin(to target: URL) async {
        await sessionStore.persist(session)
        router.replace(with: target)
    }
    ```

    | Test | Result |
    |---|---|
    | `testRedirectWaitsForSession` | passed |
    | `testRedirectKeepsDeepLink` | passed |

    Run `swift test --filter LoginRedirectTests` to check it yourself.
    """

    nonisolated static let sampleDiff = """
    diff --git a/Sources/Auth/LoginController.swift b/Sources/Auth/LoginController.swift
    index 3f2a1c9..8b7d6e2 100644
    --- a/Sources/Auth/LoginController.swift
    +++ b/Sources/Auth/LoginController.swift
    @@ -84,12 +84,16 @@ final class LoginController {
         private let router: Router
         private let sessionStore: SessionStore
     
    -    func redirectAfterLogin(to target: URL) {
    -        sessionStore.persist(session)
    -        router.replace(with: target)
    +    func redirectAfterLogin(to target: URL) async {
    +        // The dashboard reads the cookie; it must exist before we leave.
    +        await sessionStore.persist(session)
    +        logger.debug("Redirecting to \\(target, privacy: .public)")
    +        router.replace(with: target)
         }
     
         func handleCallback(_ url: URL) {
    -        redirectAfterLogin(to: url.deepLinkTarget ?? .dashboard)
    +        Task {
    +            await redirectAfterLogin(to: url.deepLinkTarget ?? .dashboard)
    +        }
         }
     }
    diff --git a/Sources/Auth/SessionStore.swift b/Sources/Auth/SessionStore.swift
    index 1c2d3e4..5f6a7b8 100644
    --- a/Sources/Auth/SessionStore.swift
    +++ b/Sources/Auth/SessionStore.swift
    @@ -12,9 +12,9 @@ final class SessionStore {
    -    func persist(_ session: Session) {
    -        queue.async { self.cookies.store(session.cookie) }
    +    func persist(_ session: Session) async {
    +        await cookies.store(session.cookie)
         }
    diff --git a/Tests/AuthTests/LoginRedirectTests.swift b/Tests/AuthTests/LoginRedirectTests.swift
    new file mode 100644
    index 0000000..9a8b7c6
    --- /dev/null
    +++ b/Tests/AuthTests/LoginRedirectTests.swift
    @@ -0,0 +1,8 @@
    +import Testing
    +@testable import App
    +
    +@Test func redirectWaitsForSession() async {
    +    let controller = LoginController.fixture()
    +    await controller.redirectAfterLogin(to: .dashboard)
    +    #expect(controller.sessionStore.hasCookie)
    +}

    """
}
