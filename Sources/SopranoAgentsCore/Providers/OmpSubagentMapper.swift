import Foundation

/// Folds omp's forwarded subagent frames (`set_subagent_subscription {level:"events"}`) into
/// `ProviderEvent.subagent` events. Pure: no I/O.
///
/// - `subagent_lifecycle {payload:{id, agent, description?, status, sessionFile?,
///   parentToolCallId?, detached?}}` → `.updated` (`started` → running; `completed`, `failed`,
///   `aborted`), plus `.runEnded` when the run was still open.
/// - `subagent_progress {payload:{assignment?, progress:{id, lastIntent?, resolvedModelIdentity?}}}`
///   → `.updated` when those facts changed (progress repeats several times a second).
/// - `subagent_event {payload:{id, event}}`: the subagent's own session events. `agent_start`
///   opens a run, reported with the first message that reaches it (`message_start` of a `user`
///   message, or a `custom` one: `irc:incoming` from another agent, background-job notices);
///   later messages in the run are `.message` (user, IRC) or a notice item (other custom).
///   Assistant text, thinking and tools go through a per-subagent `OmpEventMapper`; subagent
///   events carry no `messageId`, so each assistant `message_start` gets one (`m<N>`).
///   `agent_end` ends the run: the last assistant message's `stopReason` `aborted` →
///   interrupted, `error` → failed.
struct OmpSubagentMapper: Sendable {
    var cwd: String?

    private struct Agent {
        var mapper: OmpEventMapper
        var info = SubagentInfo()
        var messageCount = 0
        var messageID: String?
        var noticeCount = 0
        /// Tool calls that ended: a late `tool_execution_update` (a command that ran in a
        /// temporary shell) would mark them running again.
        var endedTools: Set<String> = []
        /// `agent_start` arrived; the run is reported with its first message.
        var isRunPending = false
        var isRunOpen = false
        var status: SubagentStatus = .running
    }

    private var agents: [String: Agent] = [:]

    init(cwd: String? = nil) {
        self.cwd = cwd
    }

    /// Subagents that are running as far as omp reported.
    var runningIDs: [String] {
        agents.filter { $0.value.status == .running }.map(\.key).sorted()
    }

    mutating func map(_ frame: JSONValue) -> [ProviderEvent] {
        let payload = frame["payload"]
        switch frame["type"]?.stringValue {
        case "subagent_lifecycle":
            guard let id = payload?["id"]?.nonEmptyString, let payload else { return [] }
            return lifecycle(id, payload)
        case "subagent_progress":
            guard let id = payload?["progress"]?["id"]?.nonEmptyString, let payload else { return [] }
            return progress(id, payload)
        case "subagent_event":
            guard let id = payload?["id"]?.nonEmptyString, let event = payload?["event"] else { return [] }
            return self.event(id, event)
        default:
            return []
        }
    }

    /// The process went away: every running subagent stopped with it.
    mutating func abortAll() -> [ProviderEvent] {
        var events: [ProviderEvent] = []
        for id in runningIDs {
            guard var agent = agents[id] else { continue }
            if agent.isRunOpen || agent.isRunPending {
                events.append(.subagent(id: id, .runEnded(outcome: .interrupted, error: nil)))
            }
            agent.isRunOpen = false
            agent.isRunPending = false
            agent.status = .aborted
            agent.info.status = .aborted
            agents[id] = agent
            events.append(.subagent(id: id, .updated(SubagentInfo(status: .aborted))))
        }
        return events
    }

    // MARK: - Frames

    private mutating func lifecycle(_ id: String, _ payload: JSONValue) -> [ProviderEvent] {
        var agent = agents[id] ?? Agent(mapper: OmpEventMapper(cwd: cwd))
        let status: SubagentStatus = switch payload["status"]?.stringValue {
        case "completed": .completed
        case "failed": .failed
        case "aborted": .aborted
        default: .running
        }
        var events: [ProviderEvent] = []
        if status != .running, agent.isRunOpen || agent.isRunPending {
            events.append(.subagent(id: id, .runEnded(outcome: Self.outcome(status), error: status == .failed ? "The subagent failed." : nil)))
            agent.isRunOpen = false
            agent.isRunPending = false
        }
        agent.status = status
        var info = agent.info
        info.agent = payload["agent"]?.nonEmptyString ?? info.agent
        info.description = payload["description"]?.nonEmptyString ?? info.description
        info.sessionFile = payload["sessionFile"]?.nonEmptyString ?? info.sessionFile
        info.parentToolCallID = payload["parentToolCallId"]?.nonEmptyString ?? info.parentToolCallID
        info.isDetached = payload["detached"]?.boolValue ?? info.isDetached ?? false
        info.status = status
        agent.info = info
        agents[id] = agent
        events.insert(.subagent(id: id, .updated(info)), at: 0)
        return events
    }

    private mutating func progress(_ id: String, _ payload: JSONValue) -> [ProviderEvent] {
        var agent = agents[id] ?? Agent(mapper: OmpEventMapper(cwd: cwd))
        let progress = payload["progress"]
        var info = agent.info
        info.agent = info.agent ?? payload["agent"]?.nonEmptyString
        info.assignment = payload["assignment"]?.nonEmptyString ?? progress?["assignment"]?.nonEmptyString ?? info.assignment
        info.lastIntent = progress?["lastIntent"]?.nonEmptyString ?? info.lastIntent
        info.model = progress?["resolvedModelIdentity"]?.nonEmptyString ?? info.model
        info.sessionFile = info.sessionFile ?? payload["sessionFile"]?.nonEmptyString
        info.parentToolCallID = info.parentToolCallID ?? payload["parentToolCallId"]?.nonEmptyString
        guard info != agent.info else { return [] }
        agent.info = info
        agents[id] = agent
        return [.subagent(id: id, .updated(info))]
    }

    private mutating func event(_ id: String, _ event: JSONValue) -> [ProviderEvent] {
        var agent = agents[id] ?? Agent(mapper: OmpEventMapper(cwd: cwd))
        defer { agents[id] = agent }
        var events: [SubagentEvent] = []
        func openRun(_ message: String?) {
            guard agent.isRunPending || !agent.isRunOpen else { return }
            agent.isRunPending = false
            agent.isRunOpen = true
            events.append(.runStarted(message: message))
        }
        switch event["type"]?.stringValue {
        case "agent_start":
            if agent.isRunOpen { events.append(.runEnded(outcome: .completed, error: nil)) }
            agent.isRunOpen = false
            agent.isRunPending = true
            agent.status = .running
            agent.mapper.resetTurn()
        case "agent_end":
            guard agent.isRunOpen || agent.isRunPending else { break }
            if agent.isRunPending { openRun(nil) }
            let last = event["messages"]?.arrayValue?.last { $0["role"]?.stringValue == "assistant" }
            switch last?["stopReason"]?.stringValue {
            case "aborted":
                events.append(.runEnded(outcome: .interrupted, error: nil))
            case "error":
                events.append(.runEnded(outcome: .failed, error: last?["errorMessage"]?.nonEmptyString ?? "The subagent's run failed."))
            default:
                events.append(.runEnded(outcome: .completed, error: nil))
            }
            agent.isRunOpen = false
            agent.mapper.resetTurn()
        case "message_start":
            let message = event["message"]
            switch message?["role"]?.stringValue {
            case "user":
                let text = OmpEventMapper.contentText(message?["content"]) ?? ""
                if agent.isRunPending || !agent.isRunOpen {
                    openRun(text)
                } else {
                    events.append(.message(text))
                }
            case "custom":
                let (text, isMessage) = Self.customText(message)
                if agent.isRunPending || !agent.isRunOpen {
                    openRun(text)
                } else if isMessage {
                    events.append(.message(text))
                } else if !text.isEmpty {
                    agent.noticeCount += 1
                    events.append(.itemUpdated(TurnItem(id: "notice:\(agent.messageCount):\(agent.noticeCount)", kind: .notice(text: text), status: .completed)))
                }
            case "assistant":
                openRun(nil)
                agent.messageCount += 1
                agent.messageID = "m\(agent.messageCount)"
            default:
                break
            }
        case "message_update", "message_end":
            guard let messageID = agent.messageID, case var .object(object) = event else { break }
            object["messageId"] = .string(messageID)
            events += Self.subagentEvents(agent.mapper.map(.object(object)))
        case "tool_execution_start", "tool_execution_update", "tool_execution_end":
            let toolID = event["toolCallId"]?.stringValue ?? ""
            if event["type"]?.stringValue == "tool_execution_update", agent.endedTools.contains(toolID) { break }
            if event["type"]?.stringValue == "tool_execution_end" { agent.endedTools.insert(toolID) }
            openRun(nil)
            events += Self.subagentEvents(agent.mapper.map(event))
        default:
            break
        }
        return events.map { .subagent(id: id, $0) }
    }

    // MARK: - Helpers

    private static func outcome(_ status: SubagentStatus) -> ProviderTurnOutcome {
        switch status {
        case .running, .completed: .completed
        case .failed: .failed
        case .aborted: .interrupted
        }
    }

    /// The parts of the inner mapper's output a subagent shows (no usage, turn ends or dialogs).
    private static func subagentEvents(_ events: [ProviderEvent]) -> [SubagentEvent] {
        events.compactMap { event in
            switch event {
            case let .itemUpdated(item): .itemUpdated(item)
            case let .assistantDelta(itemID, delta, _): .assistantDelta(itemID: itemID, delta: delta)
            case let .reasoningDelta(itemID, delta): .reasoningDelta(itemID: itemID, delta: delta)
            case let .commandOutputDelta(itemID, delta): .commandOutputDelta(itemID: itemID, delta: delta)
            default: nil
            }
        }
    }

    /// A `custom` message as text: an `irc:incoming` message from another agent ("From Main:
    /// …", a message), or the first line of a notice (`<system-notice>` background-job results).
    static func customText(_ message: JSONValue?) -> (text: String, isMessage: Bool) {
        if message?["customType"]?.stringValue == "irc:incoming", let body = message?["details"]?["message"]?.nonEmptyString {
            let from = message?["details"]?["from"]?.nonEmptyString
            return (from.map { "From \($0): \(body)" } ?? body, true)
        }
        let raw = OmpEventMapper.contentText(message?["content"]) ?? ""
        let line = raw.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !($0.hasPrefix("<") && $0.hasSuffix(">")) }
        return (line ?? "", false)
    }
}
