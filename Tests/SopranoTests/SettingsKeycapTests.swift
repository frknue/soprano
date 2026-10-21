import AppKit
import Testing
@testable import Soprano

struct SettingsKeycapTests {
    @Test func settingsShowsTheSameCapsAsThePalette() throws {
        for binding in DefaultKeybindings.config.bindings where binding.id != "zoom-in" {
            let palette = MainWindowController.keycaps(for: binding, prefixKey: "a")
            let settings = SettingsKeycaps.alternatives(for: binding, prefixKey: "a")
            #expect(settings == (palette.isEmpty ? [] : [palette]), "\(binding.id)")
        }
    }

    @Test func namedKeysUseTheirGlyphsAndLowercaseEsc() throws {
        #expect(SettingsKeycaps.alternatives(for: try defaultBinding("next-tab"), prefixKey: "a") == [["⌃⇥"]])

        let chord = try #require(KeyChord.parse("cmd+escape"))
        let overridden = chord.applied(to: try defaultBinding("command-palette"))
        #expect(SettingsKeycaps.alternatives(for: overridden, prefixKey: "a") == [["⌘esc"]])
    }

    @Test func aPrefixBindingFollowsTheConfiguredPrefix() throws {
        #expect(SettingsKeycaps.alternatives(for: try defaultBinding("previous-window"), prefixKey: "b") == [["⌃B", "P"]])
    }

    @Test func listedAlternativesKeepTheirSlashSplit() throws {
        let zoomIn = try defaultBinding("zoom-in")
        #expect(SettingsKeycaps.alternatives(for: zoomIn, prefixKey: "a") == [["⌘+"], ["⌘="]])

        let chord = try #require(KeyChord.parse("cmd+shift+i"))
        #expect(SettingsKeycaps.alternatives(for: chord.applied(to: zoomIn), prefixKey: "a") == [["⇧⌘I"]])
    }

    private func defaultBinding(_ id: String) throws -> KeyBinding {
        try #require(DefaultKeybindings.config.bindings.first { $0.id == id })
    }
}
