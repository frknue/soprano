import AppKit
import Testing
@testable import Soprano

@MainActor
struct ConfigStoreTests {
    /// A store pointed at a throwaway file, so nothing here can touch the real
    /// `~/.config/soprano/settings.json`.
    private func makeStore() -> (store: ConfigStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soprano-config-tests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("settings.json")
        return (ConfigStore(fileURL: url), directory)
    }

    private func cleanUp(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ text: String, to store: ConfigStore) {
        try! ConfigFile.write(text, to: store.fileURL)
    }

    @Test func startingWithNoFileWritesADocumentedTemplateThatParsesCleanly() {
        let (store, directory) = makeStore()
        defer { cleanUp(directory) }

        store.start(
            watching: false,
            seedSettings: .defaultSettings,
            seedKeybindings: DefaultKeybindings.config
        )

        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
        #expect(store.text.contains("// Soprano settings."))
        #expect(store.issues.isEmpty)
        #expect(store.settings == AppSettings.defaultSettings)
        #expect(store.keybindings == DefaultKeybindings.config)
    }

    @Test func theSeededTemplateCarriesForwardSettingsMadeBeforeTheFileExisted() {
        let (store, directory) = makeStore()
        defer { cleanUp(directory) }

        var previous = AppSettings.defaultSettings
        previous.themeId = "catppuccin-mocha"
        previous.restoreLastSession = false
        var previousKeys = DefaultKeybindings.config
        let index = previousKeys.bindings.firstIndex { $0.id == "new-browser" }!
        previousKeys.bindings[index] = KeyChord.parse("cmd+shift+b")!
            .applied(to: previousKeys.bindings[index])
        previousKeys.prefixKey = "b"

        store.start(watching: false, seedSettings: previous, seedKeybindings: previousKeys)

        #expect(store.settings.themeId == "catppuccin-mocha")
        #expect(store.settings.restoreLastSession == false)
        #expect(store.keybindings.prefixKey == "b")
        #expect(store.keybindings.bindings.first { $0.id == "new-browser" }?.shift == true)
        #expect(store.resolved.customizedBindingIds.contains("new-browser"))
    }

    @Test func writingOneKeyLeavesEveryCommentAndUnrelatedKeyUntouched() {
        let (store, directory) = makeStore()
        defer { cleanUp(directory) }

        write("""
        // My Soprano config
        {
          // I like the orange one
          "theme": "gruvbox-dark",
          "restoreLastSession": false
        }
        """, to: store)
        store.start(watching: false, seedSettings: .defaultSettings, seedKeybindings: DefaultKeybindings.config)

        #expect(store.write("catppuccin-mocha", at: ["theme"]))

        let text = try! String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(text.contains("// My Soprano config"))
        #expect(text.contains("// I like the orange one"))
        #expect(text.contains("\"theme\": \"catppuccin-mocha\""))
        #expect(text.contains("\"restoreLastSession\": false"))
        #expect(store.settings.themeId == "catppuccin-mocha")
        #expect(store.settings.restoreLastSession == false)
    }

    /// A trailing block comment that wraps onto the next line looks like plain
    /// whitespace once comments are blanked, so a naive scan finds the newline
    /// *inside* it and splices the new key into the comment body — writing a
    /// setting that is commented out, with no error anywhere.
    @Test func aKeyInsertedAfterAMultiLineTrailingCommentLandsOutsideThatComment() {
        let (store, directory) = makeStore()
        defer { cleanUp(directory) }

        write("""
        {
          "theme": "gruvbox-dark",
          "keybindings": {
            "prefixKey": "a" /* the tmux-style prefix; press this,
                                then the action key */
          }
        }
        """, to: store)
        store.start(watching: false, seedSettings: .defaultSettings, seedKeybindings: DefaultKeybindings.config)

        #expect(store.write(2500, at: ["keybindings", "prefixTimeoutMs"]))

        #expect(store.keybindings.prefixTimeoutMs == 2500)
        let text = try! String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(text.contains("then the action key */"))
        #expect(try! JSONCText.decode(SopranoConfig.self, from: text).keybindings?.prefixTimeoutMs == 2500)
    }

    /// The mirror of the insertion case: removing an entry whose trailing block
    /// comment wraps onto the next line must not cut the comment in half and
    /// leave its tail as bare text, which would break the whole file.
    @Test func removingAKeyWithAMultiLineTrailingCommentLeavesTheFileParseable() {
        let (store, directory) = makeStore()
        defer { cleanUp(directory) }

        write("""
        {
          "restoreLastSession": false,
          "theme": "catppuccin-mocha" /* the purple one; I keep going
                                         back and forth on this */
        }
        """, to: store)
        store.start(watching: false, seedSettings: .defaultSettings, seedKeybindings: DefaultKeybindings.config)

        #expect(store.remove(at: ["theme"]))

        let text = try! String(contentsOf: store.fileURL, encoding: .utf8)
        let reparsed = try! JSONCText.decode(SopranoConfig.self, from: text)
        #expect(reparsed.theme == nil)
        #expect(reparsed.restoreLastSession == false)
        #expect(store.issues.isEmpty)
    }

    @Test func writingANestedKeyCreatesTheObjectItLivesIn() {
        let (store, directory) = makeStore()
        defer { cleanUp(directory) }

        write("{}", to: store)
        store.start(watching: false, seedSettings: .defaultSettings, seedKeybindings: DefaultKeybindings.config)

        #expect(store.write(2500, at: ["keybindings", "prefixTimeoutMs"]))

        #expect(store.keybindings.prefixTimeoutMs == 2500)
        #expect(try! JSONCText.decode(SopranoConfig.self, from: store.text).keybindings?.prefixTimeoutMs == 2500)
    }

    @Test func aSyntaxErrorKeepsTheLastGoodValuesRunningAndReportsTheLine() {
        let (store, directory) = makeStore()
        defer { cleanUp(directory) }

        write("""
        {
          "theme": "catppuccin-mocha"
        }
        """, to: store)
        store.start(watching: false, seedSettings: .defaultSettings, seedKeybindings: DefaultKeybindings.config)
        #expect(store.settings.themeId == "catppuccin-mocha")

        write("""
        {
          "theme": "catppuccin-mocha",
          "restoreLastSession":
        }
        """, to: store)
        store.reloadFromDisk()

        // The app keeps working on the values it already had.
        #expect(store.settings.themeId == "catppuccin-mocha")
        #expect(store.issues.contains { $0.severity == .error })
        #expect(store.issues.first { $0.severity == .error }?.line != nil)
    }

    /// Reporting a problem must not be cumulative: three bad saves in a row are
    /// still one problem, and the banner should say so once.
    @Test func repeatedProblemsDoNotPileUpInTheIssueList() {
        let (store, directory) = makeStore()
        defer { cleanUp(directory) }

        write("""
        { "theme": "catppuccin-mocha" }
        """, to: store)
        store.start(watching: false, seedSettings: .defaultSettings, seedKeybindings: DefaultKeybindings.config)

        for attempt in 1...3 {
            write("{ \"theme\": \"catppuccin-mocha\", \(attempt)", to: store)
            store.reloadFromDisk()
            #expect(store.issues.filter { $0.severity == .error }.count == 1)
        }

        // And the error clears once the file parses again.
        write("""
        { "theme": "gruvbox-dark" }
        """, to: store)
        store.reloadFromDisk()
        #expect(store.issues.isEmpty)
        #expect(store.settings.themeId == "gruvbox-dark")
    }

    @Test func aWarningFromTheLastGoodConfigSurvivesAlongsideASyntaxError() {
        let (store, directory) = makeStore()
        defer { cleanUp(directory) }

        write("""
        { "theme": "not-a-theme" }
        """, to: store)
        store.start(watching: false, seedSettings: .defaultSettings, seedKeybindings: DefaultKeybindings.config)
        #expect(store.issues.count == 1)

        write("{ \"theme\": ", to: store)
        store.reloadFromDisk()

        // One of each: the file cannot be read, and the config still in force
        // has its own problem.
        #expect(store.issues.filter { $0.severity == .error }.count == 1)
        #expect(store.issues.filter { $0.severity == .warning }.count == 1)
    }

    @Test func anEditMadeOutsideTheAppIsPickedUpAndAnnouncedOnce() {
        let (store, directory) = makeStore()
        defer { cleanUp(directory) }

        store.start(watching: false, seedSettings: .defaultSettings, seedKeybindings: DefaultKeybindings.config)

        var notifications = 0
        store.addObserver(id: "test") { notifications += 1 }

        write("""
        { "theme": "catppuccin-mocha", "keybindings": { "prefixKey": "x" } }
        """, to: store)
        store.reloadFromDisk()

        #expect(notifications == 1)
        #expect(store.settings.themeId == "catppuccin-mocha")
        #expect(store.keybindings.prefixKey == "x")

        // A reload with no change on disk must not churn the whole app.
        store.reloadFromDisk()
        #expect(notifications == 1)
    }

    @Test func aStoreWriteDoesNotReloadItsOwnFileAgain() {
        let (store, directory) = makeStore()
        defer { cleanUp(directory) }

        write("{}", to: store)
        store.start(watching: false, seedSettings: .defaultSettings, seedKeybindings: DefaultKeybindings.config)

        var notifications = 0
        store.addObserver(id: "test") { notifications += 1 }

        #expect(store.write("catppuccin-mocha", at: ["theme"]))
        #expect(notifications == 1)

        // This is what the file watcher delivers a moment after our own save.
        store.reloadFromDisk()
        #expect(notifications == 1)
    }

    /// The whole "hand edits apply immediately" promise rests on the watcher
    /// surviving how editors actually save: write a temp file, rename it over
    /// the target. That swaps the inode and silences a naive file-only watch
    /// after exactly one save, so this saves twice on purpose.
    @Test func repeatedAtomicSavesFromAnEditorAreEachPickedUpLive() async throws {
        let (store, directory) = makeStore()
        defer { cleanUp(directory) }

        store.start(seedSettings: .defaultSettings, seedKeybindings: DefaultKeybindings.config)

        for theme in ["catppuccin-mocha", "gruvbox-dark", "catppuccin-mocha"] {
            // `atomically: true` is the write-temp-then-rename path.
            try ConfigFile.write("{ \"theme\": \"\(theme)\" }", to: store.fileURL)

            let deadline = Date().addingTimeInterval(5)
            while store.settings.themeId != theme, Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            #expect(store.settings.themeId == theme)
        }
    }

    /// Someone re-cloning their dotfiles deletes and recreates the whole
    /// `~/.config/soprano` directory. Every descriptor we hold then points at a
    /// dead inode, so the watch has to be rebuilt against the new one rather
    /// than going quietly deaf for the rest of the session.
    @Test func theWatchIsRebuiltAfterTheConfigDirectoryIsReplaced() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soprano-watch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        try ConfigFile.write("{}", to: url)

        let changes = Changes()
        let watcher = ConfigFileWatcher(
            url: url,
            debounceInterval: .milliseconds(20),
            rearmInterval: .milliseconds(50)
        ) { changes.record() }
        watcher.start()
        defer { watcher.stop() }

        try FileManager.default.removeItem(at: directory)
        try await Task.sleep(nanoseconds: 200_000_000)

        let before = changes.count
        try ConfigFile.write("{ \"theme\": \"catppuccin-mocha\" }", to: url)

        let deadline = Date().addingTimeInterval(5)
        while changes.count == before, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(changes.count > before)
    }

    /// Counts watcher callbacks, which arrive on the watcher's own queue.
    private final class Changes: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func record() {
            lock.lock()
            value += 1
            lock.unlock()
        }
    }

    /// A file that exists but cannot be read is not an empty configuration.
    /// Treating it as one would silently reset the whole app to defaults the
    /// moment a permission changed.
    @Test func anUnreadableFileReportsAnErrorInsteadOfResettingEverything() throws {
        let (store, directory) = makeStore()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: store.fileURL.path
            )
            cleanUp(directory)
        }

        write("""
        { "theme": "catppuccin-mocha" }
        """, to: store)
        store.start(watching: false, seedSettings: .defaultSettings, seedKeybindings: DefaultKeybindings.config)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: store.fileURL.path
        )
        store.reloadFromDisk()

        #expect(store.settings.themeId == "catppuccin-mocha")
        #expect(store.issues.contains { $0.severity == .error })
    }

    /// The README recommends symlinking settings.json out of a dotfiles repo.
    /// An atomic write is a rename onto the path, so writing must follow the
    /// link instead of replacing it with a regular file.
    @Test func writingThroughASymlinkKeepsTheLinkAndUpdatesItsTarget() throws {
        let (store, directory) = makeStore()
        defer { cleanUp(directory) }

        let dotfiles = directory.appendingPathComponent("dotfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let target = dotfiles.appendingPathComponent("soprano.json")
        try ConfigFile.write("{ \"theme\": \"gruvbox-dark\" }", to: target)
        try FileManager.default.createSymbolicLink(at: store.fileURL, withDestinationURL: target)

        store.start(watching: false, seedSettings: .defaultSettings, seedKeybindings: DefaultKeybindings.config)
        #expect(store.write("catppuccin-mocha", at: ["theme"]))

        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)
        let written = try String(contentsOf: target, encoding: .utf8)
        #expect(written.contains("catppuccin-mocha"))
    }

    /// The watcher is debounced, so an external edit can be in flight when a
    /// settings control is clicked. The click must not rewrite the file from a
    /// stale copy and throw the user's edit away.
    @Test func aUIWriteMergesOntoWhateverIsOnDiskRatherThanOverwritingIt() {
        let (store, directory) = makeStore()
        defer { cleanUp(directory) }

        write("""
        { "theme": "gruvbox-dark" }
        """, to: store)
        store.start(watching: false, seedSettings: .defaultSettings, seedKeybindings: DefaultKeybindings.config)

        // An external edit the store has not observed yet.
        write("""
        { "theme": "gruvbox-dark", "restoreLastSession": false }
        """, to: store)

        #expect(store.write("catppuccin-mocha", at: ["theme"]))

        let text = try! String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(text.contains("\"restoreLastSession\": false"))
        #expect(store.settings.restoreLastSession == false)
        #expect(store.settings.themeId == "catppuccin-mocha")
    }

    @Test func removingAKeyRestoresTheBuiltInDefault() {
        let (store, directory) = makeStore()
        defer { cleanUp(directory) }

        write("""
        { "theme": "catppuccin-mocha" }
        """, to: store)
        store.start(watching: false, seedSettings: .defaultSettings, seedKeybindings: DefaultKeybindings.config)
        #expect(store.settings.themeId == "catppuccin-mocha")

        #expect(store.remove(at: ["theme"]))
        #expect(store.settings.themeId == AppSettings.defaultSettings.themeId)
    }

    @Test func configuredAgentsReachTheCatalogTheRestOfTheAppReads() {
        let (store, directory) = makeStore()
        defer { cleanUp(directory) }

        write("""
        { "agents": [ { "id": "aider", "command": "aider", "color": "#8bd5ca" } ] }
        """, to: store)
        store.start(watching: false, seedSettings: .defaultSettings, seedKeybindings: DefaultKeybindings.config)

        #expect(AgentCatalog.profile(for: "aider")?.command == "aider")
        #expect(AgentCatalog.profile(for: "aider")?.color == "#8bd5ca")
        #expect(KeybindingManager.launchedAgentId(for: "launch-aider") == "aider")

        // Restore the catalog for whatever runs next in this process.
        AgentCatalog.replaceAll(with: DefaultAgents.all)
    }

    @Test func theFilePathHonorsAnExplicitOverride() {
        // Documents the precedence the README promises. SOPRANO_CONFIG is read
        // from the environment, so this asserts the default-derivation rules
        // rather than mutating the process environment.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = ConfigFile.url.path
        #expect(path.hasSuffix("settings.json"))
        #expect(path.contains("soprano"))
        #expect(ConfigFile.displayPath(for: URL(fileURLWithPath: "\(home)/.config/soprano/settings.json"))
            == "~/.config/soprano/settings.json")
    }
}
