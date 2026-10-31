import Foundation

/// Built-in model catalog: what the app offers before omp's first probe replaces it with omp's
/// live catalog (`get_available_models`).
public enum ProviderCatalog {
    public static func fallback(_ kind: ProviderKind) -> [ProviderModel] {
        switch kind {
        case .omp: ompModels
        }
    }

    /// Labels for omp's thinking levels.
    public static func effortLabel(_ id: String) -> String {
        switch id {
        case "minimal": "Minimal"
        case "low": "Low"
        case "medium": "Medium"
        case "high": "High"
        case "xhigh": "Extra High"
        case "max": "Max"
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
        case .omp: return selection.model == ModelSelection.ompDefaultModel ? "omp default" : selection.model
        }
    }
}
