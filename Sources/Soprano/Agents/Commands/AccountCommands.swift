import AppKit
import SopranoAgentsCore

/// Account and usage commands (Accounts module): the usage card, Settings → Accounts, refresh.
@MainActor
enum AccountCommands {
    static var all: [AppCommand] {
        [
            AppCommand(
                id: "usage.open",
                title: "Show Usage",
                description: "Show plan limits and usage in the sidebar",
                category: .app,
                defaultKeys: ["cmd+u"],
                icon: "gauge.medium"
            ) { context in
                guard let workspace = context.workspace else { return }
                workspace.state.setSidebarVisible(true)
                workspace.view.layoutSubtreeIfNeeded()
                workspace.sidebar.toggleUsageCard()
            },
            AppCommand(
                id: "accounts.manage",
                title: "Manage Accounts…",
                description: "Add or switch accounts in settings",
                category: .app,
                icon: "person.2"
            ) { context in
                guard let window = context.window, let engine = context.engine else { return }
                SettingsController.present(page: .accounts, engine: engine, over: window)
            },
            AppCommand(
                id: "usage.refresh",
                title: "Refresh Usage",
                description: "Fetch the latest usage numbers",
                category: .app,
                icon: "arrow.clockwise"
            ) { _ in
                AccountsCenter.source.refresh(force: true)
            },
        ]
    }
}
