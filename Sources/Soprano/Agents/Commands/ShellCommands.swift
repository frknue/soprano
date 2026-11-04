import AppKit
import SopranoAgentsCore

/// Window-level commands: panel toggles, settings, command palette (Shell module).
@MainActor
enum ShellCommands {
    static var all: [AppCommand] {
        [
            AppCommand(
                id: "palette.open",
                title: "Command Palette",
                description: "Search commands, threads, projects and settings",
                category: .app,
                defaultKeys: ["cmd+k", "cmd+p"],
                icon: Icon.search,
                inPalette: false
            ) { context in
                CommandPalette.toggle(in: context)
            },
            AppCommand(
                id: "window.showTerminals",
                title: "Show Terminals",
                description: "Bring Soprano's terminal window forward",
                category: .app,
                defaultKeys: ["cmd+shift+t"],
                icon: "terminal"
            ) { context in
                (context.window?.windowController as? AgentsWindowController)?.showTerminals?()
            },
            AppCommand(
                id: "window.close",
                title: "Close Soprano Agents",
                description: "Close this window and go back to the terminals; threads keep working, and ⇧⌘A there opens it again",
                category: .app,
                defaultKeys: ["cmd+shift+a"],
                icon: "xmark.rectangle"
            ) { context in
                guard let controller = context.window?.windowController as? AgentsWindowController else { return }
                controller.close()
                controller.showTerminals?()
            },
            AppCommand(
                id: "settings.open",
                title: "Settings",
                description: "Open the settings screen",
                category: .app,
                defaultKeys: ["cmd+,"],
                icon: Icon.settings
            ) { context in
                SettingsController.toggle(in: context)
            },
            AppCommand(
                id: "view.toggleSidebar",
                title: "Toggle Sidebar",
                description: "Show or hide the thread list",
                category: .view,
                defaultKeys: ["cmd+e"],
                icon: "sidebar.left"
            ) { context in
                guard let state = context.state else { return }
                state.setSidebarVisible(!state.isSidebarVisible)
            },
            AppCommand(
                id: "view.toggleThreadDetails",
                title: "Toggle Thread Details",
                description: "Show or hide the thread's git and folder info",
                category: .view,
                scopes: FocusRegion.outsideTerminal,
                defaultKeys: ["cmd+shift+b"],
                icon: Icon.squareMenu
            ) { context in
                guard let state = context.state else { return }
                state.setThreadDetailsVisible(state.toggledVisibility(state.isThreadDetailsVisible))
            },
            AppCommand(
                id: "view.toggleTerminal",
                title: "Toggle Terminal Drawer",
                description: "Show or hide the terminal below the thread",
                category: .view,
                defaultKeys: ["cmd+j"],
                icon: Icon.panelBottom,
                isEnabled: { $0.state?.workspace != nil }
            ) { context in
                guard let state = context.state else { return }
                state.setTerminalVisible(state.toggledVisibility(state.isTerminalVisible))
            },
            AppCommand(
                id: "view.toggleRightPanel",
                title: "Toggle Right Panel",
                description: "Show or hide the panel on the right",
                category: .view,
                defaultKeys: ["cmd+l"],
                icon: Icon.panelRight
            ) { context in
                guard let state = context.state else { return }
                state.setRightPanelVisible(state.toggledVisibility(state.isRightPanelVisible))
            },
            AppCommand(
                id: "settings.openFile",
                title: "Open settings.json",
                description: "Edit the raw settings file in your editor",
                category: .app,
                icon: "doc.text"
            ) { _ in
                SettingsCenter.shared.openInEditor()
            },
        ]
    }
}
