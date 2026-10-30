import Foundation

/// The agent CLIs Soprano Agents drives. One thread talks to exactly one provider.
/// Declaration order is display order (pickers, settings): omp first.
public enum ProviderKind: String, Codable, Sendable, CaseIterable, Hashable {
    /// `omp --mode rpc-ui` (oh-my-pi's JSONL RPC with host-rendered tool UI: approvals, `ask`).
    case omp
    /// `codex app-server` (JSON-RPC over stdio).
    case codex
    /// `claude -p --input-format stream-json --output-format stream-json` with the stdio control protocol.
    case claude

    public var displayName: String {
        switch self {
        case .omp: "omp"
        case .codex: "Codex"
        case .claude: "Claude Code"
        }
    }

    /// The CLI's executable name.
    public var executableName: String {
        switch self {
        case .omp: "omp"
        case .codex: "codex"
        case .claude: "claude"
        }
    }

    /// Build/Plan applies: omp's RPC has no plan-mode switch, so its composer hides the toggle.
    public var supportsPlanMode: Bool { self != .omp }

    /// Default chat model when the provider's live catalog is not known yet. For omp this is
    /// `ModelSelection.ompDefaultModel`: whatever omp itself is configured to use.
    public var defaultModel: String {
        switch self {
        case .omp: ModelSelection.ompDefaultModel
        case .codex: "gpt-6.1-sol"
        case .claude: "claude-opus-5-5"
        }
    }

    /// Default model for background text generation (titles, commit messages, branch names).
    public var textGenerationModel: String {
        switch self {
        case .omp: ModelSelection.ompDefaultModel
        case .codex: "gpt-6-luna"
        case .claude: "claude-haiku-5-5"
        }
    }
}

/// How much the agent may do without asking. Four modes with fixed labels.
public enum RuntimeMode: String, Codable, Sendable, CaseIterable, Hashable {
    case approvalRequired = "approval-required"
    case autoAcceptEdits = "auto-accept-edits"
    case auto
    case fullAccess = "full-access"

    public var title: String {
        switch self {
        case .approvalRequired: "Supervised"
        case .autoAcceptEdits: "Auto-accept edits"
        case .auto: "Auto"
        case .fullAccess: "Full access"
        }
    }

    public var summary: String {
        switch self {
        case .approvalRequired: "Ask before running commands or changing files."
        case .autoAcceptEdits: "Edit files freely; ask before running commands."
        case .auto: "Let the agent decide when to ask."
        case .fullAccess: "Run commands and edit files without asking."
        }
    }

    /// SF Symbol shown in the permissions chip and menu.
    public var symbolName: String {
        switch self {
        case .approvalRequired: "lock"
        case .autoAcceptEdits: "pencil.line"
        case .auto: "sparkles"
        case .fullAccess: "shield.slash"
        }
    }
}

/// Build (default) or Plan. Plan asks the agent for a plan instead of changes.
public enum InteractionMode: String, Codable, Sendable, CaseIterable, Hashable {
    case build = "default"
    case plan

    public var title: String {
        switch self {
        case .build: "Build"
        case .plan: "Plan"
        }
    }
}

/// One selectable value of a model option (e.g. reasoning effort "high").
public struct ModelOptionChoice: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public var description: String?

    public init(id: String, label: String, description: String? = nil) {
        self.id = id
        self.label = label
        self.description = description
    }
}

/// A provider-supplied option for a model: a select (effort, service tier) or a boolean (fast mode).
public struct ModelOption: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case select
        case boolean
    }

    /// Stable id; also the key in `ModelSelection.options`. Known ids: `effort`, `fastMode`, `serviceTier`.
    public var id: String
    public var label: String
    public var kind: Kind
    public var choices: [ModelOptionChoice]
    /// Default choice id for selects, "true"/"false" for booleans.
    public var defaultValue: String

    public init(id: String, label: String, kind: Kind, choices: [ModelOptionChoice] = [], defaultValue: String) {
        self.id = id
        self.label = label
        self.kind = kind
        self.choices = choices
        self.defaultValue = defaultValue
    }
}

/// A model a provider offers.
public struct ProviderModel: Codable, Sendable, Hashable, Identifiable {
    public var id: String { slug }
    /// Id sent to the provider (`gpt-6.1-sol`, `claude-opus-5-5`).
    public var slug: String
    /// Display name ("GPT-6.1 Sol", "Claude Opus 5.5").
    public var name: String
    public var isDefault: Bool
    public var options: [ModelOption]

    public init(slug: String, name: String, isDefault: Bool = false, options: [ModelOption] = []) {
        self.slug = slug
        self.name = name
        self.isDefault = isDefault
        self.options = options
    }

    public func option(_ id: String) -> ModelOption? {
        options.first { $0.id == id }
    }
}

/// What the app knows about an installed provider CLI after probing it.
public struct ProviderStatus: Codable, Sendable, Hashable, Identifiable {
    public enum Health: String, Codable, Sendable, Hashable {
        case unknown
        case ready
        case notInstalled
        case unauthenticated
        case error
    }

    public var id: ProviderKind { kind }
    public var kind: ProviderKind
    public var health: Health
    /// CLI version ("0.166.0", "2.1.314").
    public var version: String?
    /// Account label ("ChatGPT Pro 100 Subscription", "Claude Max").
    public var accountLabel: String?
    public var models: [ProviderModel]
    /// Human-readable problem when `health` is not `ready`.
    public var message: String?

    public init(
        kind: ProviderKind,
        health: Health = .unknown,
        version: String? = nil,
        accountLabel: String? = nil,
        models: [ProviderModel] = [],
        message: String? = nil
    ) {
        self.kind = kind
        self.health = health
        self.version = version
        self.accountLabel = accountLabel
        self.models = models
        self.message = message
    }

    public var defaultModel: ProviderModel? {
        models.first(where: \.isDefault) ?? models.first
    }
}

/// Provider + model + option values for a thread or a single turn.
public struct ModelSelection: Codable, Sendable, Hashable {
    public var provider: ProviderKind
    public var model: String
    /// Option id → value (`effort` → `high`, `fastMode` → `true`). Missing = the model's default.
    public var options: [String: String]

    public init(provider: ProviderKind, model: String, options: [String: String] = [:]) {
        self.provider = provider
        self.model = model
        self.options = options
    }

    public static func `default`(for provider: ProviderKind) -> ModelSelection {
        ModelSelection(provider: provider, model: provider.defaultModel)
    }

    public var effort: String? {
        get { options[ModelOptionID.effort] }
        set { options[ModelOptionID.effort] = newValue }
    }

    public var fastMode: Bool {
        get { options[ModelOptionID.fastMode] == "true" }
        set { options[ModelOptionID.fastMode] = newValue ? "true" : nil }
    }
}

extension ModelSelection {
    /// omp model id meaning "omp's own configured default" (no `--model`, no `set_model`).
    /// Real omp models are `provider/id` (`anthropic/claude-opus-5-5`).
    public static let ompDefaultModel = "default"
}

public enum ModelOptionID {
    public static let effort = "effort"
    public static let fastMode = "fastMode"
    public static let serviceTier = "serviceTier"
}
