import AppKit
import SopranoAgentsCore

/// What the composer's round primary button does.
enum ComposerPrimaryAction: Equatable {
    /// Idle with text or attachments: start a turn (or decline a pending approval and redirect).
    case send
    /// Idle and empty: the send button is shown disabled.
    case sendDisabled
    /// Running with text: deliver into the running turn.
    case steer
    /// Running with text: wait until the running turn ends.
    case queue
    /// Running and empty: interrupt.
    case stop

    /// - Parameters:
    ///   - isAwaitingApproval: the running turn waits on an approval; sending declines it and
    ///     delivers the message, so it is a plain send rather than a steer or queue.
    ///   - alternate: ⌘ is held (⌘-click, ⌘↩): steer and queue swap.
    static func resolve(
        isRunning: Bool,
        hasContent: Bool,
        isAwaitingApproval: Bool,
        followUp: AppSettings.FollowUp,
        alternate: Bool
    ) -> ComposerPrimaryAction {
        guard isRunning else { return hasContent ? .send : .sendDisabled }
        guard hasContent else { return .stop }
        if isAwaitingApproval { return .send }
        let queues = (followUp == .queue) != alternate
        return queues ? .queue : .steer
    }

    /// How the engine delivers the message.
    var sendMode: SendMode? {
        switch self {
        case .send: .automatic
        case .steer: .steer
        case .queue: .queue
        case .sendDisabled, .stop: nil
        }
    }

    /// Tooltip and accessibility label.
    func tooltip(followUp: AppSettings.FollowUp) -> String {
        switch self {
        case .send, .sendDisabled: "Submit message"
        case .stop: "Interrupt"
        case .steer, .queue:
            followUp == .steer
                ? "Click to steer, ⌘-click or ⌘↩ to queue"
                : "Click to queue, ⌘-click or ⌘↩ to steer"
        }
    }
}

/// Model choice rules shared by the model picker, the traits menu and the model chip.
enum ModelChoice {
    /// omp's models: its live catalog once probed, else the built-in fallback.
    static func models(status: ProviderStatus?) -> [ProviderModel] {
        let live = status?.models ?? []
        return live.isEmpty ? ProviderCatalog.fallback(.omp) : live
    }

    static func model(for selection: ModelSelection, status: ProviderStatus?) -> ProviderModel? {
        models(status: status).first { $0.slug == selection.model }
    }

    /// Option values `model` accepts: unknown option ids and values outside a select's choices
    /// are dropped, booleans must be "true"/"false".
    static func supportedOptions(_ options: [String: String], for model: ProviderModel) -> [String: String] {
        options.filter { id, value in
            guard let option = model.option(id) else { return false }
            switch option.kind {
            case .select: return option.choices.contains { $0.id == value }
            case .boolean: return value == "true" || value == "false"
            }
        }
    }

    /// Picking `model` keeps the current option values the new model supports.
    static func selecting(_ model: ProviderModel, from current: ModelSelection) -> ModelSelection {
        ModelSelection(provider: .omp, model: model.slug, options: supportedOptions(current.options, for: model))
    }

    /// The effort in effect: the explicit value when the model offers it, else the model's default.
    static func effectiveEffort(_ selection: ModelSelection, model: ProviderModel?) -> String? {
        guard let option = model?.option(ModelOptionID.effort) else { return selection.effort }
        if let explicit = selection.effort, option.choices.contains(where: { $0.id == explicit }) {
            return explicit
        }
        return option.defaultValue
    }

    /// Fast mode in effect (explicit, else the option's default).
    static func effectiveFastMode(_ selection: ModelSelection, model: ProviderModel?) -> Bool {
        guard let option = model?.option(ModelOptionID.fastMode) else { return false }
        if let explicit = selection.options[ModelOptionID.fastMode] { return explicit == "true" }
        return option.defaultValue == "true"
    }

    /// "GPT-6.1 Sol · High" (· Fast when on): the model chip's title, tooltip and accessibility label.
    static func chipTitle(_ selection: ModelSelection, status: ProviderStatus?) -> String {
        let model = model(for: selection, status: status)
        var parts = [ProviderCatalog.displayName(for: selection, in: status)]
        if let effort = effectiveEffort(selection, model: model) {
            parts.append(ProviderCatalog.effortLabel(effort))
        }
        if effectiveFastMode(selection, model: model) {
            parts.append("Fast")
        }
        return parts.joined(separator: " · ")
    }
}

/// Up/Down recall of the thread's earlier user messages in an empty editor.
struct ComposerHistory: Equatable {
    /// Oldest first.
    let entries: [String]
    /// Index into `entries` while browsing; nil = not browsing.
    private(set) var position: Int?

    init(entries: [String]) {
        self.entries = entries
    }

    /// The user messages of a thread (first messages and steers), oldest first.
    static func entries(of thread: AgentThread?) -> [String] {
        guard let thread else { return [] }
        return thread.turns
            .flatMap { [$0.userMessage] + $0.steers }
            .map(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// The entry shown right now, while browsing.
    var current: String? {
        position.map { entries[$0] }
    }

    /// One step back in time; nil when there is nothing older.
    mutating func older() -> String? {
        let next = (position ?? entries.count) - 1
        guard next >= 0, next < entries.count else { return nil }
        position = next
        return entries[next]
    }

    /// One step forward; leaving the newest entry ends browsing and returns "".
    mutating func newer() -> String? {
        guard let position else { return nil }
        if position + 1 < entries.count {
            self.position = position + 1
            return entries[position + 1]
        }
        self.position = nil
        return ""
    }

    mutating func reset() {
        position = nil
    }
}

/// Branch picker trigger label.
enum BranchLabel {
    static func trigger(branch: String?, newWorktree: Bool, isRemote: Bool = false) -> String {
        guard let branch, !branch.isEmpty else { return "Select ref" }
        guard newWorktree else { return branch }
        return isRemote ? "From \(branch) (remote)" : "From \(branch)"
    }

    /// Row badge, by priority: current → worktree → remote → default.
    static func badge(for ref: GitBranchRef, projectPath: String?) -> String? {
        if ref.isCurrent { return "current" }
        if let worktree = ref.worktreePath, worktree != projectPath { return "worktree" }
        if ref.isRemote { return "remote" }
        if ref.isDefault { return "default" }
        return nil
    }
}
