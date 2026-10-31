import AppKit
import SopranoAgentsCore

/// Composer module: model picker, effort, permissions, workspace, branch, send alternate, stop,
/// compaction.
@MainActor
enum ComposerCommands {
    /// `!terminalFocus`.
    private static let notTerminal = FocusRegion.outsideTerminal

    private static func composer(_ context: CommandContext) -> ComposerViewController? {
        context.workspace?.chat.composer
    }

    static var all: [AppCommand] {
        [
            AppCommand(
                id: "composer.focus",
                title: "Focus Composer",
                category: .composer,
                defaultKeys: ["cmd+shift+l"],
                icon: "text.cursor",
                isEnabled: { composer($0) != nil }
            ) { context in
                composer(context)?.focusEditor()
            },
            AppCommand(
                id: "modelPicker.toggle",
                title: "Model Picker",
                category: .composer,
                scopes: notTerminal,
                defaultKeys: ["cmd+shift+m"],
                icon: "cpu",
                isEnabled: { composer($0) != nil }
            ) { context in
                composer(context)?.toggleModelPicker()
            },
            AppCommand(
                id: "composer.effort",
                title: "Reasoning Effort",
                category: .composer,
                scopes: notTerminal,
                defaultKeys: ["cmd+shift+e"],
                icon: Icon.gauge,
                isEnabled: { composer($0) != nil }
            ) { context in
                composer(context)?.toggleTraits()
            },
            AppCommand(
                id: "composer.mode",
                title: "Permissions",
                category: .composer,
                scopes: notTerminal,
                defaultKeys: ["cmd+shift+a"],
                icon: "lock",
                isEnabled: { composer($0) != nil }
            ) { context in
                composer(context)?.togglePermissions()
            },
            AppCommand(
                id: "composer.workspace",
                title: "Workspace",
                category: .composer,
                scopes: notTerminal,
                defaultKeys: ["cmd+shift+x"],
                icon: Icon.folder,
                isEnabled: { composer($0)?.hasDraftRepository ?? false }
            ) { context in
                composer(context)?.toggleWorkspaceMenu()
            },
            AppCommand(
                id: "composer.branch",
                title: "Branch",
                category: .composer,
                scopes: notTerminal,
                defaultKeys: ["cmd+shift+g"],
                icon: Icon.gitBranch,
                isEnabled: { composer($0)?.hasDraftRepository ?? false }
            ) { context in
                composer(context)?.toggleBranchPicker()
            },
            AppCommand(
                id: "composer.sendAlternate",
                title: "Steer or Queue (opposite)",
                category: .composer,
                scopes: [.composer],
                defaultKeys: ["cmd+enter"],
                icon: Icon.listPlus,
                isEnabled: { composer($0) != nil }
            ) { context in
                composer(context)?.sendAlternate()
            },
            AppCommand(
                id: "thread.stop",
                title: "Interrupt",
                category: .thread,
                icon: Icon.stop,
                isEnabled: { composer($0)?.canStop ?? false }
            ) { context in
                composer(context)?.stop()
            },
            AppCommand(
                id: "thread.compact",
                title: "Compact Conversation",
                category: .thread,
                icon: "arrow.down.right.and.arrow.up.left",
                isEnabled: { composer($0)?.canCompact ?? false }
            ) { context in
                composer(context)?.compactConversation()
            },
        ]
    }
}
