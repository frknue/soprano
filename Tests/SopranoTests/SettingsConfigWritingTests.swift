import AppKit
import Testing
@testable import Soprano

/// Proves the settings screen is a view over `settings.json` rather than a
/// second place state lives: driving its real controls must land in the file.
@MainActor
struct SettingsConfigWritingTests {
    private func makeStore() -> (store: ConfigStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soprano-settings-ui-\(UUID().uuidString)", isDirectory: true)
        let store = ConfigStore(fileURL: directory.appendingPathComponent("settings.json"))
        store.start(
            watching: false,
            seedSettings: .defaultSettings,
            seedKeybindings: DefaultKeybindings.config
        )
        return (store, directory)
    }

    private func makeController(
        _ store: ConfigStore,
        themeManager: ThemeManager? = nil
    ) -> SettingsViewController {
        let controller = SettingsViewController(
            themeManager: themeManager ?? ThemeManager(themeId: store.settings.themeId),
            settings: store.settings,
            keybindingConfig: store.keybindings,
            configStore: store
        )
        controller.loadViewIfNeeded()
        return controller
    }

    private func fileText(_ store: ConfigStore) -> String {
        (try? String(contentsOf: store.fileURL, encoding: .utf8)) ?? ""
    }

    private func controls<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view.subviews.compactMap { $0 as? T }) + view.subviews.flatMap { controls(type, in: $0) }
    }

    private func send(_ control: NSControl) {
        guard let action = control.action, let target = control.target else { return }
        _ = NSApp.sendAction(action, to: target, from: control)
    }

    @Test func choosingAThemeInTheUIRewritesTheThemeKeyInTheFile() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let controller = makeController(store)
        let popup = controls(NSPopUpButton.self, in: controller.view).first
        #expect(popup != nil)

        // The menu sets Folio apart with a separator, so pick by value.
        popup?.selectItem(at: popup?.indexOfItem(withRepresentedObject: "catppuccin-mocha") ?? -1)
        send(popup!)

        #expect(store.settings.themeId == "catppuccin-mocha")
        #expect(fileText(store).contains("\"theme\": \"catppuccin-mocha\""))
    }

    @Test func togglingRestoreLastSessionRewritesItsKeyInTheFile() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let controller = makeController(store)
        // Switches sit at the trailing edge of a labeled row, so the
        // accessibility label is what names them.
        let toggle = controls(SettingsSwitch.self, in: controller.view)
            .first { $0.accessibilityLabel() == "Restore last session" }
        #expect(toggle != nil)

        toggle?.state = .off
        send(toggle!)

        #expect(store.settings.restoreLastSession == false)
        #expect(fileText(store).contains("\"restoreLastSession\": false"))
    }

    @Test func togglingHideWindowBarRewritesItsKeyInTheFile() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let controller = makeController(store)
        let toggle = controls(SettingsSwitch.self, in: controller.view)
            .first { $0.accessibilityLabel() == "Hide window bar" }
        #expect(toggle != nil)

        toggle?.state = .on
        send(toggle!)

        #expect(store.settings.hideWindowBar == true)
        #expect(fileText(store).contains("\"hideWindowBar\": true"))
    }

    @Test func choosingDarkAppearanceWritesTheAppearanceKeyAndPinsTheThemeManager() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let themeManager = ThemeManager(themeId: store.settings.themeId)
        let controller = makeController(store, themeManager: themeManager)
        #expect(themeManager.appearance == .system)

        let dark = controls(NSButton.self, in: controller.view).first { $0.title == "Dark" }
        #expect(dark != nil)
        send(dark!)

        #expect(store.settings.appearance == .dark)
        #expect(fileText(store).contains("\"appearance\": \"dark\""))
        #expect(themeManager.appearance == .dark)
        #expect(themeManager.currentTheme.appearance == .dark)
    }

    @Test func theAppearanceControlReflectsTheConfiguredAppearance() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        store.write("light", at: ["appearance"])
        let controller = makeController(store)

        let light = controls(NSButton.self, in: controller.view).first { $0.title == "Light" }
        #expect(light?.accessibilityValue() as? Bool == true)
        let system = controls(NSButton.self, in: controller.view).first { $0.title == "System" }
        #expect(system?.accessibilityValue() as? Bool == false)
    }

    @Test func togglingTheUptimeSwitchWritesTheNestedStatusBarKey() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let controller = makeController(store)
        let toggle = controls(SettingsSwitch.self, in: controller.view)
            .first { $0.accessibilityLabel() == "Show uptime in status bar" }
        #expect(toggle?.state == .off)

        toggle?.state = .on
        send(toggle!)
        #expect(store.settings.statusBarUptime == true)
        #expect(fileText(store).contains("\"uptime\": true"))

        toggle?.state = .off
        send(toggle!)
        #expect(store.settings.statusBarUptime == false)
        #expect(fileText(store).contains("\"uptime\": false"))
    }

    @Test func recordingAPrefixKeyWritesItAndShowsItAsAControlChord() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let controller = makeController(store)
        let prefix = try #require(
            controls(NSControl.self, in: controller.view)
                .first { $0.accessibilityLabel() == "Prefix key" }
        )
        #expect(prefix.accessibilityValue() as? String == "⌃A")

        #expect(prefix.accessibilityPerformPress())
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "b",
            charactersIgnoringModifiers: "b",
            isARepeat: false,
            keyCode: 11
        ))
        prefix.keyDown(with: event)

        #expect(prefix.accessibilityValue() as? String == "⌃B")
        #expect(store.keybindings.prefixKey == "b")
        #expect(fileText(store).contains("\"prefixKey\": \"b\""))
    }

    @Test func aPrefixKeyThatNeedsShiftIsRefusedBecauseControlAloneCouldNeverTypeIt() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let controller = makeController(store)
        let prefix = try #require(
            controls(NSControl.self, in: controller.view)
                .first { $0.accessibilityLabel() == "Prefix key" }
        )
        func shifted(_ character: String, keyCode: UInt16) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .shift,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: character,
                charactersIgnoringModifiers: character,
                isARepeat: false,
                keyCode: keyCode
            ))
        }

        #expect(prefix.accessibilityPerformPress())
        prefix.keyDown(with: try shifted("!", keyCode: 18))
        #expect(store.keybindings.prefixKey == "a")

        // A shifted letter is still that letter: ⌃B types it without Shift.
        prefix.keyDown(with: try shifted("B", keyCode: 11))
        #expect(store.keybindings.prefixKey == "b")
    }

    @Test func addingAProjectDirectoryWritesItHomeRelativeAndResolvesItBack() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let controller = makeController(store)
        let input = controls(NSTextField.self, in: controller.view)
            .first { $0.placeholderAttributedString?.string == "Folder path" }
        #expect(input != nil)

        let home = FileManager.default.homeDirectoryForCurrentUser
        input?.stringValue = home.path
        send(input!)

        // Written as "~", read back as the absolute path the app can use.
        #expect(fileText(store).contains("\"~\""))
        #expect(store.settings.projectDirectories == [home.standardizedFileURL.path])
    }

    @Test func addingOrRemovingAProjectDirectoryKeepsThePageInsteadOfRebuildingIt() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let controller = makeController(store)
        let input = try #require(controls(NSTextField.self, in: controller.view)
            .first { $0.placeholderAttributedString?.string == "Folder path" })
        func settle() async throws {
            // The screen adopts the store's change like the main window does;
            // a rebuild would land once the main queue gets a turn.
            controller.update(settings: store.settings, keybindingConfig: store.keybindings)
            try await Task.sleep(for: .milliseconds(50))
        }

        input.stringValue = folder.path
        send(input)
        try await settle()
        #expect(store.settings.projectDirectories.contains(folder.standardizedFileURL.path))
        #expect(input.isDescendant(of: controller.view))

        let remove = try #require(controls(NSButton.self, in: controller.view)
            .first { $0.title == "Remove" || $0.accessibilityLabel() == "Remove" })
        send(remove)
        try await settle()
        #expect(store.settings.projectDirectories.isEmpty)
        #expect(input.isDescendant(of: controller.view))
    }

    @Test func editingThePrefixTimeoutClampsAndWritesTheNestedKey() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let controller = makeController(store)
        let field = controls(NSTextField.self, in: controller.view)
            .first { $0.isEditable && $0.stringValue == "\(DefaultKeybindings.config.prefixTimeoutMs)" }
        #expect(field != nil)

        field?.stringValue = "99999"
        send(field!)

        #expect(field?.stringValue == "5000")
        #expect(store.keybindings.prefixTimeoutMs == 5000)
        #expect(fileText(store).contains("\"prefixTimeoutMs\": 5000"))
    }

    /// A syntax error deliberately keeps the last good values, so nothing the
    /// screen compares changes — the banner still has to appear.
    @Test func aBreakageThatChangesNoValuesStillRaisesABannerOnTheOpenScreen() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let controller = makeController(store)
        controller.update(settings: store.settings, keybindingConfig: store.keybindings)
        #expect(!controls(NSTextField.self, in: controller.view)
            .contains { $0.stringValue.contains("Line 2") })

        try! ConfigFile.write("{\n  \"theme\":\n}", to: store.fileURL)
        store.reloadFromDisk()
        // Values are untouched on purpose — only the issue list moved.
        #expect(store.settings == AppSettings.defaultSettings)
        let error = store.issues.first { $0.severity == .error }
        #expect(error?.line == 3)

        controller.update(settings: store.settings, keybindingConfig: store.keybindings)
        // update() defers the rebuild so it cannot tear down a control that is
        // mid-edit; yield the main actor so that work runs.
        try await Task.sleep(nanoseconds: 100_000_000)

        let labels = controls(NSTextField.self, in: controller.view).map(\.stringValue)
        #expect(labels.contains { $0.contains("Line 3") && $0.contains("Unexpected character") })
    }

    @Test func aConfigProblemIsShownOnTheSettingsScreenInsteadOfFailingSilently() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try! ConfigFile.write("""
        { "theme": "no-such-theme" }
        """, to: store.fileURL)
        store.reloadFromDisk()
        #expect(store.issues.contains { $0.severity == .warning })

        let controller = makeController(store)
        let labels = controls(NSTextField.self, in: controller.view).map(\.stringValue)
        #expect(labels.contains { $0.contains("no-such-theme") })
    }
}
