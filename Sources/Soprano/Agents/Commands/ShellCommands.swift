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
                category: .app,
                defaultKeys: ["cmd+k"],
                icon: Icon.search,
                inPalette: false
            ) { context in
                CommandPaletteController.toggle(in: context)
            },
            AppCommand(
                id: "settings.open",
                title: "Settings",
                category: .app,
                defaultKeys: ["cmd+,"],
                icon: Icon.settings
            ) { context in
                SettingsController.toggle(in: context)
            },
            AppCommand(
                id: "view.toggleSidebar",
                title: "Toggle Sidebar",
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
                category: .view,
                scopes: FocusRegion.outsideTerminal,
                defaultKeys: ["cmd+shift+b"],
                icon: Icon.squareMenu
            ) { context in
                guard let state = context.state else { return }
                state.setThreadDetailsVisible(!state.isThreadDetailsVisible)
            },
            AppCommand(
                id: "view.toggleTerminal",
                title: "Toggle Terminal Drawer",
                category: .view,
                defaultKeys: ["cmd+j"],
                icon: Icon.panelBottom,
                isEnabled: { $0.state?.workspace != nil }
            ) { context in
                guard let state = context.state else { return }
                state.setTerminalVisible(!state.isTerminalVisible)
            },
            AppCommand(
                id: "view.toggleRightPanel",
                title: "Toggle Right Panel",
                category: .view,
                defaultKeys: ["cmd+l"],
                icon: Icon.panelRight
            ) { context in
                guard let state = context.state else { return }
                state.setRightPanelVisible(!state.isRightPanelVisible)
            },
            AppCommand(
                id: "settings.openFile",
                title: "Open settings.json",
                category: .app,
                icon: "doc.text"
            ) { _ in
                SettingsCenter.shared.openInEditor()
            },
        ]
    }
}
