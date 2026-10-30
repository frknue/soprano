import AppKit
import Testing
@testable import SopranoAgents
@testable import SopranoAgentsCore

struct SlashCommandFilterTests {
    private let commands = [
        ProviderCommand(name: "compact", kind: .command, description: "Summarize earlier messages", insertText: "/compact "),
        ProviderCommand(name: "model", kind: .command, description: "Switch the model", insertText: "/model "),
        ProviderCommand(name: "review", kind: .command, description: "Review the changes", insertText: "/review "),
        ProviderCommand(name: "skill:pr", kind: .skill, description: "Write PR descriptions", insertText: "/skill:pr "),
        ProviderCommand(name: "skill:refactor", kind: .skill, description: "Restructure code", insertText: "/skill:refactor "),
    ]

    @Test func namesStartingWithTheQueryComeFirstThenNameOrDescriptionMatches() {
        let names = SlashCommandFilter.matching(commands, query: "RE").map(\.name)
        #expect(names == ["review", "skill:refactor"])
        #expect(SlashCommandFilter.matching(commands, query: "pr").map(\.name) == ["skill:pr"])
        #expect(SlashCommandFilter.matching(commands, query: "earlier").map(\.name) == ["compact"])
        #expect(SlashCommandFilter.matching(commands, query: "").count == commands.count)
        #expect(SlashCommandFilter.matching(commands, query: "zzz").isEmpty)
    }

    @Test func aNameContainingTheQueryOutranksADescriptionThatMentionsIt() {
        let list = [
            ProviderCommand(name: "alpha", kind: .command, description: "Pick a model", insertText: "/alpha "),
            ProviderCommand(name: "remodel", kind: .command, insertText: "/remodel "),
            ProviderCommand(name: "model", kind: .command, insertText: "/model "),
        ]
        #expect(SlashCommandFilter.matching(list, query: "model").map(\.name) == ["model", "remodel", "alpha"])
    }

    @Test func prefixMatchesKeepTheProviderOrder() {
        let names = SlashCommandFilter.matching(commands, query: "skill:").map(\.name)
        #expect(names == ["skill:pr", "skill:refactor"])
    }

    @Test func candidatesFollowTheSigilAndAddTheAppCompactRowOnlyWhenMissing() {
        let codex = [ProviderCommand(name: "pdf", kind: .skill, description: "Read PDFs", insertText: "$pdf ")]
        #expect(SlashCommandFilter.candidates(codex, sigil: "$", includeCompact: true).map(\.name) == ["pdf"])
        #expect(SlashCommandFilter.candidates(codex, sigil: "/", includeCompact: true) == [SlashCommandFilter.compactCommand])
        #expect(SlashCommandFilter.candidates(codex, sigil: "/", includeCompact: false).isEmpty)
        #expect(SlashCommandFilter.candidates(commands, sigil: "/", includeCompact: true) == commands)
    }

    @Test func theEmptyRowNamesTheProviderOrTheUnmatchedQuery() {
        #expect(SlashCommandFilter.emptyText(provider: .claude, sigil: "/", hasCandidates: false, query: "") == "No commands from Claude Code yet — they load once the session starts.")
        #expect(SlashCommandFilter.emptyText(provider: .codex, sigil: "$", hasCandidates: false, query: "") == "No skills from Codex yet — they load once the session starts.")
        #expect(SlashCommandFilter.emptyText(provider: .omp, sigil: "/", hasCandidates: true, query: "zz") == "No commands match “/zz”")
    }
}
