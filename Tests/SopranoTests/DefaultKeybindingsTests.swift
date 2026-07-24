import Testing
@testable import Soprano

struct DefaultKeybindingsTests {
    @Test func numberedWindowBindingsRemainControlNumber() throws {
        for number in 1...9 {
            let window = try #require(binding("select-window-\(number)"))
            #expect(window.key == "\(number)")
            #expect(window.ctrl == true)
            #expect(window.shift != true)
            #expect(window.defaultKeys == "Ctrl+\(number)")
        }
    }

    @Test func temporaryShiftedWindowBindingsMigrateBackToControlNumber() throws {
        var savedConfig = DefaultKeybindings.config
        savedConfig.bindings = savedConfig.bindings.map { binding in
            guard binding.id.hasPrefix("select-window-") else { return binding }
            let number = String(binding.id.suffix(1))
            return KeyBinding(
                id: binding.id,
                label: binding.label,
                description: binding.description,
                category: binding.category,
                defaultKeys: "Ctrl+Shift+\(number)",
                mode: .direct,
                key: number,
                ctrl: true,
                shift: true
            )
        }

        let mergedConfig = DefaultKeybindings.mergedConfig(with: savedConfig)

        for number in 1...9 {
            let window = try #require(
                mergedConfig.bindings.first { $0.id == "select-window-\(number)" }
            )
            #expect(window.ctrl == true)
            #expect(window.shift != true)
            #expect(window.defaultKeys == "Ctrl+\(number)")
        }
    }

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

    @Test func symbolicSplitBindingsFollowDividerOrientation() throws {
        let horizontal = try #require(binding("split-horizontal"))
        let vertical = try #require(binding("split-vertical"))

        // SplitDirection describes pane arrangement: stacked panes produce a
        // horizontal divider, while side-by-side panes produce a vertical one.
        #expect(KeybindingManager.splitDirection(for: horizontal.id) == .vertical)
        #expect(KeybindingManager.splitDirection(for: vertical.id) == .horizontal)
    }

    @Test func copyModeSupportsBothTmuxBracketShortcuts() throws {
        let leftBracket = try #require(binding("copy-mode"))
        let rightBracket = try #require(binding("copy-mode-right-bracket"))

        #expect(leftBracket.mode == .prefix)
        #expect(leftBracket.key == "[")
        #expect(rightBracket.mode == .prefix)
        #expect(rightBracket.key == "]")
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
