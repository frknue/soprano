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

    @Test func tmuxWindowCyclingUsesPrefixPAndN() throws {
        let previousWindow = try #require(binding("previous-window"))
        let nextWindow = try #require(binding("next-window"))
        let previousWindowDirect = try #require(binding("previous-window-direct"))
        let nextWindowDirect = try #require(binding("next-window-direct"))

        #expect(previousWindow.mode == .prefix)
        #expect(previousWindow.key == "p")
        #expect(previousWindow.shift != true)
        #expect(previousWindow.defaultKeys == "Prefix → P")
        #expect(nextWindow.mode == .prefix)
        #expect(nextWindow.key == "n")
        #expect(nextWindow.shift != true)
        #expect(nextWindow.defaultKeys == "Prefix → N")

        #expect(previousWindowDirect.mode == .direct)
        #expect(previousWindowDirect.key == "h")
        #expect(previousWindowDirect.ctrl == true)
        #expect(previousWindowDirect.shift == true)
        #expect(nextWindowDirect.mode == .direct)
        #expect(nextWindowDirect.key == "l")
        #expect(nextWindowDirect.ctrl == true)
        #expect(nextWindowDirect.shift == true)
    }

    @Test func paneTabCyclingMovesToShiftedPrefixPAndN() throws {
        let previousTab = try #require(binding("prev-pane-tab"))
        let nextTab = try #require(binding("next-pane-tab"))

        #expect(previousTab.mode == .prefix)
        #expect(previousTab.key == "p")
        #expect(previousTab.shift == true)
        #expect(previousTab.defaultKeys == "Prefix → Shift+P")
        #expect(nextTab.mode == .prefix)
        #expect(nextTab.key == "n")
        #expect(nextTab.shift == true)
        #expect(nextTab.defaultKeys == "Prefix → Shift+N")
    }

    @Test func legacyWindowAndTabDefaultsMigrateToTmuxBindings() throws {
        var savedConfig = DefaultKeybindings.config
        savedConfig.bindings.removeAll {
            $0.id == "previous-window-direct" || $0.id == "next-window-direct"
        }
        savedConfig.bindings = savedConfig.bindings.map { current in
            switch current.id {
            case "previous-window":
                return legacyBinding(
                    basedOn: current,
                    display: "Ctrl+Shift+H",
                    mode: .direct,
                    key: "h",
                    ctrl: true,
                    shift: true
                )
            case "next-window":
                return legacyBinding(
                    basedOn: current,
                    display: "Ctrl+Shift+L",
                    mode: .direct,
                    key: "l",
                    ctrl: true,
                    shift: true
                )
            case "prev-pane-tab":
                return legacyBinding(
                    basedOn: current,
                    display: "Prefix → P",
                    mode: .prefix,
                    key: "p"
                )
            case "next-pane-tab":
                return legacyBinding(
                    basedOn: current,
                    display: "Prefix → N",
                    mode: .prefix,
                    key: "n"
                )
            default:
                return current
            }
        }

        let merged = DefaultKeybindings.mergedConfig(with: savedConfig)
        let byId = Dictionary(uniqueKeysWithValues: merged.bindings.map { ($0.id, $0) })

        #expect(byId["previous-window"]?.mode == .prefix)
        #expect(byId["previous-window"]?.key == "p")
        #expect(byId["next-window"]?.mode == .prefix)
        #expect(byId["next-window"]?.key == "n")
        #expect(byId["prev-pane-tab"]?.shift == true)
        #expect(byId["next-pane-tab"]?.shift == true)
        #expect(byId["previous-window-direct"] != nil)
        #expect(byId["next-window-direct"] != nil)
    }

    @Test func customizedWindowCyclingBindingIsPreserved() throws {
        var savedConfig = DefaultKeybindings.config
        savedConfig.bindings = savedConfig.bindings.map { current in
            guard current.id == "previous-window" else { return current }
            return legacyBinding(
                basedOn: current,
                display: "Ctrl+Shift+B",
                mode: .direct,
                key: "b",
                ctrl: true,
                shift: true
            )
        }

        let merged = DefaultKeybindings.mergedConfig(with: savedConfig)
        let previousWindow = try #require(
            merged.bindings.first { $0.id == "previous-window" }
        )

        #expect(previousWindow.mode == .direct)
        #expect(previousWindow.key == "b")
        #expect(previousWindow.ctrl == true)
        #expect(previousWindow.shift == true)
    }

    @Test func defaultBindingsDoNotContainShortcutCollisions() {
        let chords = DefaultKeybindings.config.bindings.map { binding in
            [
                binding.mode.rawValue,
                binding.key,
                binding.ctrl == true ? "ctrl" : "",
                binding.meta == true ? "meta" : "",
                binding.shift == true ? "shift" : "",
            ].joined(separator: ":")
        }

        #expect(Set(chords).count == chords.count)
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

    @Test func newWindowCurrentDirectoryUsesTmuxPrefixC() throws {
        let newWindow = try #require(binding("new-window-current-directory"))

        #expect(newWindow.mode == .prefix)
        #expect(newWindow.key == "c")
        #expect(newWindow.shift != true)
        #expect(newWindow.defaultKeys == "Prefix → C")
    }

    @Test func paneDepthUsesMnemonicPrefixBindings() throws {
        let goIn = try #require(binding("pane-depth-in"))
        let goOut = try #require(binding("pane-depth-out"))

        #expect(goIn.mode == .prefix)
        #expect(goIn.key == "i")
        #expect(goIn.shift != true)
        #expect(goIn.defaultKeys == "Prefix → I")
        #expect(goOut.mode == .prefix)
        #expect(goOut.key == "o")
        #expect(goOut.shift != true)
        #expect(goOut.defaultKeys == "Prefix → O")
    }

    @Test func prefixXClosesADepthLayerBeforeKillingThePane() throws {
        let killBinding = try #require(binding("kill-pane"))

        #expect(killBinding.mode == .prefix)
        #expect(killBinding.key == "x")
        #expect(killBinding.label == "Close Layer / Kill Pane")
        #expect(killBinding.description.contains("depth layer"))
        #expect(killBinding.description.contains("Z0"))
    }

    @Test func savedConfigurationsGainPaneDepthBindings() {
        var savedConfig = DefaultKeybindings.config
        savedConfig.bindings.removeAll {
            $0.id == "pane-depth-in" || $0.id == "pane-depth-out"
        }

        let mergedConfig = DefaultKeybindings.mergedConfig(with: savedConfig)

        #expect(mergedConfig.bindings.contains { $0.id == "pane-depth-in" })
        #expect(mergedConfig.bindings.contains { $0.id == "pane-depth-out" })
    }

    @Test func windowManagementUsesShiftedCommandShortcuts() throws {
        let renameWindow = try #require(binding("rename-window"))
        let closeWindow = try #require(binding("close-window"))

        #expect(renameWindow.mode == .direct)
        #expect(renameWindow.key == "r")
        #expect(renameWindow.meta == true)
        #expect(renameWindow.shift == true)
        #expect(renameWindow.defaultKeys == "⇧⌘R")

        #expect(closeWindow.mode == .direct)
        #expect(closeWindow.key == "w")
        #expect(closeWindow.meta == true)
        #expect(closeWindow.shift == true)
        #expect(closeWindow.defaultKeys == "⇧⌘W")
    }

    @Test func savedConfigurationsGainWindowManagementBindings() {
        var savedConfig = DefaultKeybindings.config
        savedConfig.bindings.removeAll {
            $0.id == "rename-window" || $0.id == "close-window"
        }

        let mergedConfig = DefaultKeybindings.mergedConfig(with: savedConfig)

        #expect(mergedConfig.bindings.contains { $0.id == "rename-window" })
        #expect(mergedConfig.bindings.contains { $0.id == "close-window" })
    }

    @Test func savedConfigurationsGainTheNewWindowCurrentDirectoryBinding() {
        var savedConfig = DefaultKeybindings.config
        savedConfig.bindings.removeAll { $0.id == "new-window-current-directory" }

        let mergedConfig = DefaultKeybindings.mergedConfig(with: savedConfig)

        #expect(
            mergedConfig.bindings.contains {
                $0.id == "new-window-current-directory"
            }
        )
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

    private func legacyBinding(
        basedOn binding: KeyBinding,
        display: String,
        mode: KeyBindingMode,
        key: String,
        ctrl: Bool? = nil,
        shift: Bool? = nil
    ) -> KeyBinding {
        KeyBinding(
            id: binding.id,
            label: binding.label,
            description: binding.description,
            category: binding.category,
            defaultKeys: display,
            mode: mode,
            key: key,
            ctrl: ctrl,
            shift: shift
        )
    }
}
