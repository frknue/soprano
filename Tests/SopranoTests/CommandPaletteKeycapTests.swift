import AppKit
import Testing
@testable import Soprano

struct CommandPaletteKeycapTests {
    @Test func aPrefixBindingIsThePrefixCapThenItsKey() throws {
        let binding = try defaultBinding("open-in-soprano-git")

        #expect(MainWindowController.keycaps(for: binding, prefixKey: "a") == ["⌃A", "G"])
    }

    @Test func aPrefixBindingFollowsTheConfiguredPrefixKey() throws {
        let binding = try defaultBinding("previous-window")

        #expect(MainWindowController.keycaps(for: binding, prefixKey: "b") == ["⌃B", "P"])
    }

    @Test func aShiftedPrefixKeyCarriesShiftInItsCap() throws {
        let binding = try defaultBinding("new-session")

        #expect(MainWindowController.keycaps(for: binding, prefixKey: "a") == ["⌃A", "⇧C"])
    }

    @Test func aSymbolThatNeedsShiftToTypeShowsNoShift() throws {
        let binding = try defaultBinding("split-vertical")

        #expect(MainWindowController.keycaps(for: binding, prefixKey: "a") == ["⌃A", "|"])
    }

    @Test func aDirectChordIsOneCapWithModifiersInMacOrder() throws {
        #expect(MainWindowController.keycaps(for: try defaultBinding("new-terminal"), prefixKey: "a") == ["⌘D"])
        #expect(MainWindowController.keycaps(for: try defaultBinding("open-project"), prefixKey: "a") == ["⇧⌘P"])
        #expect(MainWindowController.keycaps(for: try defaultBinding("next-window-direct"), prefixKey: "a") == ["⌃⇧L"])
        #expect(MainWindowController.keycaps(for: try defaultBinding("previous-tab"), prefixKey: "a") == ["⌃⇧⇥"])
    }

    @Test func anOverriddenChordRendersLikeAStockOne() throws {
        let chord = try #require(KeyChord.parse("cmd+escape"))
        let binding = chord.applied(to: try defaultBinding("command-palette"))

        #expect(MainWindowController.keycaps(for: binding, prefixKey: "a") == ["⌘esc"])
    }

    @Test func aBindingWithoutAKeyHasNoCaps() {
        let binding = KeyBinding(
            id: "launch-custom",
            label: "Launch Custom",
            description: "Launch the custom agent",
            category: .agents,
            defaultKeys: "",
            mode: .direct,
            key: ""
        )

        #expect(MainWindowController.keycaps(for: binding, prefixKey: "a").isEmpty)
    }

    private func defaultBinding(_ id: String) throws -> KeyBinding {
        try #require(DefaultKeybindings.config.bindings.first { $0.id == id })
    }
}
