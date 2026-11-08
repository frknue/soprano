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

    @Test func aDialogKeepsSopranosChordsSoCommandDPicksDontSaveInsteadOfOpeningATerminal() throws {
        let agentManager = AgentManager()
        let keybindings = KeybindingManager(agentManager: agentManager, config: DefaultKeybindings.config)
        let parent = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        parent.isReleasedWhenClosed = false
        parent.orderFront(nil)
        defer { parent.orderOut(nil) }
        func commandD(in window: NSWindow) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "d",
                charactersIgnoringModifiers: "d", isARepeat: false, keyCode: 2
            ))
        }
        let paneCount = agentManager.panes.count

        var result: ShellDialogResult?
        let dialog = ShellDialogController(
            content: ShellDialogContent(
                title: "Save?",
                message: "",
                buttons: [
                    ShellDialogButton("Don't Save", style: .destructiveOutline, keyEquivalent: "d", keyModifiers: .command),
                    ShellDialogButton("Cancel"),
                    ShellDialogButton("Save", style: .primary),
                ]
            )
        ) { result = $0 }
        dialog.present(over: parent)

        // In the dialog, and in the window it covers, ⌘D passes Soprano's
        // bindings by and opens no terminal.
        let inDialog = try commandD(in: dialog.window)
        #expect(keybindings.filter(inDialog) === inDialog)
        #expect(keybindings.filter(try commandD(in: parent)) != nil)
        #expect(agentManager.panes.count == paneCount)
        #expect(dialog.window.keyHandler?(inDialog) == true)
        #expect(result?.index == 0)

        // Once it closed, ⌘D is New Terminal again.
        #expect(keybindings.filter(try commandD(in: parent)) == nil)
        #expect(agentManager.panes.count == paneCount + 1)
    }

    @Test func aDialogKeepsMenuShortcutsFromActingBehindItButLetsEditingAndQuitThrough() throws {
        final class Recorder: NSObject {
            var fired: [String] = []
            @objc func commandPalette(_ sender: Any?) { fired.append("palette") }
            @objc func dashboard(_ sender: Any?) { fired.append("dashboard") }
        }
        let recorder = Recorder()
        let menu = NSMenu()
        let commands = NSMenuItem(title: "Commands", action: nil, keyEquivalent: "")
        commands.submenu = NSMenu(title: "Commands")
        for (title, action, key, modifiers) in [
            ("Command Palette", #selector(Recorder.commandPalette(_:)), "p", NSEvent.ModifierFlags.command),
            ("Agent Dashboard", #selector(Recorder.dashboard(_:)), "d", [.command, .shift]),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = recorder
            commands.submenu?.addItem(item)
        }
        menu.addItem(commands)

        let parent = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        parent.isReleasedWhenClosed = false
        parent.orderFront(nil)
        defer { parent.orderOut(nil) }
        let dialog = ShellDialogController(
            content: ShellDialogContent(title: "Close Session?", message: "", buttons: [
                ShellDialogButton("Cancel"), ShellDialogButton("Close Session", style: .destructive),
            ])
        ) { _ in }
        dialog.present(over: parent)
        defer { dialog.finish(index: nil) }

        func chord(_ key: String, _ modifiers: NSEvent.ModifierFlags, keyCode: UInt16) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: dialog.window.windowNumber, context: nil, characters: key,
                charactersIgnoringModifiers: key, isARepeat: false, keyCode: keyCode
            ))
        }
        /// NSApplication's order for a key equivalent: the key window, then the main menu.
        func dispatch(_ event: NSEvent) -> Bool {
            dialog.window.performKeyEquivalent(with: event) || menu.performKeyEquivalent(with: event)
        }

        _ = dispatch(try chord("p", .command, keyCode: 35))
        _ = dispatch(try chord("d", [.command, .shift], keyCode: 2))
        #expect(recorder.fired.isEmpty)

        // Editing chords and quitting still go on to the menu.
        #expect(!dialog.window.performKeyEquivalent(with: try chord("c", .command, keyCode: 8)))
        #expect(!dialog.window.performKeyEquivalent(with: try chord("v", .command, keyCode: 9)))
        #expect(!dialog.window.performKeyEquivalent(with: try chord("q", .command, keyCode: 12)))

        // Without a dialog the same chords reach the menu.
        dialog.finish(index: nil)
        #expect(menu.performKeyEquivalent(with: try chord("p", .command, keyCode: 35)))
        #expect(recorder.fired == ["palette"])
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }
}
