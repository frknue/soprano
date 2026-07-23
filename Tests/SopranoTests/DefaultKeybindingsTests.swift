import Testing
@testable import Soprano

struct DefaultKeybindingsTests {
    @Test func splitDefaultsUseDashAndPipe() throws {
        let horizontal = try #require(binding("split-horizontal"))
        let vertical = try #require(binding("split-vertical"))

        #expect(horizontal.defaultKeys == "Prefix → -")
        #expect(horizontal.key == "-")
        #expect(horizontal.shift != true)

        #expect(vertical.defaultKeys == "Prefix → |")
        #expect(vertical.key == "|")
        #expect(vertical.shift == true)
    }

    @Test func savedLegacySplitDefaultsMigrateToCurrentDefaults() throws {
        var savedConfig = DefaultKeybindings.config
        savedConfig.bindings = savedConfig.bindings.map { binding in
            switch binding.id {
            case "split-horizontal":
                legacySplitBinding(id: binding.id, key: "s", display: "Prefix → S")
            case "split-vertical":
                legacySplitBinding(id: binding.id, key: "v", display: "Prefix → V")
            default:
                binding
            }
        }

        let mergedConfig = DefaultKeybindings.mergedConfig(with: savedConfig)
        let horizontal = try #require(
            mergedConfig.bindings.first { $0.id == "split-horizontal" }
        )
        let vertical = try #require(
            mergedConfig.bindings.first { $0.id == "split-vertical" }
        )

        #expect(horizontal.key == "-")
        #expect(vertical.key == "|")
        #expect(vertical.shift == true)
    }

    @Test func customizedSplitBindingsArePreserved() throws {
        var savedConfig = DefaultKeybindings.config
        savedConfig.bindings = savedConfig.bindings.map { binding in
            guard binding.id == "split-horizontal" else { return binding }
            return legacySplitBinding(
                id: binding.id,
                key: "d",
                display: "Prefix → D"
            )
        }

        let mergedConfig = DefaultKeybindings.mergedConfig(with: savedConfig)
        let horizontal = try #require(
            mergedConfig.bindings.first { $0.id == "split-horizontal" }
        )

        #expect(horizontal.key == "d")
        #expect(horizontal.defaultKeys == "Prefix → D")
    }

    private func binding(_ id: String) -> KeyBinding? {
        DefaultKeybindings.config.bindings.first { $0.id == id }
    }

    private func legacySplitBinding(
        id: String,
        key: String,
        display: String
    ) -> KeyBinding {
        KeyBinding(
            id: id,
            label: id == "split-horizontal" ? "Split Horizontal" : "Split Vertical",
            description: "Split the active pane",
            category: .layout,
            defaultKeys: display,
            mode: .prefix,
            key: key
        )
    }
}
