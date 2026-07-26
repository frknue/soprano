import AppKit
import Testing
@testable import Soprano

struct SopranoConfigTests {
    private func resolve(_ json: String) -> ResolvedConfig {
        let config = try! JSONCText.decode(SopranoConfig.self, from: json)
        return config.resolved()
    }

    @Test func anEmptyDocumentLeavesEveryBuiltInDefaultInPlace() {
        let resolved = resolve("{}")

        #expect(resolved.settings == AppSettings.defaultSettings)
        #expect(resolved.keybindings == DefaultKeybindings.config)
        #expect(resolved.agents == DefaultAgents.all)
        #expect(resolved.issues.isEmpty)
    }

    @Test func theBuiltInBindingsContainNoChordCollisions() {
        // The conflict detector must not cry wolf on a stock configuration.
        let resolved = resolve("{}")
        #expect(resolved.issues.isEmpty)
    }

    @Test func settingOneKeyLeavesTheOthersAtTheirDefaults() {
        let resolved = resolve("""
        { "theme": "catppuccin-mocha" }
        """)

        #expect(resolved.settings.themeId == "catppuccin-mocha")
        #expect(resolved.settings.restoreLastSession == AppSettings.defaultSettings.restoreLastSession)
        #expect(resolved.settings.projectDirectories.isEmpty)
        #expect(resolved.issues.isEmpty)
    }

    @Test func anUnknownThemeIsReportedAndTheCurrentThemeSurvives() {
        let resolved = resolve("""
        { "theme": "solarized-light" }
        """)

        #expect(resolved.settings.themeId == AppSettings.defaultSettings.themeId)
        #expect(resolved.issues.count == 1)
        #expect(resolved.issues.first?.severity == .warning)
        #expect(resolved.issues.first?.message.contains("solarized-light") == true)
    }

    @Test func projectDirectoriesExpandTildesAndRejectPathsThatAreNotDirectories() {
        let missing = "/tmp/soprano-tests-does-not-exist-\(UUID().uuidString)"
        let resolved = resolve("""
        { "projectDirectories": ["~", "\(missing)"] }
        """)

        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        #expect(resolved.settings.projectDirectories == [home])
        #expect(resolved.issues.contains { $0.message.contains(missing) })
    }

    // MARK: - Keybindings

    @Test func aChordOverrideRetargetsTheBindingAndMarksItCustomized() {
        let resolved = resolve("""
        { "keybindings": { "bindings": { "new-browser": "cmd+shift+b" } } }
        """)

        let binding = resolved.keybindings.bindings.first { $0.id == "new-browser" }
        #expect(binding?.key == "b")
        #expect(binding?.meta == true)
        #expect(binding?.shift == true)
        #expect(binding?.defaultKeys == "⇧⌘B")
        #expect(resolved.customizedBindingIds == ["new-browser"])
        #expect(resolved.issues.isEmpty)
    }

    @Test func aBindingSetToNullIsRemovedFromTheActiveSetAndListedAsDisabled() {
        let resolved = resolve("""
        { "keybindings": { "bindings": { "zoom-reset": null } } }
        """)

        #expect(!resolved.keybindings.bindings.contains { $0.id == "zoom-reset" })
        #expect(resolved.disabledBindingIds == ["zoom-reset"])
        #expect(resolved.issues.isEmpty)
    }

    @Test func aShiftedSymbolBindsWithoutHavingToSpellOutShift() {
        // "|" cannot be typed without Shift, so both spellings must land on the
        // chord the key actually produces — otherwise the binding is written,
        // accepted, and then never fires.
        let terse = resolve("""
        { "keybindings": { "bindings": { "split-vertical": "prefix+|" } } }
        """)
        let explicit = resolve("""
        { "keybindings": { "bindings": { "split-vertical": "prefix+shift+|" } } }
        """)

        let binding = terse.keybindings.bindings.first { $0.id == "split-vertical" }
        #expect(binding?.key == "|")
        #expect(binding?.shift == true)
        #expect(binding == explicit.keybindings.bindings.first { $0.id == "split-vertical" })
        #expect(binding == DefaultKeybindings.config.bindings.first { $0.id == "split-vertical" })
    }

    @Test func anUnknownActionIdIsReportedWithoutDisturbingTheOtherBindings() {
        let resolved = resolve("""
        { "keybindings": { "bindings": { "summon-a-pony": "cmd+9" } } }
        """)

        #expect(resolved.keybindings.bindings.count == DefaultKeybindings.config.bindings.count)
        #expect(resolved.issues.contains { $0.message.contains("summon-a-pony") })
    }

    @Test func anUnparseableChordIsReportedAndTheDefaultChordStays() {
        let resolved = resolve("""
        { "keybindings": { "bindings": { "new-terminal": "alt+t" } } }
        """)

        let binding = resolved.keybindings.bindings.first { $0.id == "new-terminal" }
        #expect(binding == DefaultKeybindings.config.bindings.first { $0.id == "new-terminal" })
        #expect(resolved.customizedBindingIds.isEmpty)
        #expect(resolved.issues.contains { $0.message.contains("alt+t") })
    }

    @Test func outOfRangeNumbersAreClampedAndReported() {
        let resolved = resolve("""
        { "keybindings": { "prefixTimeoutMs": 99999, "resizeTickPercent": 0 } }
        """)

        #expect(resolved.keybindings.prefixTimeoutMs == 5000)
        #expect(resolved.keybindings.resizeTickPercent == 1)
        #expect(resolved.issues.count == 2)
        #expect(resolved.issues.allSatisfy { $0.severity == .warning })
    }

    @Test func aMultiCharacterPrefixKeyIsRejected() {
        let resolved = resolve("""
        { "keybindings": { "prefixKey": "esc" } }
        """)

        #expect(resolved.keybindings.prefixKey == DefaultKeybindings.config.prefixKey)
        #expect(resolved.issues.contains { $0.message.contains("prefixKey") })
    }

    @Test func twoBindingsOnTheSameChordAreReportedAsAConflict() {
        // ⌘T already belongs to new-terminal.
        let resolved = resolve("""
        { "keybindings": { "bindings": { "new-browser": "cmd+t" } } }
        """)

        #expect(resolved.issues.contains {
            $0.message.contains("new-browser") && $0.message.contains("new-terminal")
        })
    }

    // MARK: - Agents

    @Test func aNewAgentJoinsTheCatalogWithDefaultsFilledIn() {
        let resolved = resolve("""
        { "agents": [ { "id": "aider", "command": "aider", "args": ["--no-auto-commits"] } ] }
        """)

        let agent = resolved.agents.first { $0.id == "aider" }
        #expect(agent?.name == "Aider")
        #expect(agent?.command == "aider")
        #expect(agent?.args == ["--no-auto-commits"])
        #expect(agent?.color.hasPrefix("#") == true)
        #expect(resolved.configuredAgentIds == ["aider"])
        #expect(resolved.agents.count == DefaultAgents.all.count + 1)
        #expect(resolved.issues.isEmpty)
    }

    /// The end of the chain that matters most: a agent someone typed into
    /// settings.json has to reach the terminal as the command they asked for.
    @Test func aConfiguredAgentReachesTheTerminalAsTheCommandItDeclared() {
        let resolved = resolve("""
        {
          "agents": [
            {
              "id": "aider",
              "command": "aider",
              "args": ["--no-auto-commits", "a file.py"],
              "env": { "AIDER_DARK_MODE": "1" },
              "cwd": "~"
            }
          ]
        }
        """)

        let profile = resolved.agents.first { $0.id == "aider" }!
        let config = TerminalConfig.forAgent(profile, paneId: "pane-1", tabId: "tab-1")

        // Each component is shell-quoted independently, so a path with a space
        // survives and a command string cannot smuggle in extra shell syntax —
        // multi-step launches are what `launchScript` is for.
        #expect(config.command == "'aider' '--no-auto-commits' 'a file.py'")
        #expect(config.env["AIDER_DARK_MODE"] == "1")
        #expect(config.env["SOPRANO_AGENT_PROFILE"] == "aider")
        #expect(config.env["SOPRANO_AGENT_NAME"] == "Aider")
        #expect(config.workingDirectory == FileManager.default.homeDirectoryForCurrentUser.path)
    }

    @Test func aConfiguredLaunchScriptReplacesTheCommand() {
        let resolved = resolve("""
        { "agents": [ { "id": "aider", "command": "aider", "launchScript": "nvm use 22 && aider" } ] }
        """)

        let profile = resolved.agents.first { $0.id == "aider" }!
        let config = TerminalConfig.forAgent(profile, paneId: "pane-1", tabId: "tab-1")

        #expect(config.launchScript == "nvm use 22 && aider")
        #expect(config.command == nil)
    }

    @Test func aNewAgentWithoutACommandIsRejected() {
        let resolved = resolve("""
        { "agents": [ { "id": "ghost", "name": "Ghost" } ] }
        """)

        #expect(!resolved.agents.contains { $0.id == "ghost" })
        #expect(resolved.issues.contains { $0.message.contains("ghost") })
    }

    @Test func reusingABuiltInIdPatchesOnlyTheFieldsItNames() {
        let resolved = resolve("""
        { "agents": [ { "id": "codex", "args": ["--model", "o3"] } ] }
        """)

        let codex = resolved.agents.first { $0.id == "codex" }
        #expect(codex?.args == ["--model", "o3"])
        #expect(codex?.name == DefaultAgents.codex.name)
        #expect(codex?.command == DefaultAgents.codex.command)
        #expect(codex?.color == DefaultAgents.codex.color)
        #expect(codex?.patterns == DefaultAgents.codex.patterns)
        #expect(resolved.agents.count == DefaultAgents.all.count)
    }

    @Test func aLaunchKeySynthesizesAShortcutForANewAgent() {
        let resolved = resolve("""
        { "agents": [ { "id": "aider", "command": "aider", "launchKey": "cmd+4" } ] }
        """)

        let binding = resolved.keybindings.bindings.first { $0.id == "launch-aider" }
        #expect(binding?.key == "4")
        #expect(binding?.meta == true)
        #expect(binding?.category == .agents)
        #expect(binding?.defaultKeys == "⌘4")
    }

    @Test func aLaunchKeyRetargetsABuiltInAgentShortcut() {
        let resolved = resolve("""
        { "agents": [ { "id": "codex", "launchKey": "cmd+7" } ] }
        """)

        let launchers = resolved.keybindings.bindings.filter { $0.id == "launch-codex" }
        #expect(launchers.count == 1)
        #expect(launchers.first?.key == "7")
    }

    @Test func anExplicitBindingWinsOverAnAgentLaunchKeyForTheSameAction() {
        let resolved = resolve("""
        {
          "keybindings": { "bindings": { "launch-aider": "cmd+8" } },
          "agents": [ { "id": "aider", "command": "aider", "launchKey": "cmd+4" } ]
        }
        """)

        let binding = resolved.keybindings.bindings.first { $0.id == "launch-aider" }
        #expect(binding?.key == "8")
    }

    @Test func aLauncherCanBeBoundFromTheBindingsTableAloneWithoutALaunchKey() {
        let resolved = resolve("""
        {
          "keybindings": { "bindings": { "launch-aider": "cmd+8" } },
          "agents": [ { "id": "aider", "command": "aider" } ]
        }
        """)

        let binding = resolved.keybindings.bindings.first { $0.id == "launch-aider" }
        #expect(binding?.key == "8")
        #expect(binding?.meta == true)
        #expect(!resolved.issues.contains { $0.message.contains("unknown action") })
    }

    @Test func aBadLaunchKeyIsReportedAgainstTheKeyTheUserActuallyWrote() {
        let resolved = resolve("""
        { "agents": [ { "id": "aider", "command": "aider", "launchKey": "alt+z" } ] }
        """)

        #expect(resolved.issues.contains { $0.message.contains("agents[aider].launchKey") })
        #expect(!resolved.issues.contains { $0.message.contains("keybindings.bindings") })
    }

    @Test func aChordShadowedByZoomInsPlusAliasIsReported() {
        let resolved = resolve("""
        { "keybindings": { "bindings": { "new-browser": "cmd+plus" } } }
        """)

        #expect(resolved.issues.contains {
            $0.message.contains("new-browser") && $0.message.contains("zoom-in")
        })
    }

    @Test func aPrefixKeyThatStealsADirectCtrlShortcutIsReported() {
        // Ctrl+H is "Focus Left"; making "h" the prefix silently consumes it.
        let resolved = resolve("""
        { "keybindings": { "prefixKey": "h" } }
        """)

        #expect(resolved.issues.contains {
            $0.message.contains("nav-left") && $0.message.contains("prefixKey")
        })
    }

    @Test func aLaunchShortcutForAnAgentThatDoesNotExistIsReported() {
        let resolved = resolve("""
        { "keybindings": { "bindings": { "launch-nothing": "cmd+9" } } }
        """)

        #expect(!resolved.keybindings.bindings.contains { $0.id == "launch-nothing" })
        #expect(resolved.issues.contains { $0.message.contains("launch-nothing") })
    }

    @Test func aDuplicateAgentIdIsReportedAndTheFirstEntryWins() {
        let resolved = resolve("""
        {
          "agents": [
            { "id": "aider", "command": "aider" },
            { "id": "aider", "command": "somethingelse" }
          ]
        }
        """)

        #expect(resolved.agents.first { $0.id == "aider" }?.command == "aider")
        #expect(resolved.issues.contains { $0.message.contains("duplicate") })
    }
}
