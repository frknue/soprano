import Foundation

public enum TurnItemStatus: String, Codable, Sendable, Hashable {
    case pending
    case running
    case completed
    case failed
    /// The user declined it (approval) or the provider skipped it.
    case declined
    /// The turn was interrupted while the item ran.
    case interrupted

    public var isActive: Bool { self == .pending || self == .running }
}

/// One row of a turn's activity log. Providers translate their native items into these.
public struct TurnItem: Codable, Sendable, Hashable, Identifiable {
    /// Provider-native item id (stable across started/updated/completed).
    public var id: String
    public var kind: TurnItemKind
    public var status: TurnItemStatus
    public var startedAt: Date
    public var completedAt: Date?

    public init(id: String, kind: TurnItemKind, status: TurnItemStatus = .running, startedAt: Date = Date(), completedAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

public enum TurnItemKind: Codable, Sendable, Hashable {
    /// Assistant prose (Markdown). `isFinal` = the turn's answer; false = commentary between tool calls.
    case assistantMessage(text: String, isFinal: Bool)
    /// Reasoning summary ("Thinking").
    case reasoning(text: String)
    /// Shell command. `output` grows while it runs.
    case command(CommandExecution)
    /// File edits the agent made (one item may touch several files).
    case fileChange([FileChange])
    /// Any other tool: read/grep/glob, MCP, dynamic tools, subagents.
    case toolCall(ToolCall)
    case webSearch(query: String)
    /// The agent's task list (Codex `turn/plan/updated`, Claude `TodoWrite`).
    case todoList(steps: [TodoStep], explanation: String?)
    /// Proposed plan (plan mode; Codex `plan` item, Claude `ExitPlanMode`).
    case plan(markdown: String)
    case approval(ApprovalRequest)
    case userInput(UserInputRequest)
    case error(message: String)
    /// Informational divider ("Context compacted").
    case notice(text: String)
}

public struct CommandExecution: Codable, Sendable, Hashable {
    public var command: String
    public var cwd: String?
    public var output: String
    public var exitCode: Int?
    public var durationMs: Int?

    public init(command: String, cwd: String? = nil, output: String = "", exitCode: Int? = nil, durationMs: Int? = nil) {
        self.command = command
        self.cwd = cwd
        self.output = output
        self.exitCode = exitCode
        self.durationMs = durationMs
    }
}

public struct FileChange: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case add
        case delete
        case update
        case move
    }

    public var path: String
    public var kind: Kind
    /// Destination for moves.
    public var movePath: String?
    /// Unified diff of this file when the provider reports one.
    public var diff: String?

    public init(path: String, kind: Kind, movePath: String? = nil, diff: String? = nil) {
        self.path = path
        self.kind = kind
        self.movePath = movePath
        self.diff = diff
    }
}

public struct ToolCall: Codable, Sendable, Hashable {
    public enum Category: String, Codable, Sendable, Hashable {
        /// Read/view a file.
        case read
        /// grep/glob/ls/find.
        case search
        case mcp
        case subagent
        case other
    }

    /// Native tool name ("Read", "Grep", "github.create_issue").
    public var name: String
    public var category: Category
    /// One-line label for the work log ("Read Sources/App.swift", "Searched TODO in Sources").
    public var title: String
    /// Pretty-printed input (JSON or text), shown when the row is expanded.
    public var input: String?
    public var output: String?

    public init(name: String, category: Category, title: String, input: String? = nil, output: String? = nil) {
        self.name = name
        self.category = category
        self.title = title
        self.input = input
        self.output = output
    }
}

public struct TodoStep: Codable, Sendable, Hashable, Identifiable {
    public enum Status: String, Codable, Sendable, Hashable {
        case pending
        case inProgress
        case completed
    }

    public var id: String
    public var text: String
    public var status: Status

    public init(id: String, text: String, status: Status) {
        self.id = id
        self.text = text
        self.status = status
    }
}

public enum ApprovalKind: String, Codable, Sendable, Hashable {
    case command
    case fileChange
    case fileRead
    case permission
    case other

    public var title: String {
        switch self {
        case .command: "Command approval"
        case .fileChange: "File change approval"
        case .fileRead: "File read approval"
        case .permission: "Permission approval"
        case .other: "Approval"
        }
    }
}

/// Answers to an approval. Same vocabulary as T3 Code and the Codex app-server.
public enum ApprovalDecision: String, Codable, Sendable, Hashable, CaseIterable {
    case accept
    case acceptForSession
    case decline
    case cancel

    public var title: String {
        switch self {
        case .accept: "Approve"
        case .acceptForSession: "Always allow this session"
        case .decline: "Decline"
        case .cancel: "Cancel"
        }
    }
}

/// The agent wants permission. Lives in the activity log as `.approval`; `decision` is set once answered.
public struct ApprovalRequest: Codable, Sendable, Hashable, Identifiable {
    /// Request id the provider expects in the answer.
    public var id: String
    public var kind: ApprovalKind
    /// What is being approved: the command line, file path, or tool description.
    public var detail: String
    /// Why the agent asks, when it says.
    public var reason: String?
    /// Decisions the provider accepts, in display order (Cancel, Decline, Always…, Approve).
    public var options: [ApprovalDecision]
    public var decision: ApprovalDecision?
    /// Feedback sent with a decline ("do it differently").
    public var feedback: String?

    public init(
        id: String,
        kind: ApprovalKind,
        detail: String,
        reason: String? = nil,
        options: [ApprovalDecision] = [.cancel, .decline, .acceptForSession, .accept],
        decision: ApprovalDecision? = nil,
        feedback: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.detail = detail
        self.reason = reason
        self.options = options
        self.decision = decision
        self.feedback = feedback
    }
}

public struct UserInputOption: Codable, Sendable, Hashable {
    public var label: String
    public var description: String?

    public init(label: String, description: String? = nil) {
        self.label = label
        self.description = description
    }
}

public struct UserInputQuestion: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// Short chip text ("Database").
    public var header: String
    public var question: String
    public var options: [UserInputOption]
    public var allowsMultiple: Bool
    /// A free-text answer is allowed besides the options.
    public var allowsOther: Bool

    public init(id: String, header: String, question: String, options: [UserInputOption], allowsMultiple: Bool = false, allowsOther: Bool = true) {
        self.id = id
        self.header = header
        self.question = question
        self.options = options
        self.allowsMultiple = allowsMultiple
        self.allowsOther = allowsOther
    }
}

/// The agent asks the user structured questions (Codex `item/tool/requestUserInput`, Claude `AskUserQuestion`).
public struct UserInputRequest: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var questions: [UserInputQuestion]
    /// Question id → selected labels or free text. nil until answered.
    public var answers: [String: [String]]?
    public var dismissed: Bool

    public init(id: String, questions: [UserInputQuestion], answers: [String: [String]]? = nil, dismissed: Bool = false) {
        self.id = id
        self.questions = questions
        self.answers = answers
        self.dismissed = dismissed
    }
}
