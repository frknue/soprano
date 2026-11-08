import Foundation

/// An agent CLI's own transcript (`AgentTimeline`, read by the Claude Code, Codex, omp and
/// OpenCode decoders) as the chat's turns, so the Agent Dashboard shows a terminal agent's
/// conversation in the chat timeline: each prompt starts a turn, and the replies, thinking,
/// tool calls and notices after it land in that turn in order. While the agent works the last
/// turn runs; a finished turn's last reply is its answer, the replies before it commentary the
/// "Worked for" fold hides. Items before the first prompt (the transcript's head fell off
/// `AgentTimeline.itemLimit`) open a turn without a message.
extension ChatThread {
    init(transcript: AgentTimeline, isRunning: Bool) {
        var preamble: [TurnItem] = []
        var turns: [Turn] = []
        for item in transcript.items {
            if case .prompt(let text) = item.kind {
                turns.append(Turn(
                    id: item.id,
                    userMessage: UserMessage(id: item.id, text: text, createdAt: item.timestamp),
                    status: .completed,
                    startedAt: item.timestamp
                ))
                continue
            }
            guard let turnItem = Self.turnItem(for: item) else { continue }
            if turns.isEmpty {
                switch turnItem.kind {
                case .notice, .error:
                    preamble.append(turnItem)
                    continue
                default:
                    turns.append(Turn(
                        id: "transcript-head",
                        userMessage: UserMessage(id: "transcript-head", text: "", createdAt: nil),
                        status: .completed,
                        startedAt: item.timestamp
                    ))
                }
            }
            turns[turns.count - 1].items.append(turnItem)
        }

        for index in turns.indices {
            let running = isRunning && index == turns.count - 1
            turns[index].status = running ? .running : .completed
            turns[index].completedAt = running ? nil : turns[index].items.compactMap { $0.completedAt ?? $0.startedAt }.max()
            // A turn's answer is its last reply once it has finished.
            if !running, let answer = turns[index].items.lastIndex(where: {
                if case .assistantMessage = $0.kind { return true }
                return false
            }), case .assistantMessage(let text, _) = turns[index].items[answer].kind {
                turns[index].items[answer].kind = .assistantMessage(text: text, isFinal: true)
            }
        }
        self.init(preamble: preamble, turns: turns, queue: [])
    }

    private static func turnItem(for item: AgentTimelineItem) -> TurnItem? {
        switch item.kind {
        case .prompt:
            return nil
        case .reply(let text):
            return TurnItem(id: item.id, kind: .assistantMessage(text: text, isFinal: false), status: .completed,
                            startedAt: item.timestamp, completedAt: item.timestamp)
        case .thinking(let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return TurnItem(id: item.id, kind: .reasoning(text: text), status: .completed,
                            startedAt: item.timestamp, completedAt: item.timestamp)
        case .notice(let text, let isError):
            return TurnItem(id: item.id, kind: isError ? .error(message: text) : .notice(text: text), status: .completed,
                            startedAt: item.timestamp, completedAt: item.timestamp)
        case .tool(let call):
            let status: TurnItemStatus = switch call.state {
            case .running: .running
            case .succeeded: .completed
            case .failed: .failed
            case .interrupted: .interrupted
            }
            return TurnItem(id: item.id, kind: kind(of: call), status: status,
                            startedAt: item.timestamp, completedAt: call.finishedAt)
        }
    }

    /// What a CLI's tool call reads as in the work log, by the tool names the decoders give.
    static func kind(of call: AgentToolCall) -> TurnItemKind {
        let name = call.name.lowercased()
        let summary = call.summary
        if commandTools.contains(name) {
            let exitCode: Int? = switch call.state {
            case .succeeded: 0
            case .failed: 1
            case .running, .interrupted: nil
            }
            return .command(TurnCommand(command: call.detail ?? summary, output: call.output ?? "", exitCode: exitCode))
        }
        if editTools.contains(name) || call.diff != nil {
            return .fileChange(fileChanges(of: call, name: name))
        }
        let input = call.detail
        switch name {
        case "read", "view":
            return .toolCall(ToolCall(name: call.name, category: .read, title: summary.isEmpty ? "Read file" : "Read \(summary)",
                                      input: input, output: call.output))
        case "grep", "glob", "search", "list", "find", "ls", "ast_grep", "codesearch":
            return .toolCall(ToolCall(name: call.name, category: .search, title: summary.isEmpty ? "Searched files" : "Searched \(summary)",
                                      input: input, output: call.output))
        case "websearch", "web_search":
            return .webSearch(query: summary)
        case "task", "agent", "subagent":
            return .toolCall(ToolCall(name: call.name, category: .subagent, title: summary.isEmpty ? "Subagent" : "Subagent: \(summary)",
                                      input: input, output: call.output))
        default:
            return .toolCall(ToolCall(name: call.name, category: .other, title: summary.isEmpty ? call.name : "\(call.name) \(summary)",
                                      input: input, output: call.output))
        }
    }

    private static let commandTools: Set<String> = ["bash", "run", "shell", "exec", "exec_command", "local_shell", "execute"]
    private static let editTools: Set<String> = [
        "edit", "multiedit", "write", "notebookedit", "add", "delete", "apply_patch", "patch", "ast_edit",
    ]

    /// The files one edit touched. Codex joins a multi-file change's diffs, each led by
    /// `diff <path>`; every other call names its one file in its summary.
    private static func fileChanges(of call: AgentToolCall, name: String) -> [FileChange] {
        let kind: FileChange.Kind = switch name {
        case "add": .add
        case "delete": .delete
        default: .update
        }
        let isWrite = name == "write"
        func isFileHeader(_ line: Substring) -> Bool { line.hasPrefix("diff ") && !line.hasPrefix("diff --") }
        guard let diff = call.diff, isFileHeader(diff[...]) else {
            return [FileChange(path: call.summary, kind: kind, diff: call.diff, isFullContent: isWrite ? true : nil)]
        }
        var changes: [FileChange] = []
        var lines: [Substring] = []
        func flush() {
            guard let header = lines.first else { return }
            changes.append(FileChange(
                path: String(header.dropFirst("diff ".count)),
                kind: kind,
                diff: lines.dropFirst().joined(separator: "\n")
            ))
        }
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if isFileHeader(line) {
                flush()
                lines = [line]
            } else {
                lines.append(line)
            }
        }
        flush()
        return changes
    }
}
