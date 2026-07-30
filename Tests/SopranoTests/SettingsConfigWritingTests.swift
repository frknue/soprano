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

    private func makeController(_ store: ConfigStore) -> SettingsViewController {
        let controller = SettingsViewController(
            themeManager: ThemeManager(themeId: store.settings.themeId),
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

        let mochaIndex = AppTheme.allThemes.firstIndex { $0.id == "catppuccin-mocha" }!
        popup?.selectItem(at: mochaIndex)
        send(popup!)

        #expect(store.settings.themeId == "catppuccin-mocha")
        #expect(fileText(store).contains("\"theme\": \"catppuccin-mocha\""))
    }

    @Test func togglingRestoreLastSessionRewritesItsKeyInTheFile() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let controller = makeController(store)
        // Checkboxes sit at the trailing edge of a labeled row, so the
        // accessibility label is what names them now.
        let checkbox = controls(NSButton.self, in: controller.view)
            .first { $0.accessibilityLabel() == "Restore last session" }
        #expect(checkbox != nil)

        checkbox?.state = .off
        send(checkbox!)

        #expect(store.settings.restoreLastSession == false)
        #expect(fileText(store).contains("\"restoreLastSession\": false"))
    }

    @Test func togglingHideWindowBarRewritesItsKeyInTheFile() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let controller = makeController(store)
        let checkbox = controls(NSButton.self, in: controller.view)
            .first { $0.accessibilityLabel() == "Hide window bar" }
        #expect(checkbox != nil)

        checkbox?.state = .on
        send(checkbox!)

        #expect(store.settings.hideWindowBar == true)
        #expect(fileText(store).contains("\"hideWindowBar\": true"))
    }

    @Test func addingAProjectDirectoryWritesItHomeRelativeAndResolvesItBack() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let controller = makeController(store)
        let input = controls(NSTextField.self, in: controller.view)
            .first { $0.placeholderString == "Folder path" }
        #expect(input != nil)

        let home = FileManager.default.homeDirectoryForCurrentUser
        input?.stringValue = home.path
        send(input!)

        // Written as "~", read back as the absolute path the app can use.
        #expect(fileText(store).contains("\"~\""))
        #expect(store.settings.projectDirectories == [home.standardizedFileURL.path])
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
