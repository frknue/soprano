import Foundation
import SopranoAgentsCore

/// SF Symbols of the timeline. Kept apart from the shared
/// `Icon` so the timeline's additions never collide with other regions'.
enum TimelineIcon {
    static let workRead = "eye"
    static let workEdit = "square.and.pencil"
    static let workCommand = "terminal"
    static let workWeb = "globe"
    static let workSearch = "magnifyingglass"
    static let workTool = "wrench"
    static let workMixed = "hammer"
    static let workReasoning = "brain"
    static let workAgent = "cpu"
    static let workMessage = "bubble.left"
    static let circleX = "xmark"
    static let ellipsis = "ellipsis"
    static let folder = "folder"
    static let folderOpen = "folder"
    static let file = "doc"
    static let fileDiffOpen = "doc.text.magnifyingglass"
    static let pencil = "pencil"
    static let redo = "arrow.uturn.right"
    static let chevronUp = "chevron.up"
    static let close = "xmark"
    static let minimize = "arrow.down.right.and.arrow.up.left"
    static let shield = "shield"
    static let advisor = "text.bubble"
    static let checks = "checkmark.shield"
    static let unfoldAll = "chevron.up.chevron.down"
}

/// One row of the work log, derived from a `TurnItem`. Pure data; the timeline renders it.
struct WorkLogEntry: Hashable, Identifiable, Sendable {
    enum Kind: Hashable, Sendable {
        case reasoning
        case command
        case fileChange
        case read
        case codeSearch
        case webSearch
        case tool
        case subagent
        case approval
        case userInput
    }

    /// The summary bucket ("Read 3 files", "Ran 2 commands", …).
    enum Action: Hashable, Sendable {
        case read
        case edit
        case command
        case search
        case codeSearch
        case other
    }

    var id: String
    var kind: Kind
    var status: TurnItemStatus
    var startedAt: Date
    /// One-line label: "Ran command", "Changed Sources/App.swift", "Read …", "Thought".
    var label: String
    /// Text after the label: the command (mono), the search query, the thought line.
    var detail: String?
    var detailIsCode: Bool
    /// Trailing note: an approval's decision, a dismissed question.
    var note: String?
    /// Shown when the row expands (output, diff, tool input/output, the full thought).
    var body: String?
    /// The body is Markdown (reasoning, question answers) rather than monospaced output.
    var bodyIsMarkdown: Bool
    var changedFiles: [String]
    var icon: String
    /// The files of a file change, each shown as its own diff row.
    var fileChanges: [FileChange] = []

    var isToolLike: Bool { kind != .reasoning }
    var isFailed: Bool { status == .failed }
    var isActive: Bool { status.isActive }
    var canExpand: Bool { !(body ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var action: Action {
        switch kind {
        case .read: .read
        case .fileChange: .edit
        case .command: .command
        case .webSearch: .search
        case .codeSearch: .codeSearch
        case .reasoning, .tool, .subagent, .approval, .userInput: .other
        }
    }

    /// Reasoning without text never shows.
    var isVisible: Bool {
        kind != .reasoning || !(body ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Work-log presentation: entry labels, group summaries, live labels, thought lines.
enum WorkLog {
    /// The work-log entry for an item, nil for items the timeline shows as their own rows
    /// (assistant messages, errors, notices, advisor notes).
    static func entry(for item: TurnItem) -> WorkLogEntry? {
        func make(
            _ kind: WorkLogEntry.Kind,
            label: String,
            detail: String? = nil,
            detailIsCode: Bool = false,
            note: String? = nil,
            body: String? = nil,
            bodyIsMarkdown: Bool = false,
            changedFiles: [String] = [],
            icon: String
        ) -> WorkLogEntry {
            WorkLogEntry(
                id: item.id, kind: kind, status: item.status, startedAt: item.startedAt, label: label,
                detail: detail?.isEmpty == true ? nil : detail, detailIsCode: detailIsCode, note: note,
                body: body, bodyIsMarkdown: bodyIsMarkdown, changedFiles: changedFiles, icon: icon
            )
        }

        switch item.kind {
        case let .reasoning(text):
            let line = thoughtLine(text)
            return make(
                .reasoning,
                label: item.status.isActive ? "Thinking" : "Thought",
                detail: line,
                body: text,
                bodyIsMarkdown: true,
                icon: TimelineIcon.workReasoning
            )
        case let .command(command):
            var body = "$ \(command.command)"
            let output = command.output.trimmingCharacters(in: .newlines)
            if !output.isEmpty { body += "\n\(output)" }
            if let exit = command.exitCode, exit != 0 { body += "\n\nExit code \(exit)" }
            return make(.command, label: item.status.isActive ? "Running command" : "Ran command", detail: singleLine(command.command), detailIsCode: true, body: body, icon: TimelineIcon.workCommand)
        case let .fileChange(changes):
            let paths = changes.map { $0.movePath ?? $0.path }
            let verb = item.status.isActive ? "Editing" : "Changed"
            let label = changes.count == 1 ? "\(verb) \(paths[0])" : "\(verb) \(changes.count) files"
            let diffs = changes.compactMap(\.diff).filter { !$0.isEmpty }
            let body = diffs.isEmpty
                ? changes.map { "\(fileChangeVerb($0.kind)) \(changeDescription($0))" }.joined(separator: "\n")
                : diffs.joined(separator: "\n")
            var entry = make(.fileChange, label: changes.isEmpty ? "\(verb) files" : label, body: body, changedFiles: paths, icon: TimelineIcon.workEdit)
            entry.fileChanges = changes
            return entry
        case let .toolCall(tool):
            let body = [tool.input, tool.output]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            let title = tool.title.trimmingCharacters(in: .whitespacesAndNewlines)
            switch tool.category {
            case .read:
                return make(.read, label: title.isEmpty ? "Read file" : title, body: body, icon: TimelineIcon.workRead)
            case .search:
                return make(.codeSearch, label: title.isEmpty ? "Searched files" : title, body: body, icon: TimelineIcon.workSearch)
            case .subagent:
                return make(.subagent, label: title.isEmpty ? (tool.name.isEmpty ? "Subagent" : tool.name) : title, body: body, icon: TimelineIcon.workAgent)
            case .other:
                let name = tool.name.trimmingCharacters(in: .whitespaces)
                return make(.tool, label: title.isEmpty ? (name.isEmpty ? "Tool call" : name) : title, body: body, icon: TimelineIcon.workTool)
            }
        case let .webSearch(query):
            return make(.webSearch, label: "Searched the web", detail: singleLine(query), body: query, icon: TimelineIcon.workWeb)
        case let .approval(request):
            let reason = request.reason.map { "\($0)\n\n" } ?? ""
            return make(
                .approval,
                label: "Approval requested",
                detail: singleLine(request.detail.isEmpty ? request.kind.title : request.detail),
                detailIsCode: request.kind == .command || request.kind == .fileChange || request.kind == .fileRead,
                note: request.decision.map(decisionNote),
                body: reason + request.detail,
                icon: TimelineIcon.workMessage
            )
        case let .userInput(request):
            let answered = request.answers != nil
            return make(
                .userInput,
                label: answered ? "Answered questions" : "Input requested",
                detail: request.questions.first.map { singleLine($0.question) },
                note: request.dismissed ? "Dismissed" : answered ? answerPreview(request) : nil,
                body: answered ? questionAnswerMarkdown(request) : request.questions.map(\.question).joined(separator: "\n\n"),
                bodyIsMarkdown: true,
                icon: TimelineIcon.workMessage
            )
        case .assistantMessage, .error, .notice, .advisory:
            return nil
        }
    }

    // MARK: Summaries

    /// "Read 3 files and ran 2 commands", "Thought", "Thought (×3)".
    static func summary(_ entries: [WorkLogEntry]) -> String {
        let tools = entries.filter(\.isToolLike)
        if !entries.isEmpty, tools.isEmpty {
            return entries.count == 1 ? "Thought" : "Thought (×\(entries.count))"
        }
        var order: [WorkLogEntry.Action] = []
        var grouped: [WorkLogEntry.Action: [WorkLogEntry]] = [:]
        for entry in tools {
            if grouped[entry.action] == nil { order.append(entry.action) }
            grouped[entry.action, default: []].append(entry)
        }
        let summaries = order.enumerated().map { index, action in
            (index: index, action: action, count: grouped[action]!.count, label: actionLabel(action, count: actionCount(action, grouped[action]!)))
        }
        let selected = summaries
            .sorted { (priority($0.action), $0.index) < (priority($1.action), $1.index) }
            .prefix(2)
            .sorted { $0.index < $1.index }
        var labels = selected.map(\.label)
        let remaining = tools.count - selected.reduce(0) { $0 + $1.count }
        if remaining > 0 {
            labels.append("Performed \(remaining) other \(remaining == 1 ? "action" : "actions")")
        }
        let sentence = labels.enumerated().map { index, label in
            index == 0 ? label : label.prefix(1).lowercased() + label.dropFirst()
        }
        if sentence.count < 3 { return sentence.joined(separator: " and ") }
        return sentence.dropLast().joined(separator: ", ") + ", and " + sentence.last!
    }

    /// Icon of a group header: the shared action's icon, brain for reasoning-only, hammer when mixed.
    static func summaryIcon(_ entries: [WorkLogEntry]) -> String {
        let tools = entries.filter(\.isToolLike)
        if !entries.isEmpty, tools.isEmpty { return TimelineIcon.workReasoning }
        let actions = Set(tools.map(\.action))
        guard actions.count == 1, let action = actions.first else { return TimelineIcon.workMixed }
        switch action {
        case .read: return TimelineIcon.workRead
        case .edit: return TimelineIcon.workEdit
        case .command: return TimelineIcon.workCommand
        case .search: return TimelineIcon.workWeb
        case .codeSearch: return TimelineIcon.workSearch
        case .other:
            let kinds = Set(tools.map(\.kind))
            return kinds.count == 1 ? (tools.first?.icon ?? TimelineIcon.workTool) : TimelineIcon.workMixed
        }
    }

    /// Label of the live activity row ("Running swift", "Thinking", "Changed App.swift").
    static func liveLabel(_ entry: WorkLogEntry) -> String {
        switch entry.kind {
        case .reasoning:
            return entry.detail ?? (entry.isActive ? "Thinking" : "Thought")
        case .command:
            let verb = switch entry.status {
            case .pending, .running: "Running"
            case .failed: "Failed"
            case .declined: "Declined"
            case .interrupted: "Stopped"
            case .completed: "Ran"
            }
            return "\(verb) \(programName(entry.detail ?? "") ?? "command")"
        default:
            return entry.detail.map { "\(entry.label) \($0)" } ?? entry.label
        }
    }

    /// First sentence (or bold heading) of a reasoning summary, Markdown stripped, one line
    ///.
    static func thoughtLine(_ markdown: String) -> String {
        let trimmedStart = markdown.drop { $0 == " " || $0 == "\t" || $0 == "\n" }
        var heading: String?
        if trimmedStart.hasPrefix("**") {
            let rest = trimmedStart.dropFirst(2)
            if let close = rest.range(of: "**") {
                let candidate = rest[..<close.lowerBound]
                let after = rest[close.upperBound...].prefix { $0 != "\n" }
                if !candidate.isEmpty, !candidate.contains("\n"), after.trimmingCharacters(in: .whitespaces).isEmpty {
                    heading = String(candidate)
                }
            }
        }
        var text = heading ?? markdown
        text = text.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^[ \t]*(?:#{1,6}|[-*+]|\d+\.)[ \t]+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"`+|\*\*|~~"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(^|[^\w*])[*_]([^*_\n]+)[*_](?![\w*])"#, with: "$1$2", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespaces)
        if heading != nil { return text }
        if let end = text.range(of: #"[.?!]["'”’)]?(?=\s)"#, options: .regularExpression) {
            return String(text[..<end.upperBound])
        }
        return text
    }

    static func decisionNote(_ decision: ApprovalDecision) -> String {
        switch decision {
        case .accept: "Approved"
        case .acceptForSession: "Always allowed"
        case .decline: "Declined"
        case .cancel: "Cancelled"
        }
    }

    // MARK: Helpers

    private static func priority(_ action: WorkLogEntry.Action) -> Int {
        switch action {
        case .command, .edit: 0
        case .other: 2
        case .read, .search, .codeSearch: 1
        }
    }

    private static func actionCount(_ action: WorkLogEntry.Action, _ entries: [WorkLogEntry]) -> Int {
        guard action == .edit else { return entries.count }
        var files: Set<String> = []
        var withoutFiles = 0
        for entry in entries {
            if entry.changedFiles.isEmpty { withoutFiles += 1 } else { files.formUnion(entry.changedFiles) }
        }
        return files.count + withoutFiles
    }

    private static func actionLabel(_ action: WorkLogEntry.Action, count: Int) -> String {
        switch action {
        case .read: "Read \(count) \(count == 1 ? "file" : "files")"
        case .edit: "Changed \(count) \(count == 1 ? "file" : "files")"
        case .command: "Ran \(count) \(count == 1 ? "command" : "commands")"
        case .search: "Searched the web \(count) \(count == 1 ? "time" : "times")"
        case .codeSearch: "Searched code \(count) \(count == 1 ? "time" : "times")"
        case .other: "Used \(count) \(count == 1 ? "tool" : "tools")"
        }
    }

    /// The program a command line runs ("swift" for `swift build`, "rg" for `cd x && rg …`).
    static func programName(_ command: String) -> String? {
        let segment = command.components(separatedBy: "&&").last ?? command
        for token in segment.split(separator: " ") {
            let word = String(token)
            if word.contains("=") && !word.hasPrefix("-") { continue }
            if ["sudo", "env", "time", "exec"].contains(word) { continue }
            let name = word.split(separator: "/").last.map(String.init) ?? word
            return name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'();"))
        }
        return nil
    }

    private static func singleLine(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s*\n\s*"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    private static func fileChangeVerb(_ kind: FileChange.Kind) -> String {
        switch kind {
        case .add: "Added"
        case .delete: "Deleted"
        case .update: "Updated"
        case .move: "Moved"
        }
    }

    private static func changeDescription(_ change: FileChange) -> String {
        if let destination = change.movePath { return "\(change.path) → \(destination)" }
        return change.path
    }

    private static func answerPreview(_ request: UserInputRequest) -> String? {
        guard let answers = request.answers else { return nil }
        let values = request.questions.compactMap { answers[$0.id]?.joined(separator: ", ") }.filter { !$0.isEmpty }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    private static func questionAnswerMarkdown(_ request: UserInputRequest) -> String {
        request.questions.map { question in
            let answer = request.answers?[question.id]?.joined(separator: ", ") ?? "—"
            return "**\(question.question)**\n\n\(answer)"
        }.joined(separator: "\n\n")
    }
}
