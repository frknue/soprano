import AppKit

/// The menu bar, built from the command registry: titles and ⌘ key equivalents follow the live
/// keymap and are rebuilt on settings changes. Command items validate against the main window's
/// command context. Commands a module has not registered show disabled with a fallback title.
@MainActor
final class MainMenuController: NSObject, NSMenuItemValidation {
    var windowController: () -> MainWindowController?
    private let registry: CommandRegistry

    init(registry: CommandRegistry = .shared, windowController: @escaping () -> MainWindowController?) {
        self.registry = registry
        self.windowController = windowController
        super.init()
    }

    func install() {
        NSApp.mainMenu = buildMenu()
    }

    func buildMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu(title: "Soprano Agents")
        appMenu.addItem(withTitle: "About Soprano Agents", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(commandItem("settings.open", title: "Settings…"))
        appMenu.addItem(commandItem("settings.openFile"))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Soprano Agents", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Soprano Agents", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, to: main)

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(commandItem("chat.new", title: "New Thread"))
        fileMenu.addItem(commandItem("chat.newLocal", title: "New Thread in Current Project"))
        fileMenu.addItem(commandItem("chat.newWithoutProject", title: "New Thread Without a Project"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(commandItem("project.add", title: "Add Project…"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "")
        add(fileMenu, to: main)

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let pasteText = editMenu.addItem(withTitle: "Paste as Text", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
        pasteText.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(commandItem("chat.find", title: "Find in Thread"))
        add(editMenu, to: main)

        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(commandItem("palette.open", title: "Command Palette…"))
        viewMenu.addItem(.separator())
        viewMenu.addItem(commandItem("view.toggleSidebar"))
        viewMenu.addItem(commandItem("view.toggleThreadDetails"))
        viewMenu.addItem(commandItem("view.toggleTerminal"))
        viewMenu.addItem(commandItem("view.toggleRightPanel"))
        viewMenu.addItem(commandItem("diff.toggle", title: "Toggle Diff"))
        viewMenu.addItem(.separator())
        let fullScreen = viewMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        add(viewMenu, to: main)

        let threadMenu = NSMenu(title: "Thread")
        threadMenu.addItem(commandItem("thread.previous", title: "Previous Thread"))
        threadMenu.addItem(commandItem("thread.next", title: "Next Thread"))
        threadMenu.addItem(.separator())
        threadMenu.addItem(commandItem("thread.stop", title: "Interrupt"))
        threadMenu.addItem(commandItem("thread.rename", title: "Rename Thread…"))
        threadMenu.addItem(commandItem("thread.pin", title: "Pin Thread"))
        threadMenu.addItem(commandItem("thread.settle", title: "Settle Thread"))
        threadMenu.addItem(commandItem("thread.archive", title: "Archive Thread"))
        threadMenu.addItem(.separator())
        threadMenu.addItem(commandItem("thread.delete", title: "Delete Thread…"))
        add(threadMenu, to: main)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        add(windowMenu, to: main)
        NSApp.windowsMenu = windowMenu

        let helpMenu = NSMenu(title: "Help")
        add(helpMenu, to: main)
        NSApp.helpMenu = helpMenu

        return main
    }

    private func add(_ submenu: NSMenu, to main: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        main.addItem(item)
    }

    /// A menu item running `id`; shows the first direct ⌘ chord as key equivalent.
    func commandItem(_ id: String, title: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(
            title: title ?? registry.command(id)?.title ?? id,
            action: #selector(performCommand(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = id
        if let equivalent = SettingsCenter.shared.chords(for: id).lazy.compactMap(\.menuKeyEquivalent).first {
            item.keyEquivalent = equivalent.key
            item.keyEquivalentModifierMask = equivalent.modifiers
        }
        return item
    }

    @objc func performCommand(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        windowController()?.perform(id)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(performCommand(_:)) else { return true }
        guard let id = menuItem.representedObject as? String, let command = registry.command(id) else { return false }
        // While a dialog or the palette has the keyboard, commands wait.
        if let key = NSApp.keyWindow, !(key is MainWindow) { return false }
        guard let controller = windowController() else { return false }
        if controller.window?.attachedSheet != nil { return false }
        return command.isEnabled(controller.commandContext())
    }
}
