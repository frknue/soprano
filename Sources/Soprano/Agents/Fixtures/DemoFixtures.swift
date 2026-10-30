import Foundation
import SopranoAgentsCore

/// Deterministic sample state for the snapshot harness and UI tests. Every item kind the
/// timeline renders appears at least once. Times are relative to `now`.
@MainActor
enum DemoFixtures {
    /// Scenario names accepted by `snapshot --fixture`.
    static let scenarios = ["demo", "running", "approval", "input", "plan", "failed", "draft", "empty"]

    struct Built {
        let engine: AgentEngine
        let selection: WorkspaceState.Selection
    }

    static func build(_ scenario: String, now: Date = Date()) throws -> Built {
        guard scenarios.contains(scenario) else {
            throw FixtureError(message: "Unknown fixture \"\(scenario)\". Known: \(scenarios.joined(separator: ", ")).")
        }
        let snapshot = scenario == "empty" ? StoreSnapshot() : StoreSnapshot(projects: projects(now), threads: threads(now))
        let dataDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("soprano-agents-fixture", isDirectory: true)
        let environment = EngineEnvironment(
            drivers: [:],
            git: FixtureGitService(),
            store: InMemoryThreadStore(snapshot),
            dataDirectory: dataDirectory,
            now: { now }
        )
        let engine = AgentEngine(environment: environment)
        for kind in ProviderKind.allCases {
            engine.setProviderStatus(ProviderStatus(
                kind: kind,
                health: .ready,
                version: kind == .codex ? "0.166.0" : "2.1.314",
                accountLabel: kind == .codex ? "ChatGPT Pro 100 Subscription" : "Claude Max",
                models: ProviderCatalog.fallback(kind)
            ))
        }
        let selection: WorkspaceState.Selection = switch scenario {
        case "running": .thread(ID.running)
        case "approval": .thread(ID.approval)
        case "input": .thread(ID.input)
        case "plan": .thread(ID.plan)
        case "failed": .thread(ID.failed)
        case "draft": .draft(projectID: ID.app)
        case "empty": .draft(projectID: nil)
        default: .thread(ID.demo)
        }
        return Built(engine: engine, selection: selection)
    }

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
        static let plan = "thread-plan"
        static let failed = "thread-renderer"
        static let pinned = "thread-release"
        static let scratch = "thread-scratch"
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

    static let codex = ModelSelection(provider: .codex, model: "gpt-6.1-sol", options: [ModelOptionID.effort: "high"])
    static let claude = ModelSelection(provider: .claude, model: "claude-opus-5-5", options: [ModelOptionID.effort: "medium"])

    static func threads(_ now: Date) -> [AgentThread] {
        func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
        var result: [AgentThread] = []

        // 1. Completed thread with every common item kind (selected in "demo").
        let loginTurn1 = Turn(
            id: "turn-login-1",
            ordinal: 1,
            userMessage: UserMessage(id: "msg-login-1", text: "Users get stuck in a redirect loop after logging in with SSO. Find out why and fix it, with a regression test.", createdAt: ago(1500)),
            modelSelection: codex,
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
            modelSelection: codex,
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
        result.append(AgentThread(
            id: ID.demo, projectID: ID.app, title: "Fix SSO login redirect loop", createdAt: ago(1500), updatedAt: ago(548),
            modelSelection: codex, branch: "soprano/fix-login-redirect", worktreePath: "/Users/demo/.soprano-agents/worktrees/app/soprano-fix-login-redirect",
            lastVisitedAt: ago(30), providerThreadID: "01a18ca6-e395-70f2-aa8c-32a625c98cc3", turns: [loginTurn1, loginTurn2]
        ))

        // 2. Running thread with a live command (Working).
        result.append(AgentThread(
            id: ID.running, projectID: ID.app, title: "Add dark mode toggle to settings", createdAt: ago(200), updatedAt: ago(5),
            modelSelection: claude, branch: "soprano/dark-mode-toggle", worktreePath: "/Users/demo/.soprano-agents/worktrees/app/soprano-dark-mode-toggle",
            lastVisitedAt: ago(100),
            turns: [Turn(
                id: "turn-dark-1", ordinal: 1,
                userMessage: UserMessage(text: "Add a dark mode toggle to the settings screen that follows the system by default.", createdAt: ago(134)),
                modelSelection: claude, status: .running, startedAt: ago(134),
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
            modelSelection: codex, runtimeMode: .approvalRequired, branch: "main", lastVisitedAt: ago(60),
            turns: [Turn(
                id: "turn-jsonc-1", ordinal: 1,
                userMessage: UserMessage(text: "Switch the settings parser to JSONC so comments survive saves.", createdAt: ago(120)),
                modelSelection: codex, status: .running, startedAt: ago(120),
                items: [
                    TurnItem(id: "ja1", kind: .assistantMessage(text: "I'll add the parser and run the existing settings tests first.", isFinal: false), status: .completed, startedAt: ago(110), completedAt: ago(109)),
                    TurnItem(id: "jp1", kind: .approval(ApprovalRequest(id: "approval-1", kind: .command, detail: "swift test --filter SettingsTests", reason: "Run the settings test suite"))),
                ]
            )]
        ))

        // 4. Waiting on answers (Input).
        result.append(AgentThread(
            id: ID.input, projectID: ID.app, title: "Investigate flaky upload test", createdAt: ago(3000), updatedAt: ago(300),
            modelSelection: claude, lastVisitedAt: ago(400),
            turns: [Turn(
                id: "turn-flaky-1", ordinal: 1,
                userMessage: UserMessage(text: "UploadTests.testResume fails about 1 in 10 runs on CI. Dig in.", createdAt: ago(900)),
                modelSelection: claude, status: .running, startedAt: ago(900),
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

        // 5. Plan mode thread with a todo list and a plan card.
        result.append(AgentThread(
            id: ID.plan, projectID: ID.site, title: "Plan the docs site redesign", createdAt: ago(7200), updatedAt: ago(3500),
            modelSelection: claude, interactionMode: .plan, lastVisitedAt: ago(3000),
            turns: [Turn(
                id: "turn-plan-1", ordinal: 1,
                userMessage: UserMessage(text: "Plan a redesign of the docs site navigation. Don't change anything yet.", createdAt: ago(3700)),
                modelSelection: claude, status: .completed, startedAt: ago(3700), completedAt: ago(3500),
                items: [
                    TurnItem(id: "pt1", kind: .todoList(steps: [
                        TodoStep(id: "s1", text: "Inventory current pages", status: .completed),
                        TodoStep(id: "s2", text: "Group pages into sections", status: .completed),
                        TodoStep(id: "s3", text: "Draft the new sidebar", status: .inProgress),
                        TodoStep(id: "s4", text: "Write migration notes", status: .pending),
                    ], explanation: nil), status: .completed, startedAt: ago(3690), completedAt: ago(3600)),
                    TurnItem(id: "pp1", kind: .plan(markdown: planMarkdown), status: .completed, startedAt: ago(3550), completedAt: ago(3500)),
                ]
            )]
        ))

        // 6. Failed turn (Failed).
        result.append(AgentThread(
            id: ID.failed, projectID: ID.soprano, title: "Refactor diff renderer", createdAt: ago(10000), updatedAt: ago(5000),
            modelSelection: codex, lastVisitedAt: ago(9000),
            turns: [Turn(
                id: "turn-renderer-1", ordinal: 1,
                userMessage: UserMessage(text: "Split DiffRows.swift into one file per row type.", createdAt: ago(5200)),
                modelSelection: codex, status: .failed, failureMessage: "Codex exited unexpectedly (exit code 1).", startedAt: ago(5200), completedAt: ago(5000),
                items: [TurnItem(id: "fe1", kind: .error(message: "Codex exited unexpectedly (exit code 1)."), status: .failed, startedAt: ago(5000), completedAt: ago(5000))]
            )]
        ))

        // 7. Pinned, unread completion (Done).
        result.append(AgentThread(
            id: ID.pinned, projectID: ID.app, title: "Release checklist for 2.4", createdAt: ago(86400 * 2), updatedAt: ago(7200),
            modelSelection: codex, pinnedAt: ago(86400), lastVisitedAt: ago(86400),
            turns: [Turn(
                ordinal: 1, userMessage: UserMessage(text: "Draft the 2.4 release checklist.", createdAt: ago(7400)),
                modelSelection: codex, status: .completed, startedAt: ago(7400), completedAt: ago(7200),
                items: [TurnItem(id: "rc1", kind: .assistantMessage(text: "Here's the checklist:\n\n- [ ] Bump versions\n- [ ] Changelog\n- [ ] Tag", isFinal: true), status: .completed)]
            )]
        ))

        // 8. Scratch thread without a project.
        result.append(AgentThread(
            id: ID.scratch, projectID: nil, title: "Explain Swift actors vs locks", createdAt: ago(86400 * 3), updatedAt: ago(86400 * 3),
            modelSelection: claude, lastVisitedAt: ago(86400),
            turns: [Turn(
                ordinal: 1, userMessage: UserMessage(text: "When should I use an actor instead of a lock?", createdAt: ago(86400 * 3)),
                modelSelection: claude, status: .completed, startedAt: ago(86400 * 3), completedAt: ago(86400 * 3 - 40),
                items: [TurnItem(id: "sa1", kind: .assistantMessage(text: "Use an actor when the state is accessed from async code…", isFinal: true), status: .completed)]
            )]
        ))

        // 9. Settled history.
        let settledTitles = ["Bump swift-markdown to 0.8", "Fix terminal resize flicker", "Add CHANGELOG entry", "Rename AgentManager APIs", "Document keybindings"]
        for (index, title) in settledTitles.enumerated() {
            let created = ago(Double(86400 * (4 + index)))
            result.append(AgentThread(
                id: "thread-settled-\(index)", projectID: index.isMultiple(of: 2) ? ID.soprano : ID.app, title: title, createdAt: created, updatedAt: created,
                modelSelection: index.isMultiple(of: 2) ? codex : claude, settledAt: created.addingTimeInterval(3600), lastVisitedAt: created.addingTimeInterval(3600),
                turns: [Turn(ordinal: 1, userMessage: UserMessage(text: title, createdAt: created), modelSelection: codex, status: .completed, startedAt: created, completedAt: created.addingTimeInterval(300))]
            ))
        }

        // 10. Archived (Settings › Archive).
        let archived: [(String, String?, Double, Double)] = [
            ("Prototype onboarding carousel", ID.app, 86400 * 2, 86400 * 12),
            ("Try SwiftData for thread storage", ID.soprano, 86400 * 6, 86400 * 15),
            ("Sketch a pricing page", nil, 86400 * 9, 86400 * 20),
        ]
        for (index, (title, projectID, archivedAgo, createdAgo)) in archived.enumerated() {
            let created = ago(createdAgo)
            result.append(AgentThread(
                id: "thread-archived-\(index)", projectID: projectID, title: title, createdAt: created, updatedAt: created,
                modelSelection: codex, archivedAt: ago(archivedAgo), lastVisitedAt: created.addingTimeInterval(600),
                turns: [Turn(ordinal: 1, userMessage: UserMessage(text: title, createdAt: created), modelSelection: codex, status: .completed, startedAt: created, completedAt: created.addingTimeInterval(240))]
            ))
        }
        return result
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

    nonisolated static let planMarkdown = """
    # Docs navigation redesign

    ## Goals
    - Readers find a page in two clicks
    - Section names match the product's own vocabulary

    ## Steps
    1. Merge *Guides* and *Tutorials* into **Learn**
    2. Move API pages under **Reference**, generated from the source
    3. Add a persistent search field to the sidebar

    ## Risks
    - Old links break → add redirects for every moved page
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
