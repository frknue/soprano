import AppKit
import SopranoAgentsCore

/// Window-level commands: panel toggles, settings, command palette (Shell module).
@MainActor
enum ShellCommands {
    static var all: [AppCommand] {
        [
            AppCommand(
                id: "view.toggleSidebar",
                title: "Toggle Sidebar",
                category: .view,
                defaultKeys: ["cmd+b"],
                icon: "sidebar.left"
            ) { context in
                guard let state = context.state else { return }
                state.setSidebarVisible(!state.isSidebarVisible)
            },
            AppCommand(
                id: "view.toggleThreadDetails",
                title: "Toggle Thread Details",
                category: .view,
                scopes: [.sidebar, .timeline, .composer, .rightPanel],
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
                isEnabled: { $0.state?.selectedThreadID != nil }
            ) { context in
                guard let state = context.state else { return }
                state.setTerminalVisible(!state.isTerminalVisible)
            },
            AppCommand(
                id: "view.toggleRightPanel",
                title: "Toggle Right Panel",
                category: .view,
                defaultKeys: ["cmd+ctrl+b"],
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
