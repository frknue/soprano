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

    @Test func theMatchedTitleRangeIgnoresCaseAndSurroundingWhitespace() throws {
        let label = "Open in Soprano Git"

        let range = try #require(CommandPaletteSearch.matchRange(in: label, query: "  OPEN "))

        #expect(label[range] == "Open")
    }

    @Test func aTitleWithoutTheQueryHasNoMatchedRange() {
        #expect(CommandPaletteSearch.matchRange(in: "omp web", query: "open") == nil)
        #expect(CommandPaletteSearch.matchRange(in: "omp web", query: " ") == nil)
    }

    @Test func aCommandWithoutAShortcutHasNoKeycaps() {
        #expect(item(id: "plain", label: "Plain").shortcut.isEmpty)
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
            searchText: searchText,
            action: {}
        )
    }
}
