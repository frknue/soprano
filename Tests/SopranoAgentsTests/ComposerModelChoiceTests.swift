import AppKit
import Testing
@testable import SopranoAgents
@testable import SopranoAgentsCore

struct ComposerModelChoiceTests {
    private func model(_ slug: String, _ provider: ProviderKind) throws -> ProviderModel {
        try #require(ProviderCatalog.fallback(provider).first { $0.slug == slug })
    }

    @Test func pickingAnotherModelKeepsOnlyTheOptionValuesItSupports() throws {
        let current = ModelSelection(provider: .codex, model: "gpt-6.1-sol", options: ["effort": "ultra", "fastMode": "true"])

        let luna = ModelChoice.selecting(try model("gpt-6-luna", .codex), of: .codex, from: current)
        #expect(luna == ModelSelection(provider: .codex, model: "gpt-6-luna", options: ["fastMode": "true"]))

        let high = ModelSelection(provider: .claude, model: "claude-opus-5-5", options: ["effort": "high", "fastMode": "true"])
        let sonnet = ModelChoice.selecting(try model("claude-sonnet-5-5", .claude), of: .claude, from: high)
        #expect(sonnet.options == ["effort": "high"])
    }

    @Test func unknownOptionsAndInvalidValuesAreDropped() throws {
        let sol = try model("gpt-6.1-sol", .codex)
        let options = ModelChoice.supportedOptions(["effort": "turbo", "fastMode": "yes", "serviceTier": "flex", "verbosity": "low"], for: sol)
        #expect(options.isEmpty)
    }

    @Test func switchingProvidersLandsOnTheDefaultModelWithSupportedOptions() {
        let current = ModelSelection(provider: .codex, model: "gpt-6-astra", options: ["effort": "max", "fastMode": "true"])
        let claude = ModelChoice.switching(to: .claude, status: nil, from: current)
        #expect(claude == ModelSelection(provider: .claude, model: "claude-opus-5-5", options: ["effort": "max", "fastMode": "true"]))

        let ultra = ModelSelection(provider: .codex, model: "gpt-6.1-sol", options: ["effort": "ultra"])
        #expect(ModelChoice.switching(to: .claude, status: nil, from: ultra).options.isEmpty)
        #expect(ModelChoice.switching(to: .codex, status: nil, from: ultra) == ultra)
    }

    @Test func aProbedCatalogReplacesTheFallbackOnceItHasModels() {
        let live = ProviderModel(slug: "gpt-7", name: "GPT-7", isDefault: true)
        let probed = ProviderStatus(kind: .codex, health: .ready, models: [live])
        #expect(ModelChoice.models(for: .codex, status: probed) == [live])
        #expect(ModelChoice.defaultModel(for: .codex, status: probed) == live)
        let unprobed = ProviderStatus(kind: .codex)
        #expect(ModelChoice.models(for: .codex, status: unprobed) == ProviderCatalog.fallback(.codex))
    }

    @Test func theModelChipTitleNamesTheModelAndTheEffortInEffect() {
        let explicit = ModelSelection(provider: .codex, model: "gpt-6.1-sol", options: ["effort": "high"])
        #expect(ModelChoice.chipTitle(explicit, status: nil) == "GPT-6.1 Sol · High")

        let implicit = ModelSelection(provider: .claude, model: "claude-sonnet-5-5")
        #expect(ModelChoice.chipTitle(implicit, status: nil) == "Claude Sonnet 5.5 · High")

        let fast = ModelSelection(provider: .codex, model: "gpt-6-luna", options: ["effort": "xhigh", "fastMode": "true"])
        #expect(ModelChoice.chipTitle(fast, status: nil) == "GPT-6 Luna · Extra High · Fast")
    }

    @Test func anEffortTheModelDoesNotOfferFallsBackToItsDefault() throws {
        let luna = try model("gpt-6-luna", .codex)
        let selection = ModelSelection(provider: .codex, model: "gpt-6-luna", options: ["effort": "ultra"])
        #expect(ModelChoice.effectiveEffort(selection, model: luna) == "medium")
    }

    @Test func anUnknownModelKeepsItsSlugNameAndExplicitEffort() {
        let selection = ModelSelection(provider: .codex, model: "gpt-7-nova", options: ["effort": "high"])
        #expect(ModelChoice.chipTitle(selection, status: nil) == "GPT-7 Nova · High")
    }
}
