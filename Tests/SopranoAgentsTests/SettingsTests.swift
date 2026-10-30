import AppKit
import Testing
@testable import SopranoAgents
@testable import SopranoAgentsCore

@MainActor
struct SettingsTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sa-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func everyKeyResolvesFromAJSONCDocument() throws {
        let resolved = try SettingsResolver.resolve(text: """
        // comment
        {
          "theme": "t3-dark",
          "agents": { "defaultProvider": "claude", "defaultModel": "claude-sonnet-5", "defaultRuntimeMode": "approval-required" },
          "providers": { "codexPath": "/opt/homebrew/bin/codex", "claudePath": "~/bin/claude" },
          "textGeneration": { "provider": "claude", "model": "claude-haiku-5-5", "titles": false },
          "worktrees": { "directory": "~/worktrees", "branchPrefix": "agent" },
          "chat": { "followUp": "queue", "width": "wide" },
          "notifications": { "enabled": false, "sound": false },
          "editor": { "app": "zed" },
          "keybindings": { "prefixKey": "B", "prefixTimeoutMs": 900, "bindings": { "palette.open": "cmd+shift+k", "x": ["j", "k"], "y": null } },
        }
        """)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var expected = AppSettings()
        expected.theme = "t3-dark"
        expected.defaultProvider = .claude
        expected.defaultModel = "claude-sonnet-5"
        expected.defaultRuntimeMode = .approvalRequired
        expected.codexPath = "/opt/homebrew/bin/codex"
        expected.claudePath = home + "/bin/claude"
        expected.textGenerationProvider = .claude
        expected.textGenerationModel = "claude-haiku-5-5"
        expected.generateTitles = false
        expected.worktreesDirectory = home + "/worktrees"
        expected.branchPrefix = "agent"
        expected.followUp = .queue
        expected.chatWidth = .wide
        expected.notificationsEnabled = false
        expected.notificationSound = false
        expected.editorApp = "zed"
        #expect(resolved.issues.isEmpty)
        #expect(resolved.settings == expected)
        #expect(resolved.keybindings == KeybindingSettings(
            prefixKey: "b",
            prefixTimeoutMs: 900,
            overrides: ["palette.open": .chords(["cmd+shift+k"]), "x": .chords(["j", "k"]), "y": .disabled]
        ))
    }

    @Test func badValuesKeepTheirDefaultsWithWarnings() throws {
        let resolved = try SettingsResolver.resolve(text: """
        {
          "theme": "neon",
          "agents": { "defaultProvider": "gemini", "defaultRuntimeMode": "yolo" },
          "chat": { "followUp": "later", "width": 3 },
          "worktrees": { "directory": "relative/path", "branchPrefix": "has space" },
          "notifications": { "enabled": "yes" },
          "keybindings": { "prefixKey": "ab", "prefixTimeoutMs": 10, "bindings": { "palette.open": 4 } },
          "colour": true
        }
        """)
        #expect(resolved.settings == .defaults)
        #expect(resolved.keybindings.prefixKey == "a")
        #expect(resolved.keybindings.prefixTimeoutMs == 300)
        #expect(resolved.keybindings.overrides.isEmpty)
        #expect(resolved.issues.count == 12)
        #expect(resolved.issues.allSatisfy { $0.severity == .warning })
    }

    @Test func theTemplateIsValidAndResolvesToTheDefaults() throws {
        let resolved = try SettingsResolver.resolve(text: SettingsFile.template)
        #expect(resolved.issues.isEmpty)
        #expect(resolved.settings == .defaults)
        #expect(resolved.keybindings == KeybindingSettings())
    }

    @Test func engineSettingsCarryTheDefaultsAndTheProviderFallbacks() {
        let defaults = AppSettings.defaults.engineSettings
        #expect(defaults.defaultModel == ModelSelection(provider: .codex, model: ProviderKind.codex.defaultModel))
        #expect(defaults.defaultRuntimeMode == .fullAccess)
        #expect(defaults.textGenerationModel == ModelSelection(provider: .codex, model: "gpt-6-luna", options: ["effort": "low"]))
        #expect(defaults.branchPrefix == "soprano")
        #expect(defaults.generateTitles)
        #expect(defaults.codexPath == nil && defaults.claudePath == nil)

        var settings = AppSettings()
        settings.defaultProvider = .claude
        settings.textGenerationProvider = .claude
        settings.textGenerationModel = "claude-sonnet-5"
        settings.claudePath = "/usr/local/bin/claude"
        settings.generateTitles = false
        let mapped = settings.engineSettings
        #expect(mapped.defaultModel == ModelSelection(provider: .claude, model: "claude-opus-5-5"))
        // Claude has no effort option for text generation.
        #expect(mapped.textGenerationModel == ModelSelection(provider: .claude, model: "claude-sonnet-5"))
        #expect(mapped.claudePath == "/usr/local/bin/claude")
        #expect(!mapped.generateTitles)
    }

    @Test func theFileIsCreatedFromTheTemplateOnFirstStart() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("nested/settings.json")
        let center = SettingsCenter(fileURL: url, registry: CommandRegistry())

        center.start(watching: false)

        #expect(try String(contentsOf: url, encoding: .utf8) == SettingsFile.template)
        #expect(center.settings == .defaults)
        #expect(center.issues.isEmpty)
    }

    @Test func aSyntaxErrorKeepsTheLastGoodSettings() {
        let center = SettingsCenter(fileURL: URL(fileURLWithPath: "/dev/null/settings.json"), registry: CommandRegistry())
        var notifications = 0
        let owner = NSObject()
        center.addObserver(owner) { notifications += 1 }

        center.apply(text: #"{ "chat": { "width": "wide" } }"#)
        center.apply(text: #"{ "chat": { "width": "full" "#)

        #expect(center.settings.chatWidth == .wide)
        #expect(center.issues.count == 1)
        #expect(center.issues.first?.severity == .error)
        #expect(center.issues.first?.line == 1)

        center.apply(text: #"{ "chat": { "width": "full" } }"#)
        #expect(center.settings.chatWidth == .full)
        #expect(center.issues.isEmpty)
        #expect(notifications == 3)
    }

    @Test func liveEditsToTheFileReachObservers() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        try #"{ "chat": { "followUp": "steer" } }"#.write(to: url, atomically: true, encoding: .utf8)
        let center = SettingsCenter(fileURL: url, registry: CommandRegistry())
        let owner = NSObject()
        var notified = false
        center.addObserver(owner) { notified = true }
        center.start()
        defer { center.stop() }
        // The watcher arms on its own queue; give it a moment like a real edit would.
        try await Task.sleep(for: .milliseconds(200))

        try #"{ "chat": { "followUp": "queue" } }"#.write(to: url, atomically: true, encoding: .utf8)
        for _ in 0..<60 where center.settings.followUp != .queue {
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(center.settings.followUp == .queue)
        #expect(notified)
    }

    @Test func writingAKeyKeepsTheFilesCommentsAndAppliesTheValue() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        try SettingsFile.template.write(to: url, atomically: true, encoding: .utf8)
        let center = SettingsCenter(fileURL: url, registry: CommandRegistry())
        center.start(watching: false)
        var notifications = 0
        let owner = NSObject()
        center.addObserver(owner) { notifications += 1 }

        #expect(center.write("wide", at: ["chat", "width"]))
        #expect(center.write("prefix+g", at: ["keybindings", "bindings", "palette.open"]))

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains(#"// Chat lane: "normal" (736 pt), "wide", or "full"."#))
        #expect(text.contains(#"// "diff.toggle": null"#))
        #expect(center.settings.chatWidth == .wide)
        #expect(center.keybindingSettings.overrides["palette.open"] == .chords(["prefix+g"]))
        #expect(notifications == 2)
        #expect(try SettingsResolver.resolve(text: text).settings.chatWidth == .wide)
    }

    @Test func removingAKeyRestoresItsDefault() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        try #"{ "providers": { "codexPath": "/opt/tools/codex" }, "keybindings": { "bindings": { "palette.open": null } } }"#
            .write(to: url, atomically: true, encoding: .utf8)
        let center = SettingsCenter(fileURL: url, registry: CommandRegistry())
        center.start(watching: false)

        #expect(center.remove(at: ["providers", "codexPath"]))
        #expect(center.remove(at: ["keybindings", "bindings", "palette.open"]))

        #expect(center.settings.codexPath == nil)
        #expect(center.keybindingSettings.overrides.isEmpty)
        #expect(center.configuredValue(at: ["providers", "codexPath"]) == nil)
    }

    @Test func aWriteEditsTheFileOnDiskEvenBeforeAHandEditWasReloaded() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        try #"{ "chat": { "followUp": "steer" } }"#.write(to: url, atomically: true, encoding: .utf8)
        let center = SettingsCenter(fileURL: url, registry: CommandRegistry())
        center.start(watching: false)

        // A hand edit the (debounced) watcher has not delivered yet.
        try #"{ "chat": { "followUp": "queue" } }"#.write(to: url, atomically: true, encoding: .utf8)
        #expect(center.write("full", at: ["chat", "width"]))

        #expect(center.settings.followUp == .queue)
        #expect(center.settings.chatWidth == .full)
    }

    @Test func aWriteToAFileWithASyntaxErrorLeavesTheFileAloneAndReportsIt() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        let broken = #"{ "chat": { "width": "wide" "#
        try broken.write(to: url, atomically: true, encoding: .utf8)
        let center = SettingsCenter(fileURL: url, registry: CommandRegistry())
        center.start(watching: false)

        #expect(!center.write("queue", at: ["chat", "followUp"]))

        #expect(try String(contentsOf: url, encoding: .utf8) == broken)
        #expect(center.settings.followUp == .steer)
        #expect(center.issues.first?.severity == .error)
        #expect(center.issues.first?.message.hasPrefix("Could not update") == true)
    }

    @Test func theThemeSettingAcceptsT3SopranoAndSopranoThemeIdsAndWarnsOnOthers() throws {
        for id in ["t3", "t3-light", "t3-dark", "soprano", "folio"] + AppTheme.options.map(\.id) {
            let resolved = try SettingsResolver.resolve(text: #"{ "theme": "\#(id)" }"#)
            #expect(resolved.issues.isEmpty, "\(id)")
            #expect(resolved.settings.theme == id)
        }
        let unknown = try SettingsResolver.resolve(text: #"{ "theme": "mission-control" }"#)
        #expect(unknown.settings.theme == "t3")
        #expect(unknown.issues.count == 1)
        #expect(unknown.issues.first?.message.contains("t3, t3-light, t3-dark, soprano") == true)
    }

    @Test func followingSopranoResolvesItsThemeAndAppearanceWithFolioFallbacks() {
        func resolve(_ text: String?, _ system: AppTheme.Appearance) -> String {
            ThemeCenter.resolveThemeID(setting: "soprano", sopranoSettingsText: text, systemAppearance: system)
        }
        #expect(resolve(#"{ "theme": "folio", "appearance": "dark" }"#, .light) == "folio-ink")
        #expect(resolve(#"{ "theme": "folio" }"#, .light) == "folio-paper")
        for text in [nil, "{ broken", #"{ "theme": "vaporwave" }"#] {
            #expect(resolve(text, .dark) == "folio-ink")
        }
    }

    @Test func theSettingsScreenOffersEveryAcceptedThemeId() throws {
        let values = SettingsController.themeOptions().map(\.value)
        #expect(values.prefix(4) == ["t3", "t3-light", "t3-dark", "soprano"])
        for value in values {
            #expect(try SettingsResolver.resolve(text: #"{ "theme": "\#(value)" }"#).issues.isEmpty, "\(value)")
        }
        #expect(Set(values) == Set(PaletteCenter.t3ThemeIDs + ["soprano"] + AppTheme.options.map(\.id)))
    }
}
