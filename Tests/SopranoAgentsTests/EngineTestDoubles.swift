import AppKit
@testable import SopranoAgentsCore

// Scripted provider and recording git doubles shared by the Engine*Tests suites.

/// A provider session whose events the test pushes with `emit`.
final class ScriptedSession: ProviderSession, @unchecked Sendable {
    let kind: ProviderKind
    let events: AsyncStream<ProviderEvent>
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private let lock = NSLock()
    private var _configs: [SessionConfig] = []
    private var _turns: [TurnInput] = []
    private var _steers: [TurnInput] = []
    private var _interrupts = 0
    private var _responses: [(id: String, decision: ApprovalDecision)] = []
    private var _answers: [(id: String, answers: [String: [String]])] = []
    private var _rollbacks: [(ordinal: Int, providerTurnID: String?)] = []
    private var _compactions = 0
    private var _subagentSteers: [(id: String, text: String)] = []
    private var _subagentCancels: [String] = []
    private var _closed = false
    var conversationID = "conv-1"
    var startTurnError: (any Error)?
    /// Awaited by `start` (a slow process start).
    var startGate: (@Sendable () async -> Void)?

    init(kind: ProviderKind) {
        self.kind = kind
        (events, continuation) = AsyncStream.makeStream(of: ProviderEvent.self)
    }

    func emit(_ event: ProviderEvent) { continuation.yield(event) }

    var configs: [SessionConfig] { lock.withLock { _configs } }
    var turns: [TurnInput] { lock.withLock { _turns } }
    var steers: [TurnInput] { lock.withLock { _steers } }
    var interrupts: Int { lock.withLock { _interrupts } }
    var responses: [(id: String, decision: ApprovalDecision)] { lock.withLock { _responses } }
    var answers: [(id: String, answers: [String: [String]])] { lock.withLock { _answers } }
    var rollbacks: [(ordinal: Int, providerTurnID: String?)] { lock.withLock { _rollbacks } }
    var compactions: Int { lock.withLock { _compactions } }
    var closed: Bool { lock.withLock { _closed } }
    var subagentSteers: [(id: String, text: String)] { lock.withLock { _subagentSteers } }
    var subagentCancels: [String] { lock.withLock { _subagentCancels } }

    func start(_ config: SessionConfig) async throws -> String {
        lock.withLock { _configs.append(config) }
        await startGate?()
        return conversationID
    }

    func startTurn(_ input: TurnInput) async throws -> String? {
        if let startTurnError { throw startTurnError }
        return lock.withLock {
            _turns.append(input)
            return "provider-turn-\(_turns.count)"
        }
    }

    func steer(_ input: TurnInput) async throws { lock.withLock { _steers.append(input) } }
    func interrupt() async { lock.withLock { _interrupts += 1 } }

    func respond(toApproval id: String, decision: ApprovalDecision) async {
        lock.withLock { _responses.append((id, decision)) }
    }

    func answer(userInput id: String, answers: [String: [String]]) async {
        lock.withLock { _answers.append((id, answers)) }
    }

    func compact() async throws {
        lock.withLock { _compactions += 1 }
    }

    func rollback(beforeTurn ordinal: Int, providerTurnID: String?) async throws {
        lock.withLock { _rollbacks.append((ordinal, providerTurnID)) }
    }

    func steerSubagent(_ id: String, text: String) async throws {
        lock.withLock { _subagentSteers.append((id, text)) }
    }

    func cancelSubagent(_ id: String) async throws {
        lock.withLock { _subagentCancels.append(id) }
    }

    /// What `askSideQuestion` answers (the topic omp reports started; it may emit events
    /// first); nil = the question as a new running topic "btw-<n>".
    var sideQuestionAnswer: (@Sendable (String, String?) async throws -> SideQuestion)?
    var sideQuestionHistory: [SideQuestion] = []
    private var _sideQuestions: [(question: String, topicID: String?)] = []
    private var _sideQuestionCancels = 0
    private var _historyReads = 0
    var askedSideQuestions: [(question: String, topicID: String?)] { lock.withLock { _sideQuestions } }
    var sideQuestionCancels: Int { lock.withLock { _sideQuestionCancels } }
    var historyReads: Int { lock.withLock { _historyReads } }

    func askSideQuestion(_ question: String, topicID: String?) async throws -> SideQuestion {
        let count = lock.withLock {
            _sideQuestions.append((question, topicID))
            return _sideQuestions.count
        }
        if let sideQuestionAnswer { return try await sideQuestionAnswer(question, topicID) }
        return SideQuestion(id: "btw-\(count)", first: SideQuestionExchange(question: question, status: .running, createdAt: Date(timeIntervalSince1970: TimeInterval(count))))
    }

    func cancelSideQuestion() async -> Bool {
        lock.withLock { _sideQuestionCancels += 1 }
        return true
    }

    func sideQuestions() async throws -> [SideQuestion] {
        lock.withLock { _historyReads += 1 }
        return sideQuestionHistory
    }

    func close() async {
        lock.withLock { _closed = true }
        continuation.finish()
    }
}

/// Hands out `ScriptedSession`s and answers `generateJSON` with a scripted handler.
final class ScriptedDriver: ProviderDriver, @unchecked Sendable {
    let kind: ProviderKind
    private let lock = NSLock()
    private var _sessions: [ScriptedSession] = []
    private var _prompts: [String] = []
    var generate: @Sendable (String) throws -> JSONValue = { _ in throw EngineError.message("no generation scripted") }
    /// `commands(directory:)`'s answer; every call is recorded in `commandDirectories`.
    var listedCommands: [ProviderCommand]?
    private var _commandDirectories: [String] = []
    var commandDirectories: [String] { lock.withLock { _commandDirectories } }
    /// Given to every new session (`ScriptedSession.startGate`).
    var sessionStartGate: (@Sendable () async -> Void)?

    init(kind: ProviderKind = .omp) {
        self.kind = kind
    }

    var sessions: [ScriptedSession] { lock.withLock { _sessions } }
    var prompts: [String] { lock.withLock { _prompts } }
    var session: ScriptedSession? { sessions.last }

    func probe() async -> ProviderStatus {
        ProviderStatus(kind: kind, health: .ready, version: "1.0")
    }

    func makeSession() -> any ProviderSession {
        let session = ScriptedSession(kind: kind)
        session.startGate = sessionStartGate
        lock.withLock { _sessions.append(session) }
        return session
    }

    func generateJSON(prompt: String, schema: JSONValue, model: String, cwd: String) async throws -> JSONValue {
        lock.withLock { _prompts.append(prompt) }
        return try generate(prompt)
    }

    func commands(directory: String) async -> [ProviderCommand]? {
        lock.withLock { _commandDirectories.append(directory) }
        return listedCommands
    }
}

/// In-memory git that records every call as a short string ("capture ref", "changed a..b").
final class RecordingGit: GitService, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    private var refs: Set<String> = []
    var isRepo = true
    var currentBranch = "main"
    var files = [ChangedFileStat(path: "README.md", additions: 3, deletions: 1)]
    var existingBranches: [String] = []
    var worktreeError: (any Error)?
    var restoreError: (any Error)?

    var calls: [String] { lock.withLock { _calls } }

    /// Checkpoint-related calls only, with the ref prefix and thread id stripped ("capture 0").
    func checkpointCalls(threadID: String) -> [String] {
        let prefix = CheckpointRef.prefix + "/" + threadID + "/"
        return calls.filter { $0.contains(prefix) }.map { $0.replacingOccurrences(of: prefix, with: "") }
    }

    func hasRef(_ ref: String) -> Bool { lock.withLock { refs.contains(ref) } }

    private func record(_ call: String) { lock.withLock { _calls.append(call) } }

    func isRepository(_ cwd: String) async -> Bool { isRepo }
    func repositoryRoot(_ cwd: String) async -> String? { isRepo ? cwd : nil }
    func checkedOutBranch(_ cwd: String) async -> String? { isRepo ? currentBranch : nil }

    func captureCheckpoint(cwd: String, ref: String) async throws {
        record("capture \(ref)")
        lock.withLock { _ = refs.insert(ref) }
    }

    func checkpointExists(cwd: String, ref: String) async -> Bool {
        lock.withLock { refs.contains(ref) }
    }

    func changedFiles(cwd: String, fromRef: String, toRef: String) async throws -> [ChangedFileStat] {
        record("changed \(fromRef)..\(toRef)")
        return files
    }

    func diff(cwd: String, fromRef: String, toRef: String, ignoreWhitespace: Bool) async throws -> String {
        record("diff \(fromRef)..\(toRef)")
        return "diff"
    }

    func workingTreeDiff(cwd: String, ignoreWhitespace: Bool) async throws -> String { "" }

    func restoreCheckpoint(cwd: String, ref: String) async throws {
        record("restore \(ref)")
        if let restoreError { throw restoreError }
    }

    func deleteRefs(cwd: String, refs deleted: [String]) async throws {
        for ref in deleted { record("delete \(ref)") }
        lock.withLock { refs.subtract(deleted) }
    }

    func status(cwd: String) async throws -> GitStatusSummary {
        GitStatusSummary(isRepository: isRepo, branch: isRepo ? currentBranch : nil)
    }

    func branches(cwd: String) async throws -> [GitBranchRef] {
        existingBranches.map { GitBranchRef(name: $0) }
    }

    func createBranch(cwd: String, name: String, checkout: Bool) async throws {}
    func switchBranch(cwd: String, name: String) async throws {}

    func renameBranch(cwd: String, from: String, to: String) async throws {
        record("rename \(from) -> \(to)")
    }

    func createWorktree(projectRoot: String, baseBranch: String, newBranch: String, directory: String) async throws -> String {
        record("worktree \(baseBranch) \(newBranch)")
        if let worktreeError { throw worktreeError }
        let path = "\(directory)/repo/\(newBranch.replacingOccurrences(of: "/", with: "-"))"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    func removeWorktree(projectRoot: String, path: String, force: Bool) async throws {}

    func runAction(_ request: GitActionRequest, writer: any SourceControlWriter, progress: @escaping @Sendable (GitActionProgress) -> Void) async throws -> GitActionResult {
        let message = try await writer.commitMessage(branch: "main", stagedSummary: "M README.md", stagedPatch: "+hi", includeBranch: false)
        return GitActionResult(title: "Committed", detail: message.subject)
    }
}

@MainActor
enum EngineHarness {
    static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("soprano-agents-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func engine(
        driver: ScriptedDriver = ScriptedDriver(),
        git: RecordingGit = RecordingGit(),
        store: any ThreadStore = InMemoryThreadStore(),
        settings: EngineSettings = EngineSettings(generateTitles: false)
    ) -> AgentEngine {
        let environment = EngineEnvironment(
            drivers: [driver.kind: driver],
            git: git,
            store: store,
            dataDirectory: temporaryDirectory()
        )
        let engine = AgentEngine(environment: environment, settings: settings)
        engine.runtime.titleRetryDelay = .zero
        // Scripted sessions never report a released yield: end it at once.
        engine.runtime.yieldReleaseTimeout = .zero
        return engine
    }

    /// A project thread with no turns yet, working in a fresh temporary project folder.
    static func idleThread(in engine: AgentEngine) -> String {
        let project = engine.addProject(path: temporaryDirectory().path)
        let thread = AgentThread(projectID: project.id, title: "Thread", modelSelection: .default(for: .omp))
        engine.insertThread(thread)
        return thread.id
    }

    /// Polls `condition` on the main actor until it holds or `timeout` passes. `swift test` runs
    /// Soprano's and Soprano Agents' suites in one process, where a main-actor hop can stall for
    /// seconds; a passing condition returns at once, so only a real failure waits this long.
    static func eventually(timeout: Duration = .seconds(15), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }
}
