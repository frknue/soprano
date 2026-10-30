import Foundation

/// Built-in model catalogs. Codex reports its live catalog through `model/list`; these lists are
/// the fallback before the first probe and for Claude, whose CLI has no model listing. Ids and
/// option sets follow T3 Code's bundled manifest (2026-10-28) and the Codex 0.166 catalog.
public enum ProviderCatalog {
    public static func fallback(_ kind: ProviderKind) -> [ProviderModel] {
        switch kind {
        case .omp: ompModels
        case .codex: codexModels
        case .claude: claudeModels
        }
    }

    /// Effort labels shared by both providers (T3 Code's `CodexProvider.ts` labels).
    public static func effortLabel(_ id: String) -> String {
        switch id {
        case "none": "None"
        case "minimal": "Minimal"
        case "low": "Low"
        case "medium": "Medium"
        case "high": "High"
        case "xhigh": "Extra High"
        case "max": "Max"
        case "ultra": "Ultra"
        case "ultrathink": "Ultrathink"
        default: id.prefix(1).uppercased() + id.dropFirst()
        }
    }

    public static func effortOption(_ ids: [String], default defaultID: String, label: String = "Reasoning") -> ModelOption {
        ModelOption(
            id: ModelOptionID.effort,
            label: label,
            kind: .select,
            choices: ids.map { ModelOptionChoice(id: $0, label: effortLabel($0)) },
            defaultValue: defaultID
        )
    }

    public static let fastModeOption = ModelOption(id: ModelOptionID.fastMode, label: "Fast Mode", kind: .boolean, defaultValue: "false")

    /// "gpt-6.1-sol" → "GPT-6.1 Sol" (T3 Code's `formatCodexModelName`: uppercase a leading `gpt`,
    /// capitalize each word after a dash, keep the version glued to the prefix).
    public static func codexDisplayName(_ slug: String) -> String {
        var parts = slug.split(separator: "-").map(String.init)
        guard !parts.isEmpty else { return slug }
        if parts[0].lowercased() == "gpt" {
            parts[0] = "GPT"
            if parts.count > 1, parts[1].first?.isNumber == true {
                let head = "GPT-" + parts[1]
                let rest = parts.dropFirst(2).map { $0.prefix(1).uppercased() + $0.dropFirst() }
                return ([head] + rest).joined(separator: " ")
            }
        }
        return parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    private static let codexEfforts = ["low", "medium", "high", "xhigh", "max", "ultra"]

    static let codexModels: [ProviderModel] = [
        ProviderModel(slug: "gpt-6.1-sol", name: "GPT-6.1 Sol", isDefault: true, options: [effortOption(codexEfforts, default: "low"), fastModeOption]),
        ProviderModel(slug: "gpt-6-astra", name: "GPT-6 Astra", options: [effortOption(codexEfforts, default: "medium"), fastModeOption]),
        ProviderModel(slug: "gpt-6.1-terra", name: "GPT-6.1 Terra", options: [effortOption(codexEfforts, default: "low"), fastModeOption]),
        ProviderModel(slug: "gpt-6-sol", name: "GPT-6 Sol", options: [effortOption(codexEfforts, default: "medium"), fastModeOption]),
        ProviderModel(slug: "gpt-6-luna", name: "GPT-6 Luna", options: [effortOption(["low", "medium", "high", "xhigh", "max"], default: "medium"), fastModeOption]),
    ]

    private static let claudeEfforts = ["low", "medium", "high", "xhigh", "max", "ultrathink"]

    static let claudeModels: [ProviderModel] = [
        ProviderModel(slug: "claude-opus-5-5", name: "Claude Opus 5.5", isDefault: true, options: [effortOption(claudeEfforts, default: "medium"), fastModeOption]),
        ProviderModel(slug: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", options: [effortOption(claudeEfforts, default: "high")]),
        ProviderModel(slug: "claude-fable-5-1", name: "Claude Fable 5.1", options: [effortOption(claudeEfforts, default: "medium")]),
        ProviderModel(slug: "claude-haiku-5-5", name: "Claude Haiku 5.5", options: [effortOption(claudeEfforts, default: "medium")]),
    ]

    /// Before the first probe omp offers only "its configured default"; the probe replaces this
    /// with omp's live catalog (`get_available_models`).
    static let ompModels: [ProviderModel] = [
        ProviderModel(slug: ModelSelection.ompDefaultModel, name: "omp default", isDefault: true),
    ]

    /// Display name for a selection, falling back to the slug.
    public static func displayName(for selection: ModelSelection, in status: ProviderStatus?) -> String {
        if let model = (status?.models ?? fallback(selection.provider)).first(where: { $0.slug == selection.model }) {
            return model.name
        }
        switch selection.provider {
        case .codex: return codexDisplayName(selection.model)
        case .omp: return selection.model == ModelSelection.ompDefaultModel ? "omp default" : selection.model
        case .claude: return selection.model
        }
    }
}
