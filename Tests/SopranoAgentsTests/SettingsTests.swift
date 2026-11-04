import AppKit
import Testing
@testable import Soprano
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
          "agents": { "defaultModel": "anthropic/claude-sonnet-5-5", "defaultRuntimeMode": "approval-required" },
          "providers": { "ompPath": "~/.bun/bin/omp" },
          "textGeneration": { "model": "anthropic/claude-haiku-5-5", "titles": false },
          "worktrees": { "directory": "~/worktrees", "branchPrefix": "agent" },
          "chat": { "followUp": "queue", "width": "wide" },
          "notifications": { "enabled": false, "sound": false },
          "editor": { "app": "zed" },
          "keybindings": { "prefixKey": "B", "prefixTimeoutMs": 900, "bindings": { "palette.open": "cmd+shift+k", "x": ["j", "k"], "y": null } },
        }
        """)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var expected = AgentsSettings()
        expected.defaultModel = "anthropic/claude-sonnet-5-5"
        expected.defaultRuntimeMode = .approvalRequired
        expected.ompPath = home + "/.bun/bin/omp"
        expected.textGenerationModel = "anthropic/claude-haiku-5-5"
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
          "theme": "neon", // Soprano's key, unknown inside threads
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

    @Test func projectDirectoriesKeepExistingFoldersOnceAndWarnAboutTheRest() throws {
        let root = EngineHarness.temporaryDirectory().standardizedFileURL
        let work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try "x".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        let resolved = try SettingsResolver.resolve(text: """
        { "projects": { "directories": ["\(root.path)", "\(work.path)/", "\(root.path)/missing", "\(root.path)/file.txt", "relative"] } }
        """)

        #expect(resolved.settings.projectDirectories == [root.path, work.path])
        #expect(resolved.issues.count == 3)
        let notAList = try SettingsResolver.resolve(text: #"{ "projects": { "directories": "~/git" } }"#)
        #expect(notAList.settings.projectDirectories.isEmpty)
        #expect(notAList.issues.map(\.message) == ["projects.directories must be an array of folder paths."])
    }


    @Test func sopranosTemplateDocumentsEveryAgentsSettingAtItsDefault() throws {
        let template = ConfigFile.template(settings: .defaultSettings, keybindings: DefaultKeybindings.config)
        let resolved = try SettingsResolver.resolve(text: SettingsFile.agentsDocument(fromSopranoText: template))
        #expect(template.contains(#""threads": {"#))
        #expect(resolved.issues.isEmpty)
        #expect(resolved.settings == .defaults)
        #expect(resolved.keybindings == KeybindingSettings())
    }

    @Test func engineSettingsRunEverythingOnOmp() {
        let defaults = AgentsSettings.defaults.engineSettings
        #expect(defaults.defaultModel == ModelSelection(provider: .omp, model: ModelSelection.ompDefaultModel))
        #expect(defaults.defaultRuntimeMode == .fullAccess)
        #expect(defaults.textGenerationModel == ModelSelection(provider: .omp, model: ModelSelection.ompDefaultModel))
        #expect(defaults.branchPrefix == "soprano")
        #expect(defaults.generateTitles)
        #expect(defaults.ompPath == nil)

        var settings = AgentsSettings()
        settings.defaultModel = "anthropic/claude-opus-5-5"
        settings.textGenerationModel = "anthropic/claude-haiku-5-5"
        settings.ompPath = "/usr/local/bin/omp"
        settings.generateTitles = false
        let mapped = settings.engineSettings
        #expect(mapped.defaultModel == ModelSelection(provider: .omp, model: "anthropic/claude-opus-5-5"))
        #expect(mapped.textGenerationModel == ModelSelection(provider: .omp, model: "anthropic/claude-haiku-5-5"))
        #expect(mapped.ompPath == "/usr/local/bin/omp")
        #expect(!mapped.generateTitles)
    }


    @Test func agentsSettingsAreReadFromThreadsWithSopranosProjectFolders() throws {
        let folder = EngineHarness.temporaryDirectory().standardizedFileURL
        let document = try SettingsFile.agentsDocument(fromSopranoText: """
        // Soprano
        {
          "theme": "nord",
          "projectDirectories": ["\(folder.path)"],
          "threads": { "theme": "folio", "projects": { "directories": [] }, "chat": { "width": "wide" } }
        }
        """)
        let resolved = try SettingsResolver.resolve(text: document)

        #expect(resolved.settings.chatWidth == .wide)
        #expect(resolved.settings.projectDirectories == [folder.path])
        #expect(resolved.issues.isEmpty)
        #expect(try SettingsResolver.resolve(text: SettingsFile.agentsDocument(fromSopranoText: "{}")).settings == .defaults)
        #expect(throws: SettingsFile.NamespaceError()) {
            try SettingsFile.agentsDocument(fromSopranoText: #"{ "threads": true }"#)
        }
    }

    @Test func agentsPathsMapIntoSopranosDocument() {
        #expect(SettingsFile.documentPath(for: ["chat", "width"]) == ["threads", "chat", "width"])
        #expect(SettingsFile.documentPath(for: ["projects", "directories"]) == ["projectDirectories"])
        #expect(SettingsFile.documentPath(for: ["theme"]) == ["theme"])
    }

    @Test func theStandaloneAppsFileIsFoundWhereItUsedToLive() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(SettingsFile.legacyURL(environment: [:]).path == home + "/.config/soprano-agents/settings.json")
        #expect(SettingsFile.legacyURL(environment: ["XDG_CONFIG_HOME": "/tmp/xdg"]).path == "/tmp/xdg/soprano-agents/settings.json")
        #expect(SettingsFile.legacyURL(environment: ["SOPRANO_AGENTS_CONFIG": "/tmp/a.json", "XDG_CONFIG_HOME": "/tmp/xdg"]).path == "/tmp/a.json")
        #expect(SettingsFile.url() == ConfigFile.url)
    }

    @Test func theStandaloneAppsSettingsAreImportedOnceKeepingSopranosComments() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("soprano/settings.json")
        let legacyURL = directory.appendingPathComponent("soprano-agents/settings.json")
        let soprano = """
        // Soprano settings.
        {
          // Color theme.
          "theme": "nord",
          "projectDirectories": []
        }
        """
        let legacy = """
        // Soprano Agents settings.
        {
          "theme": "folio-ink",
          "projects": { "directories": ["~/git/private"] },
          "chat": { "width": "full" },
          "keybindings": { "bindings": { "palette.open": null } }
        }
        """
        try ConfigFile.write(soprano, to: url)
        try ConfigFile.write(legacy, to: legacyURL)
        let center = SettingsCenter(fileURL: url, registry: CommandRegistry())

        center.importLegacySettings(from: legacyURL)
        center.start(watching: false)

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasPrefix("// Soprano settings.\n{\n  // Color theme.\n  \"theme\": \"nord\""))
        #expect(center.configuredValue(at: ["theme"]) as? String == "nord")
        #expect(center.configuredValue(at: ["projects", "directories"]) as? [String] == ["~/git/private"])
        #expect(center.configuredValue(at: ["chat", "width"]) as? String == "full")
        #expect(center.configuredValue(at: ["projects"]) == nil)
        #expect((center.configuredValue(at: []) as? [String: Any])?["theme"] == nil)
        #expect(center.settings.chatWidth == .full)
        #expect(center.keybindingSettings.overrides["palette.open"] == .disabled)
        #expect(try String(contentsOf: legacyURL, encoding: .utf8) == legacy)

        // Presence of "threads" marks the import as done.
        try ConfigFile.write(text.replacingOccurrences(of: #""full""#, with: #""wide""#), to: url)
        #expect(try !SettingsFile.importLegacySettings(into: url, from: legacyURL))
        #expect(try String(contentsOf: url, encoding: .utf8).contains(#""wide""#))
    }

    @Test func importingIsSkippedWhenSopranoAlreadyHasThreadsOrTheOldFileIsMissing() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        try ConfigFile.write("{}", to: url)

        #expect(try SettingsFile.importing(legacyText: #"{ "chat": { "width": "full" } }"#, into: #"{ "threads": {} }"#) == nil)
        #expect(try !SettingsFile.importLegacySettings(into: url, from: directory.appendingPathComponent("missing.json")))
        #expect(try String(contentsOf: url, encoding: .utf8) == "{}")
    }

    @Test func projectFoldersMoveOnlyWhenSopranoHasNone() throws {
        let legacy = #"{ "projects": { "directories": ["~/git/work"] } }"#
        func folders(_ soprano: String) throws -> [String]? {
            let text = try #require(try SettingsFile.importing(legacyText: legacy, into: soprano))
            let root = try JSONSerialization.jsonObject(with: JSONCText.strictJSONData(from: text)) as? [String: Any]
            return root?["projectDirectories"] as? [String]
        }

        #expect(try folders("{}") == ["~/git/work"])
        #expect(try folders(#"{ "projectDirectories": [] }"#) == ["~/git/work"])
        #expect(try folders(#"{ "projectDirectories": ["~/git/private"] }"#) == ["~/git/private"])
    }

    @Test func startingWithoutSopranosFileUsesTheDefaultsAndCreatesNothing() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("nested/settings.json")
        let center = SettingsCenter(fileURL: url, registry: CommandRegistry())

        center.start(watching: false)

        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(center.settings == .defaults)
        #expect(center.issues.isEmpty)
    }

    @Test func aSyntaxErrorKeepsTheLastGoodSettings() {
        let center = SettingsCenter(fileURL: URL(fileURLWithPath: "/dev/null/settings.json"), registry: CommandRegistry())
        var notifications = 0
        let owner = NSObject()
        center.addObserver(owner) { notifications += 1 }

        center.apply(text: #"{ "threads": { "chat": { "width": "wide" } } }"#)
        center.apply(text: "{\n  \"threads\": { \"chat\": { \"width\": \"full\" ")

        #expect(center.settings.chatWidth == .wide)
        #expect(center.issues.count == 1)
        #expect(center.issues.first?.severity == .error)
        #expect(center.issues.first?.line == 2)

        center.apply(text: #"{ "threads": { "chat": { "width": "full" } } }"#)
        #expect(center.settings.chatWidth == .full)
        #expect(center.issues.isEmpty)
        #expect(notifications == 3)
    }

    @Test func badValuesInsideThreadsWarnWithoutALine() {
        let center = SettingsCenter(fileURL: URL(fileURLWithPath: "/dev/null/settings.json"), registry: CommandRegistry())

        center.apply(text: "{\n\n  \"threads\": { \"chat\": { \"width\": 3 } }\n}")

        #expect(center.issues.map(\.message) == [#"chat.width must be "normal", "wide" or "full"."#])
        #expect(center.issues.first?.line == nil)
    }

    @Test func liveEditsToTheFileReachObservers() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        try #"{ "threads": { "chat": { "followUp": "steer" } } }"#.write(to: url, atomically: true, encoding: .utf8)
        let center = SettingsCenter(fileURL: url, registry: CommandRegistry())
        let owner = NSObject()
        var notified = false
        center.addObserver(owner) { notified = true }
        center.start()
        defer { center.stop() }
        // The watcher arms on its own queue; give it a moment like a real edit would.
        try await Task.sleep(for: .milliseconds(200))

        try #"{ "threads": { "chat": { "followUp": "queue" } } }"#.write(to: url, atomically: true, encoding: .utf8)
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
        try ConfigFile.template(settings: .defaultSettings, keybindings: DefaultKeybindings.config)
            .write(to: url, atomically: true, encoding: .utf8)
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
        #expect(text.contains(#""width": "wide""#))
        #expect(center.settings.chatWidth == .wide)
        #expect(center.keybindingSettings.overrides["palette.open"] == .chords(["prefix+g"]))
        #expect(notifications == 2)
        #expect(try SettingsResolver.resolve(text: SettingsFile.agentsDocument(fromSopranoText: text)).settings.chatWidth == .wide)
    }

    @Test func theThemeAndProjectFoldersAreWrittenToSopranosOwnKeys() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        try #"{ "theme": "folio" }"#.write(to: url, atomically: true, encoding: .utf8)
        let center = SettingsCenter(fileURL: url, registry: CommandRegistry())
        center.start(watching: false)

        #expect(center.write("nord", at: ["theme"]))
        #expect(center.write([directory.path], at: ["projects", "directories"]))

        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(root?["theme"] as? String == "nord")
        #expect(root?["projectDirectories"] as? [String] == [directory.path])
        #expect(root?["threads"] == nil)
        #expect(center.settings.projectDirectories == [directory.standardizedFileURL.path])
        #expect(center.issues.isEmpty)
    }

    @Test func removingAKeyRestoresItsDefault() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        try #"{ "threads": { "providers": { "ompPath": "/opt/tools/omp" }, "keybindings": { "bindings": { "palette.open": null } } } }"#
            .write(to: url, atomically: true, encoding: .utf8)
        let center = SettingsCenter(fileURL: url, registry: CommandRegistry())
        center.start(watching: false)

        #expect(center.remove(at: ["providers", "ompPath"]))
        #expect(center.remove(at: ["keybindings", "bindings", "palette.open"]))

        #expect(center.settings.ompPath == nil)
        #expect(center.keybindingSettings.overrides.isEmpty)
        #expect(center.configuredValue(at: ["providers", "ompPath"]) == nil)
    }

    @Test func aWriteEditsTheFileOnDiskEvenBeforeAHandEditWasReloaded() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        try #"{ "threads": { "chat": { "followUp": "steer" } } }"#.write(to: url, atomically: true, encoding: .utf8)
        let center = SettingsCenter(fileURL: url, registry: CommandRegistry())
        center.start(watching: false)

        // A hand edit the (debounced) watcher has not delivered yet.
        try #"{ "threads": { "chat": { "followUp": "queue" } } }"#.write(to: url, atomically: true, encoding: .utf8)
        #expect(center.write("full", at: ["chat", "width"]))

        #expect(center.settings.followUp == .queue)
        #expect(center.settings.chatWidth == .full)
    }

    @Test func aWriteToAFileWithASyntaxErrorLeavesTheFileAloneAndReportsIt() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        let broken = #"{ "threads": { "chat": { "width": "wide" "#
        try broken.write(to: url, atomically: true, encoding: .utf8)
        let center = SettingsCenter(fileURL: url, registry: CommandRegistry())
        center.start(watching: false)

        #expect(!center.write("queue", at: ["chat", "followUp"]))

        #expect(try String(contentsOf: url, encoding: .utf8) == broken)
        #expect(center.settings.followUp == .steer)
        #expect(center.issues.first?.severity == .error)
        #expect(center.issues.first?.message.hasPrefix("Could not update") == true)
    }

    @Test func aForcedAppearancePicksFolioPaperOrInkButNeverReplacesAnotherTheme() throws {
        let center = ThemeCenter(sopranoSettingsURL: try temporaryDirectory().appendingPathComponent("missing.json"))
        center.forcedAppearance = .light
        center.apply(setting: "nord", watch: false)
        #expect(center.theme.id == "nord")
        center.forcedAppearance = .dark
        #expect(center.theme.id == "nord")

        center.apply(setting: "folio", watch: false)
        #expect(center.theme.id == "folio-ink")
        center.forcedAppearance = .light
        #expect(center.theme.id == "folio-paper")
        // Following Soprano without Soprano's settings file follows Folio too.
        center.apply(setting: ThemeCenter.followSoprano, watch: false)
        #expect(center.theme.id == "folio-paper")
    }

    @Test func followingSopranoResolvesItsThemeAndAppearanceWithFolioFallbacks() {
        func resolve(_ text: String?, _ system: AppTheme.Appearance) -> String {
            ThemeCenter.resolveThemeID(setting: ThemeCenter.followSoprano, sopranoSettingsText: text, systemAppearance: system)
        }
        #expect(resolve(#"{ "theme": "folio", "appearance": "dark" }"#, .light) == "folio-ink")
        #expect(resolve(#"{ "theme": "folio" }"#, .light) == "folio-paper")
        for text in [nil, "{ broken", #"{ "theme": "vaporwave" }"#] {
            #expect(resolve(text, .dark) == "folio-ink")
        }
    }

    @Test func theSettingsScreenOffersSopranosThemes() {
        let values = SettingsController.themeOptions().map(\.value)
        #expect(values == AppTheme.options.map(\.id))
        #expect(values.first == AppTheme.folioId)
    }
}
