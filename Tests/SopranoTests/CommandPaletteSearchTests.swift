import AppKit
import Testing
@testable import Soprano

struct CommandPaletteSearchTests {
    @Test func windowTitleMatchesRankAboveMatchesInsideSplitPanes() {
        let paneMatch = item(
            id: "backend",
            label: "Backend",
            searchText: "Soprano terminal"
        )
        let windowMatch = item(
            id: "soprano",
            label: "Soprano",
            searchText: "Backend terminal"
        )

        let results = CommandPaletteSearch.filter(
            [paneMatch, windowMatch],
            query: "soprano"
        )

        #expect(results.map(\.id) == ["soprano", "backend"])
    }

    @Test func hiddenPaneMetadataCanFindItsContainingWindow() {
        let item = item(
            id: "agents",
            label: "Agents",
            searchText: "Claude /Users/example/projects/soprano"
        )

        let results = CommandPaletteSearch.filter([item], query: "soprano")

        #expect(results.map(\.id) == ["agents"])
    }

    @Test func anEmptyQueryPreservesWindowOrder() {
        let commands = [
            item(id: "second", label: "Second"),
            item(id: "first", label: "First"),
        ]

        let results = CommandPaletteSearch.filter(commands, query: "  ")

        #expect(results.map(\.id) == ["second", "first"])
    }

    private func item(
        id: String,
        label: String,
        description: String = "",
        searchText: String? = nil
    ) -> CommandItem {
        CommandItem(
            id: id,
            icon: "macwindow",
            label: label,
            description: description,
            shortcut: nil,
            searchText: searchText,
            action: {}
        )
    }
}
