import AppKit
import Testing
@testable import Soprano
@testable import SopranoAgentsCore

@MainActor
struct SlashCommandMenuContentTests {
    private let commands = [
        ProviderCommand(name: "compact", kind: .command, insertText: "/compact "),
        ProviderCommand(name: "model", kind: .command, insertText: "/model "),
        ProviderCommand(name: "review", kind: .command, insertText: "/review "),
    ]

    private func menu(picked: @escaping (String) -> Void) -> SlashCommandMenuContent {
        SlashCommandMenuContent(width: 400) { picked($0.name) }
    }

    @Test func reListingTheSameQueryKeepsTheHighlightedCommandEvenWhenItMoved() {
        var picked: [String] = []
        let content = menu { picked.append($0) }
        content.show(commands, emptyText: "")
        content.moveHighlight(by: 2)

        // A thread update re-lists the open menu with the same query.
        content.show(commands, emptyText: "", keepingHighlight: true)
        #expect(content.chooseHighlighted())
        // The list changed under it: the highlight follows the command, not the row.
        content.show([commands[2], commands[0]], emptyText: "", keepingHighlight: true)
        #expect(content.chooseHighlighted())
        #expect(picked == ["review", "review"])
    }

    @Test func aNewQueryOrAVanishedCommandHighlightsTheFirstRowAgain() {
        var picked: [String] = []
        let content = menu { picked.append($0) }
        content.show(commands, emptyText: "")
        content.moveHighlight(by: 2)
        content.show(commands, emptyText: "")
        #expect(content.chooseHighlighted())

        content.moveHighlight(by: 1)
        content.show([commands[0], commands[2]], emptyText: "", keepingHighlight: true)
        #expect(content.chooseHighlighted())
        #expect(picked == ["compact", "compact"])
    }
}
