import AppKit
import Testing
@testable import Soprano
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

    @Test func candidatesAreTheSlashCommandsPlusTheAppCompactRowOnlyWhenMissing() {
        let withoutCompact = Array(commands.dropFirst())
        #expect(SlashCommandFilter.candidates(withoutCompact, includeCompact: true) == withoutCompact + [SlashCommandFilter.compactCommand])
        #expect(SlashCommandFilter.candidates(withoutCompact, includeCompact: false) == withoutCompact)
        #expect(SlashCommandFilter.candidates(commands, includeCompact: true) == commands)
        let bare = [ProviderCommand(name: "pdf", kind: .skill, insertText: "pdf ")]
        #expect(SlashCommandFilter.candidates(bare, includeCompact: false).isEmpty)
    }

    @Test func threadsListTheAppsBtwRowOnceEvenWhenTheProviderHasOne() {
        let providerBtw = ProviderCommand(name: "btw", kind: .command, insertText: "/btw ")
        let list = SlashCommandFilter.candidates(commands + [providerBtw], includeCompact: false, includeSideQuestion: true)
        #expect(list == commands + [SlashCommandFilter.sideQuestionCommand])
        #expect(!SlashCommandFilter.candidates(commands, includeCompact: false, includeSideQuestion: false).contains(SlashCommandFilter.sideQuestionCommand))
    }

    @Test func btwAsksTheRestAsASideQuestionAndAloneOpensThePanel() {
        #expect(SideQuestionCommand.parse("/btw why a lock?") == .ask("why a lock?"))
        #expect(SideQuestionCommand.parse("  /btw\n  two\nlines  ") == .ask("two\nlines"))
        #expect(SideQuestionCommand.parse("/btw") == .open)
        #expect(SideQuestionCommand.parse("/btw   ") == .open)
        #expect(SideQuestionCommand.parse("/btwx why") == nil)
        #expect(SideQuestionCommand.parse("so /btw why") == nil)
        #expect(SideQuestionCommand.parse("/compact") == nil)
    }

    @Test func theEmptyRowSaysCommandsAreLoadingOrNamesTheUnmatchedQuery() {
        #expect(SlashCommandFilter.emptyText(hasCandidates: false, query: "") == "No commands from omp yet — they load once the session starts.")
        #expect(SlashCommandFilter.emptyText(hasCandidates: true, query: "zz") == "No commands match “/zz”")
    }
}
