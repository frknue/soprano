import AppKit
import Testing
@testable import Soprano
@testable import SopranoAgentsCore

struct ModelPickerFilterTests {
    private let catalog = [
        ProviderModel(slug: "anthropic/claude-opus-5-5", name: "Claude Opus 5.5 · anthropic"),
        ProviderModel(slug: "openrouter/anthropic/claude-opus-5-5", name: "Claude Opus 5.5 · openrouter"),
        ProviderModel(slug: "github-copilot/gpt-6-luna", name: "GPT-6 Luna · github-copilot"),
    ]

    @Test func everyWordOfTheQueryMustAppearInTheNameOrSlugInAnyOrder() {
        let slugs = ModelPickerContent.matching(catalog, query: "  OPUS   openrouter ").map(\.slug)
        #expect(slugs == ["openrouter/anthropic/claude-opus-5-5"])
        #expect(ModelPickerContent.matching(catalog, query: "copilot luna").map(\.slug) == ["github-copilot/gpt-6-luna"])
        #expect(ModelPickerContent.matching(catalog, query: "opus luna").isEmpty)
        #expect(ModelPickerContent.matching(catalog, query: " ").count == catalog.count)
    }

    @Test func aLongCatalogShowsTheFirstMatchesAndKeepsTheCurrentModelVisiblePastTheCut() {
        let models = (0..<200).map { ProviderModel(slug: "openrouter/m\($0)", name: "Model \($0)") }

        let current = ModelPickerContent.window(models, limit: 80) { $0.slug == "openrouter/m150" }
        #expect(current.hidden == 120)
        #expect(current.shown.count == 80)
        #expect(current.shown.prefix(79).map(\.slug) == models.prefix(79).map(\.slug))
        #expect(current.shown.last?.slug == "openrouter/m150")

        let inside = ModelPickerContent.window(models, limit: 80) { $0.slug == "openrouter/m3" }
        #expect(inside.shown.map(\.slug) == models.prefix(80).map(\.slug))

        let short = ModelPickerContent.window(Array(models.prefix(80)), limit: 80) { _ in false }
        #expect(short.hidden == 0 && short.shown.count == 80)
    }
}
