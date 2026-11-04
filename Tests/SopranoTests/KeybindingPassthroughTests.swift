import AppKit
import Testing
@testable import Soprano

/// Soprano's chords act on the panes; while the command palette or the
/// Prefix key recorder has the keyboard, a chord belongs to them instead.
@MainActor
struct KeybindingPassthroughTests {
    @Test func theCommandPaletteKeepsItsKeysAndAPlainWindowDoesNot() {
        let palette = CommandPalettePanel(themeManager: ThemeManager(themeId: "gruvbox-dark"))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        #expect(KeybindingManager.leavesKeysAlone(in: palette))
        #expect(!KeybindingManager.leavesKeysAlone(in: window))
    }

    @Test func aRecordingPrefixKeyFieldKeepsItsKeysUntilItHasOne() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soprano-passthrough-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(fileURL: directory.appendingPathComponent("settings.json"))
        store.start(watching: false, seedSettings: .defaultSettings, seedKeybindings: DefaultKeybindings.config)
        let controller = SettingsViewController(
            themeManager: ThemeManager(themeId: store.settings.themeId),
            settings: store.settings,
            keybindingConfig: store.keybindings,
            configStore: store
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        let prefix = try #require(descendants(of: controller.view).compactMap { $0 as? NSControl }
            .first { $0.accessibilityLabel() == "Prefix key" })
        #expect(!KeybindingManager.leavesKeysAlone(in: window))

        #expect(prefix.accessibilityPerformPress())
        #expect(KeybindingManager.leavesKeysAlone(in: window))

        prefix.keyDown(with: try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .control,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{0C}",
            charactersIgnoringModifiers: "l",
            isARepeat: false,
            keyCode: 37
        )))
        #expect(store.keybindings.prefixKey == "l")
        #expect(!KeybindingManager.leavesKeysAlone(in: window))
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }
}
