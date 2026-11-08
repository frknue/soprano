import Foundation

/// How a chat tab starts its agent: the agent's ACP server, run through the
/// user's login shell like an agent pane so it finds the same CLI and sees the
/// same environment.
struct AgentChatLaunch: Equatable, Sendable {
    let profileId: String
    let agentName: String
    let shell: String
    let arguments: [String]
    let environment: [String: String]
    let workingDirectory: String
    let toolStyle: ACPToolStyle

    /// Agents a chat tab can run, by profile id: those whose CLI serves the
    /// Agent Client Protocol on stdio.
    static func supports(profileId: String) -> Bool {
        profileId == "omp"
    }

    /// The catalog's agents that open as a chat, in catalog order.
    static var chatProfiles: [AgentProfile] {
        AgentCatalog.all.filter { supports(profileId: $0.id) }
    }

    static func forProfile(
        _ profile: AgentProfile,
        cwd: String?,
        loginShell: String = DefaultAgents.terminal.command,
        accounts: AccountLaunchState = .shared,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AgentChatLaunch? {
        guard supports(profileId: profile.id) else { return nil }
        let directory = SopranoConfig.expandPath(cwd ?? profile.cwd ?? "")
        let workingDirectory = directory.hasPrefix("/") ? directory : FileManager.default.homeDirectoryForCurrentUser.path

        // A Soprano started from one of its own panes must not pass that
        // pane's identity on: hooks would report this chat as that pane.
        var processEnvironment = environment.filter { !$0.key.hasPrefix("SOPRANO_") }
        processEnvironment.merge(profile.env ?? [:]) { _, profile in profile }
        // omp's ambient extension stays quiet for an agent Soprano launched.
        processEnvironment["SOPRANO_AGENT_PROFILE"] = profile.id
        processEnvironment["SOPRANO_AGENT_NAME"] = profile.name

        let adjustments = accounts.adjustments(forProfile: profile.id)
        let arguments = ["acp"] + profile.args + adjustments.arguments
        let command = ([profile.command] + arguments).map(TerminalConfig.shellQuoted).joined(separator: " ")
        // Account variables go after the rc files, as in an agent pane.
        let exports = adjustments.environment.keys.sorted().map { key in
            "export \(key)=\(TerminalConfig.shellQuoted(adjustments.environment[key] ?? ""))"
        }
        let script = (exports + ["exec \(command)"]).joined(separator: "; ")
        return AgentChatLaunch(
            profileId: profile.id,
            agentName: profile.name,
            shell: loginShell,
            arguments: ["-lic", script],
            environment: processEnvironment,
            workingDirectory: workingDirectory,
            toolStyle: profile.id == "omp" ? .omp : .generic
        )
    }

    @MainActor
    func makeConnection() -> JSONRPCConnection {
        JSONRPCConnection(
            executableURL: URL(fileURLWithPath: shell),
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment
        )
    }
}

/// A tool call the agent wants to run once the person allows it.
struct AgentChatPermission: Equatable, Sendable {
    typealias Option = ApprovalOption

    let title: String
    /// The full command or input when it says more than the title.
    let detail: String?
    /// What the tool does, for the approval's heading.
    var kind: ApprovalKind = .other
    let options: [Option]

    /// What is being approved: the command, else the title.
    var subject: String {
        detail ?? (title.hasPrefix("$ ") ? String(title.dropFirst(2)) : title)
    }

    /// Why the agent asks: its title, when the command says what runs.
    var reason: String? {
        detail == nil ? nil : title
    }
}

/// Questions the agent asks, as an ACP form elicitation: one or more fields,
/// each a choice among labels and, where offered, an answer of one's own.
struct AgentChatQuestion: Equatable, Sendable {
    struct Field: Equatable, Sendable {
        struct Choice: Equatable, Sendable {
            let label: String
            let detail: String?
        }

        let key: String
        let title: String
        let detail: String?
        let choices: [Choice]
        let allowsMultiple: Bool
        /// The key a typed answer goes under, when the field takes one.
        let otherKey: String?
        let recommended: String?
    }

    let message: String
    let fields: [Field]

    /// Parses `requestedSchema` from `elicitation/create`. Nil for a form
    /// with nothing a person could answer.
    init?(message: String, schema: JSONValue) {
        guard let properties = schema["properties"]?.object else { return nil }
        var fields: [Field] = []
        for key in properties.keys.sorted(by: Self.fieldOrder) where !key.hasSuffix("__other") {
            guard let property = properties[key] else { continue }
            let isArray = property["type"]?.string == "array"
            let options = isArray ? property["items"]?["anyOf"]?.array : property["oneOf"]?.array
            let choices = (options ?? []).compactMap { option -> Field.Choice? in
                guard let label = option["const"]?.string ?? option["title"]?.string else { return nil }
                return Field.Choice(label: label, detail: option["description"]?.nonEmptyString)
            }
            let otherKey = properties["\(key)__other"] == nil ? nil : "\(key)__other"
            guard !choices.isEmpty || otherKey != nil || property["type"]?.string == "string" else { continue }
            fields.append(Field(
                key: key,
                title: property["title"]?.nonEmptyString ?? message,
                detail: property["description"]?.nonEmptyString,
                choices: choices,
                allowsMultiple: isArray,
                otherKey: otherKey ?? (choices.isEmpty ? key : nil),
                recommended: property["default"]?.string
            ))
        }
        guard !fields.isEmpty else { return nil }
        self.message = message
        self.fields = fields
    }

    /// `q0`, `q1`, …, `q10` in numeric order rather than by string.
    private static func fieldOrder(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: .numeric) == .orderedAscending
    }

    /// The questions as the composer asks them: the field's description as
    /// the header chip, its title as the question.
    func userInputRequest(id: String) -> UserInputRequest {
        UserInputRequest(id: id, questions: fields.map { field in
            UserInputQuestion(
                id: field.key,
                header: field.detail ?? "",
                question: field.title,
                options: field.choices.map { UserInputOption(label: $0.label, description: $0.detail) },
                allowsMultiple: field.allowsMultiple,
                allowsOther: field.otherKey != nil
            )
        })
    }

    /// The form's content for answers by question id (`userInputRequest`):
    /// chosen labels, or a typed answer under the field's `otherKey`.
    func content(for answers: [String: [String]]) -> [String: JSONValue] {
        var content: [String: JSONValue] = [:]
        for field in fields {
            let values = answers[field.key] ?? []
            let labels = Set(field.choices.map(\.label))
            if let otherKey = field.otherKey, values.count == 1, !labels.contains(values[0]) {
                if otherKey != field.key, field.allowsMultiple { content[field.key] = .array([]) }
                content[otherKey] = .string(values[0])
            } else if field.allowsMultiple {
                content[field.key] = .array(values.map { .string($0) })
            } else if let value = values.first {
                content[field.key] = .string(value)
            }
        }
        return content
    }

    /// What the content answers, by question id, as the timeline shows it.
    func answers(from content: [String: JSONValue]) -> [String: [String]] {
        var answers: [String: [String]] = [:]
        for field in fields {
            if let otherKey = field.otherKey, let typed = content[otherKey]?.nonEmptyString {
                answers[field.key] = [typed]
            } else if let value = content[field.key]?.string {
                answers[field.key] = [value]
            } else if let values = content[field.key]?.array {
                answers[field.key] = values.compactMap(\.string)
            }
        }
        return answers
    }
}

/// One of the session settings the agent offers, such as the model.
struct AgentChatConfigOption: Equatable, Sendable {
    struct Value: Equatable, Sendable {
        let value: String
        let name: String
        /// What the value means ("Auto-detect per prompt"; a model's `provider/id`).
        var detail: String? = nil
    }

    let id: String
    let name: String
    let category: String?
    let currentValue: String
    let values: [Value]

    var currentName: String {
        values.first { $0.value == currentValue }?.name ?? currentValue
    }

    static func parse(_ list: JSONValue?) -> [AgentChatConfigOption] {
        (list?.array ?? []).compactMap { option in
            guard option["type"]?.string == "select",
                  let id = option["id"]?.string,
                  let current = option["currentValue"]?.string
            else { return nil }
            let values = (option["options"]?.array ?? []).compactMap { value -> Value? in
                guard let raw = value["value"]?.string else { return nil }
                return Value(value: raw, name: value["name"]?.nonEmptyString ?? raw, detail: value["description"]?.nonEmptyString)
            }
            return AgentChatConfigOption(
                id: id,
                name: option["name"]?.string ?? id,
                category: option["category"]?.string,
                currentValue: current,
                values: values
            )
        }
    }
}

/// One step of the plan the agent keeps for the current task.
struct AgentChatPlanEntry: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case pending
        case inProgress
        case completed
    }

    let content: String
    let status: Status
}

/// A `/` command the agent offers (`available_commands_update`).
struct AgentChatCommand: Equatable, Sendable {
    let name: String
    let description: String?
    /// What the command takes after its name.
    let hint: String?

    /// What choosing it types: the command and a space for its input.
    var insertText: String { "/\(name) " }

    static func parse(_ list: JSONValue?) -> [AgentChatCommand] {
        (list?.array ?? []).compactMap { command in
            guard let name = command["name"]?.nonEmptyString else { return nil }
            return AgentChatCommand(
                name: name.hasPrefix("/") ? String(name.dropFirst()) : name,
                description: command["description"]?.nonEmptyString,
                hint: command["input"]?["hint"]?.nonEmptyString
            )
        }
    }
}

/// What the session tells the tab that hosts it.
enum AgentChatEvent: Equatable {
    /// The status the sidebar, headers and dashboard show. `notify` asks for
    /// attention unless the person is looking at the chat.
    case status(AgentStatus, waitingReason: AgentWaitingReason?, notify: Bool, message: String?)
    /// The agent's id for this conversation, for resuming it after a restart.
    case conversation(id: String, cwd: String)
    case title(String)
}

/// One conversation with an agent over the Agent Client Protocol: starts its
/// server, opens or reloads the session, sends prompts, and keeps what the
/// chat tab shows — the turns, what the agent is waiting on, the plan, the
/// commands and the settings it offers. Lives on the main actor; the view
/// re-reads it on every `onChange`.
@MainActor
final class AgentChatSession {
    enum Phase: Equatable {
        case starting
        case ready
        case working
        /// The agent's process ended; the text explains an unexpected end.
        case stopped(String?)
    }

    enum Interaction: Equatable {
        case permission(AgentChatPermission)
        case question(AgentChatQuestion)
    }

    let launch: AgentChatLaunch
    /// Stopped until `start`, which a tab stopped before a relaunch skips.
    private(set) var phase: Phase = .stopped(nil)
    private(set) var builder: ACPTurnBuilder
    private(set) var interaction: Interaction?
    private(set) var configOptions: [AgentChatConfigOption] = []
    private(set) var plan: [AgentChatPlanEntry] = []
    /// Messages waiting for the running turn, oldest first.
    private(set) var queue: [UserMessage] = []
    /// The `/` commands the agent offers.
    private(set) var commands: [AgentChatCommand] = []
    /// Context tokens in use and the window's size, after the last turn.
    private(set) var contextUsage: (used: Int, size: Int)?
    private(set) var sessionId: String?
    private(set) var supportsSteering = false
    private(set) var turnStartedAt: Date?

    var onChange: (() -> Void)?
    var onEvent: ((AgentChatEvent) -> Void)?

    private let makePeer: (AgentChatLaunch) -> any JSONRPCPeer
    private var peer: (any JSONRPCPeer)?
    private var interactionReply: (@MainActor (Result<JSONValue, JSONRPCError>) -> Void)?
    private var generation = 0
    /// Processes this session ended that have not exited yet.
    private var retiringPeers: [ObjectIdentifier: any JSONRPCPeer] = [:]
    /// The turn item of the approval or question on screen.
    private var interactionItemId: String?
    private var nextLocalId = 1

    init(
        launch: AgentChatLaunch,
        makePeer: @escaping (AgentChatLaunch) -> any JSONRPCPeer = { $0.makeConnection() }
    ) {
        self.launch = launch
        self.makePeer = makePeer
        builder = ACPTurnBuilder(cwd: launch.workingDirectory, toolStyle: launch.toolStyle)
    }

    /// The conversation as the chat shows it, queued messages included.
    var thread: ChatThread {
        var thread = builder.thread
        thread.queue = queue
        return thread
    }

    var queuedPrompts: [String] {
        queue.map(\.text)
    }

    /// The agent offers `/compact` and nothing runs: the context can be compacted.
    var canCompact: Bool {
        phase == .ready && interaction == nil && commands.contains { $0.name == "compact" }
    }

    var isRunning: Bool {
        if case .stopped = phase { return false }
        return true
    }

    // MARK: - Lifecycle

    /// Starts the agent and opens `conversationId` when given, else a new
    /// conversation. Waits first for every process this session ended to
    /// exit: one may still hold the conversation, and a load it blocks would
    /// open a new one instead.
    func start(resuming conversationId: String?) {
        generation += 1
        let generation = generation
        phase = .starting
        report(.status(.starting, waitingReason: nil, notify: false, message: nil))
        changed()
        let retiring = Array(retiringPeers.values)
        Task { [weak self] in
            for peer in retiring {
                await peer.waitForExit()
            }
            // A stop or another start while waiting wins.
            guard let self, self.generation == generation else { return }
            self.launchPeer(resuming: conversationId, generation: generation)
        }
    }

    private func launchPeer(resuming conversationId: String?, generation: Int) {
        let peer = makePeer(launch)
        self.peer = peer
        peer.onNotification = { [weak self] method, params in
            guard let self, self.generation == generation else { return }
            self.handleNotification(method, params)
        }
        peer.onRequest = { [weak self] method, params, reply in
            guard let self, self.generation == generation else {
                reply(.failure(JSONRPCError(code: JSONRPCError.internalError, message: "Session closed")))
                return
            }
            self.handleRequest(method, params, reply: reply)
        }
        peer.onExit = { [weak self] status, stderr in
            guard let self, self.generation == generation else { return }
            self.didExit(status: status, stderr: stderr)
        }
        do {
            try peer.start()
        } catch {
            didExit(status: -1, stderr: error.localizedDescription)
            return
        }
        Task { [weak self] in
            await self?.openSession(peer: peer, resuming: conversationId, generation: generation)
        }
    }

    /// Ends the agent's process. The conversation stays on disk.
    func stop() {
        shutdown()
        report(.status(.stopped, waitingReason: nil, notify: false, message: nil))
        changed()
    }

    /// Starts the agent again on the same conversation, or on `fallback`
    /// when this session never opened one. Reports no stop in between: the
    /// tab is already starting.
    func restart(resuming fallback: String? = nil) {
        let conversationId = sessionId ?? fallback
        shutdown()
        builder = ACPTurnBuilder(cwd: launch.workingDirectory, toolStyle: launch.toolStyle)
        plan = []
        commands = []
        contextUsage = nil
        start(resuming: conversationId)
    }

    /// Ends the process and whatever it was doing; later messages from it
    /// are ignored. An unanswered request dies with the process, which the
    /// next `start` waits for.
    private func shutdown() {
        generation += 1
        if let peer {
            self.peer = nil
            peer.terminate()
            retire(peer)
        }
        interaction = nil
        interactionReply = nil
        interactionItemId = nil
        if turnStartedAt != nil {
            builder.finishTurn(stopReason: "cancelled", at: Date())
            turnStartedAt = nil
        }
        phase = .stopped(nil)
    }

    /// Keeps `peer` until its process is gone, across any number of stops
    /// and restarts.
    private func retire(_ peer: any JSONRPCPeer) {
        let id = ObjectIdentifier(peer)
        retiringPeers[id] = peer
        Task { [weak self] in
            await peer.waitForExit()
            self?.retiringPeers[id] = nil
        }
    }

    private func openSession(peer: any JSONRPCPeer, resuming conversationId: String?, generation: Int) async {
        do {
            let initialized = try await peer.request("initialize", params: [
                "protocolVersion": 1,
                "clientCapabilities": [
                    "fs": ["readTextFile": false, "writeTextFile": false],
                    "terminal": false,
                    // Lets the agent ask questions (omp's `ask` tool) and
                    // have a plan approved instead of auto-approving it.
                    "elicitation": ["form": [:]],
                ],
                "clientInfo": ["name": "soprano", "title": "Soprano", "version": .string(AppVersion.current)],
            ])
            guard generation == self.generation else { return }
            supportsSteering = initialized["_meta"]?["steering"]?["supported"]?.bool == true
            let canLoad = initialized["agentCapabilities"]?["loadSession"]?.bool == true

            var opened: JSONValue?
            if let conversationId, canLoad {
                builder.isReplaying = true
                do {
                    opened = try await peer.request("session/load", params: [
                        "sessionId": .string(conversationId),
                        "cwd": .string(launch.workingDirectory),
                        "mcpServers": [],
                    ])
                    sessionId = conversationId
                } catch let error as JSONRPCError where error != .closed {
                    builder.addNotice("Could not reopen the conversation: \(error.message)", isError: true)
                }
                builder.isReplaying = false
            }
            guard generation == self.generation else { return }
            if opened == nil {
                let created = try await peer.request("session/new", params: [
                    "cwd": .string(launch.workingDirectory),
                    "mcpServers": [],
                ])
                guard generation == self.generation else { return }
                guard let id = created["sessionId"]?.string else {
                    throw JSONRPCError(code: JSONRPCError.internalError, message: "The agent returned no session.")
                }
                sessionId = id
                opened = created
            }
            configOptions = AgentChatConfigOption.parse(opened?["configOptions"])
            if let sessionId {
                report(.conversation(id: sessionId, cwd: launch.workingDirectory))
            }
            phase = .ready
            report(.status(.idle, waitingReason: nil, notify: false, message: nil))
            changed()
            sendNextQueuedPrompt()
        } catch let error as JSONRPCError {
            guard generation == self.generation, error != .closed else { return }
            builder.isReplaying = false
            builder.addNotice("The agent could not start a conversation: \(error.message)", isError: true)
            peer.terminate()
        } catch {
            guard generation == self.generation else { return }
            builder.addNotice("The agent could not start a conversation: \(error.localizedDescription)", isError: true)
            peer.terminate()
        }
    }

    private func didExit(status: Int32, stderr: String) {
        shutdown()
        let reason: String
        if status == 0 {
            reason = "The agent exited."
        } else {
            let lastLines = stderr.split(separator: "\n").suffix(6).joined(separator: "\n")
            reason = lastLines.isEmpty
                ? "The agent exited with status \(status)."
                : "The agent exited with status \(status):\n\(lastLines)"
        }
        builder.addNotice(reason, isError: status != 0, at: Date())
        phase = .stopped(status == 0 ? nil : reason)
        report(.status(status == 0 ? .stopped : .error, waitingReason: nil, notify: status != 0, message: reason))
        changed()
    }

    // MARK: - Prompts

    /// Sends `text`, or queues it while a turn runs; it goes out when the
    /// turn ends. False when the agent is not running.
    @discardableResult
    func send(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, isRunning else { return false }
        guard phase == .ready, interaction == nil else {
            queue.append(UserMessage(id: localId("queued"), text: text, createdAt: Date()))
            changed()
            return true
        }
        prompt(text)
        return true
    }

    /// Sends `text` into the running turn, which the agent reads before its
    /// next step. Falls back to `send` when nothing runs or the agent cannot
    /// be steered.
    @discardableResult
    func steer(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, isRunning else { return false }
        guard phase == .working, supportsSteering, let peer, let sessionId else {
            return send(text)
        }
        builder.addSteer(text, at: Date())
        changed()
        Task { [weak self] in
            do {
                _ = try await peer.request("_session/steering", params: [
                    "sessionId": .string(sessionId),
                    "prompt": [["type": "text", "text": .string(text)]],
                ])
            } catch let error as JSONRPCError {
                guard error != .closed else { return }
                self?.builder.addNotice("Could not steer the agent: \(error.message)", isError: true)
                self?.changed()
            } catch {}
        }
        return true
    }

    /// Drops a queued prompt before it is sent.
    func removeQueuedPrompt(at index: Int) {
        guard queue.indices.contains(index) else { return }
        queue.remove(at: index)
        changed()
    }

    func removeQueuedPrompt(id: String) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        removeQueuedPrompt(at: index)
    }

    /// Steers a queued prompt into the running turn instead of waiting.
    func sendQueuedPromptNow(id: String) {
        guard phase == .working, supportsSteering, let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let message = queue.remove(at: index)
        steer(message.text)
    }

    /// Stops the running turn. Queued prompts stay queued and go out after
    /// the next turn the person starts, not right after the stop.
    func cancel() {
        guard let peer, let sessionId, phase == .working else { return }
        failInteraction()
        builder.markStopRequested(at: Date())
        changed()
        peer.notify("session/cancel", params: ["sessionId": .string(sessionId)])
    }

    /// Asks the agent to summarize the conversation so far (its `/compact`).
    func compact() {
        guard canCompact else { return }
        prompt("/compact")
    }

    private func prompt(_ text: String) {
        guard let peer, let sessionId else { return }
        let started = Date()
        builder.addPrompt(text, at: started)
        phase = .working
        turnStartedAt = started
        report(.status(.running, waitingReason: nil, notify: false, message: nil))
        changed()
        let generation = generation
        Task { [weak self] in
            let outcome: Result<JSONValue, JSONRPCError>
            do {
                outcome = .success(try await peer.request("session/prompt", params: [
                    "sessionId": .string(sessionId),
                    "prompt": [["type": "text", "text": .string(text)]],
                ]))
            } catch let error as JSONRPCError {
                outcome = .failure(error)
            } catch {
                outcome = .failure(JSONRPCError(code: JSONRPCError.internalError, message: error.localizedDescription))
            }
            guard let self, self.generation == generation else { return }
            self.finishTurn(outcome)
        }
    }

    private func finishTurn(_ outcome: Result<JSONValue, JSONRPCError>) {
        // An exit already ended the turn and said why.
        guard outcome != .failure(.closed) else { return }
        failInteraction()
        turnStartedAt = nil
        phase = .ready
        // A stop holds the queue: sending it now would undo the stop.
        var sendsQueue = true
        switch outcome {
        case .success(let result):
            let stopReason = result["stopReason"]?.string
            builder.finishTurn(stopReason: stopReason, at: Date())
            if stopReason == "cancelled" {
                sendsQueue = false
                report(.status(.idle, waitingReason: nil, notify: false, message: nil))
            } else {
                report(.status(.waiting, waitingReason: .turnEnded, notify: true, message: lastReply()))
            }
        case .failure(let error):
            builder.finishTurn(stopReason: nil, failure: error.message, at: Date())
            report(.status(.error, waitingReason: nil, notify: true, message: error.message))
        }
        changed()
        if sendsQueue {
            sendNextQueuedPrompt()
        }
    }

    private func sendNextQueuedPrompt() {
        guard phase == .ready, interaction == nil, !queue.isEmpty else { return }
        prompt(queue.removeFirst().text)
    }

    /// The last turn's answer, for the notification.
    private func lastReply() -> String? {
        for item in builder.thread.turns.last?.items.reversed() ?? [] {
            if case let .assistantMessage(text, _) = item.kind { return String(text.prefix(4_096)) }
        }
        return nil
    }

    private func localId(_ prefix: String) -> String {
        defer { nextLocalId += 1 }
        return "\(prefix)-\(nextLocalId)"
    }

    // MARK: - Settings

    /// Changes one of the agent's session settings, such as the model.
    func setConfigOption(_ id: String, to value: String) {
        guard let peer, let sessionId,
              let index = configOptions.firstIndex(where: { $0.id == id }),
              configOptions[index].currentValue != value
        else { return }
        Task { [weak self] in
            do {
                let result = try await peer.request("session/set_config_option", params: [
                    "sessionId": .string(sessionId),
                    "configId": .string(id),
                    "value": .string(value),
                ])
                guard let self else { return }
                let options = AgentChatConfigOption.parse(result["configOptions"])
                if !options.isEmpty {
                    self.configOptions = options
                }
                self.changed()
            } catch let error as JSONRPCError {
                guard error != .closed else { return }
                self?.builder.addNotice("Could not change \(id): \(error.message)", isError: true)
                self?.changed()
            } catch {}
        }
    }

    // MARK: - Interactions

    /// Answers a permission request with one of its options.
    func choosePermissionOption(_ optionId: String) {
        guard case .permission(let permission) = interaction,
              let option = permission.options.first(where: { $0.id == optionId })
        else { return }
        if let id = interactionItemId {
            builder.resolveApproval(id, decision: .of(optionKind: option.kind), at: Date())
        }
        resolveInteraction(.success(["outcome": ["outcome": "selected", "optionId": .string(optionId)]]))
    }

    /// Answers a question form: per field key, the chosen labels or the
    /// typed answer under its `otherKey`.
    func answerQuestion(_ content: [String: JSONValue]) {
        guard case .question(let question) = interaction else { return }
        if let id = interactionItemId {
            builder.resolveUserInput(id, answers: question.answers(from: content), at: Date())
        }
        resolveInteraction(.success(["action": "accept", "content": .object(content)]))
    }

    func declineQuestion() {
        guard case .question = interaction else { return }
        if let id = interactionItemId {
            builder.resolveUserInput(id, answers: nil, at: Date())
        }
        resolveInteraction(.success(["action": "decline"]))
    }

    private func resolveInteraction(_ result: Result<JSONValue, JSONRPCError>) {
        let reply = interactionReply
        interactionReply = nil
        interaction = nil
        interactionItemId = nil
        reply?(result)
        if phase == .working {
            report(.status(.running, waitingReason: nil, notify: false, message: nil))
        }
        changed()
    }

    /// Withdraws a pending request when its turn ends or the agent leaves.
    private func failInteraction() {
        guard let interaction else { return }
        withdrawInteractionItem()
        switch interaction {
        case .permission:
            resolveInteraction(.success(["outcome": ["outcome": "cancelled"]]))
        case .question:
            resolveInteraction(.success(["action": "cancel"]))
        }
    }

    /// The request on screen went unanswered: its turn item says so.
    private func withdrawInteractionItem() {
        guard let id = interactionItemId, let interaction else { return }
        switch interaction {
        case .permission: builder.resolveApproval(id, decision: .cancel, at: Date())
        case .question: builder.resolveUserInput(id, answers: nil, at: Date())
        }
    }

    // MARK: - Messages from the agent

    private func handleNotification(_ method: String, _ params: JSONValue) {
        switch method {
        case "session/update":
            guard params["sessionId"]?.string == sessionId || sessionId == nil,
                  let update = params["update"]
            else { return }
            apply(update)
        case "_omp/compaction/start":
            builder.addNotice("Compacting context…", isError: false, at: Date())
            changed()
        case "_omp/compaction/end":
            if let message = params["errorMessage"]?.nonEmptyString {
                builder.addNotice("Context compaction failed: \(message)", isError: true, at: Date())
            } else if params["aborted"]?.bool != true, params["skipped"]?.bool != true {
                builder.addNotice("Context compacted", isError: false, at: Date())
            }
            changed()
        case "$/cancel_request":
            // The agent withdrew the question it asked, e.g. after steering.
            withdrawInteractionItem()
            interactionReply = nil
            interaction = nil
            interactionItemId = nil
            changed()
        default:
            break
        }
    }

    private func apply(_ update: JSONValue) {
        switch update["sessionUpdate"]?.string {
        case "plan":
            plan = (update["entries"]?.array ?? []).compactMap { entry in
                guard let content = entry["content"]?.nonEmptyString else { return nil }
                let status: AgentChatPlanEntry.Status = switch entry["status"]?.string {
                case "completed": .completed
                case "in_progress": .inProgress
                default: .pending
                }
                return AgentChatPlanEntry(content: content, status: status)
            }
            changed()
        case "config_option_update":
            let options = AgentChatConfigOption.parse(update["configOptions"])
            if !options.isEmpty {
                configOptions = options
                changed()
            }
        case "current_mode_update":
            if let mode = update["currentModeId"]?.string,
               let index = configOptions.firstIndex(where: { $0.category == "mode" })
            {
                let option = configOptions[index]
                configOptions[index] = AgentChatConfigOption(
                    id: option.id, name: option.name, category: option.category,
                    currentValue: mode, values: option.values
                )
                changed()
            }
        case "session_info_update":
            if let title = update["title"]?.nonEmptyString {
                report(.title(title))
            }
        case "usage_update":
            if let used = update["used"]?.int, let size = update["size"]?.int, size > 0 {
                contextUsage = (used, size)
                changed()
            }
        case "available_commands_update":
            commands = AgentChatCommand.parse(update["availableCommands"])
            changed()
        default:
            if builder.apply(update, at: Date()) {
                changed()
            }
        }
    }

    private func handleRequest(
        _ method: String,
        _ params: JSONValue,
        reply: @escaping @MainActor (Result<JSONValue, JSONRPCError>) -> Void
    ) {
        switch method {
        case "session/request_permission":
            let toolCall = params["toolCall"] ?? .null
            let options = (params["options"]?.array ?? []).compactMap { option -> AgentChatPermission.Option? in
                guard let id = option["optionId"]?.string else { return nil }
                return AgentChatPermission.Option(
                    id: id,
                    name: option["name"]?.string ?? id,
                    kind: option["kind"]?.string ?? ""
                )
            }
            guard !options.isEmpty else {
                reply(.success(["outcome": ["outcome": "cancelled"]]))
                return
            }
            let title = toolCall["title"]?.nonEmptyString ?? "Run a tool"
            let command = toolCall["rawInput"]?["command"]?.nonEmptyString
            let permission = AgentChatPermission(
                title: title,
                detail: command.flatMap { $0 == title || "$ \($0)" == title ? nil : $0 },
                kind: ApprovalKind.of(acpKind: toolCall["kind"]?.string),
                options: options
            )
            present(.permission(permission), reply: reply, reason: .approval, message: title)
            let id = localId("approval")
            interactionItemId = id
            builder.addApproval(ApprovalRequest(
                id: id,
                kind: permission.kind,
                detail: permission.subject,
                reason: permission.reason,
                options: permission.options
            ), at: Date())
            changed()
        case "elicitation/create":
            guard params["mode"]?.string ?? "form" == "form",
                  let question = AgentChatQuestion(
                      message: params["message"]?.string ?? "",
                      schema: params["requestedSchema"] ?? .null
                  )
            else {
                reply(.success(["action": "decline"]))
                return
            }
            present(.question(question), reply: reply, reason: .question, message: question.fields.first?.title)
            let id = localId("question")
            interactionItemId = id
            builder.addUserInput(question.userInputRequest(id: id), at: Date())
            changed()
        default:
            reply(.failure(JSONRPCError(code: JSONRPCError.methodNotFound, message: "Method not found: \(method)")))
        }
    }

    private func present(
        _ interaction: Interaction,
        reply: @escaping @MainActor (Result<JSONValue, JSONRPCError>) -> Void,
        reason: AgentWaitingReason,
        message: String?
    ) {
        // A newer request replaces one the agent left unanswered.
        failInteraction()
        self.interaction = interaction
        interactionReply = reply
        report(.status(.waiting, waitingReason: reason, notify: true, message: message))
        changed()
    }

    // MARK: - Output

    private func report(_ event: AgentChatEvent) {
        onEvent?(event)
    }

    private func changed() {
        onChange?()
    }
}
