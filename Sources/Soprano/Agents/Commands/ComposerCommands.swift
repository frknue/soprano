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

    /// The composer for a command that shows or focuses something in it: the statistics board
    /// closes first.
    private static func revealedComposer(_ context: CommandContext) -> ComposerViewController? {
        context.workspace?.revealChat().composer
    }

    static var all: [AppCommand] {
        [
            AppCommand(
                id: "composer.focus",
                title: "Focus Composer",
                description: "Move the cursor into the message box",
                category: .composer,
                defaultKeys: ["cmd+shift+l"],
                icon: "text.cursor",
                isEnabled: { composer($0) != nil }
            ) { context in
                revealedComposer(context)?.focusEditor()
            },
            AppCommand(
                id: "modelPicker.toggle",
                title: "Model Picker",
                description: "Choose the model for this thread",
                category: .composer,
                scopes: notTerminal,
                defaultKeys: ["cmd+shift+m"],
                icon: "cpu",
                isEnabled: { composer($0) != nil }
            ) { context in
                revealedComposer(context)?.toggleModelPicker()
            },
            AppCommand(
                id: "composer.effort",
                title: "Reasoning Effort",
                description: "Set how much the model reasons",
                category: .composer,
                scopes: notTerminal,
                defaultKeys: ["cmd+shift+e"],
                icon: Icon.gauge,
                isEnabled: { composer($0) != nil }
            ) { context in
                revealedComposer(context)?.toggleTraits()
            },
            AppCommand(
                id: "composer.mode",
                title: "Permissions",
                description: "Choose what the agent may do without asking",
                category: .composer,
                scopes: notTerminal,
                defaultKeys: ["cmd+shift+a"],
                icon: "lock",
                isEnabled: { composer($0) != nil }
            ) { context in
                revealedComposer(context)?.togglePermissions()
            },
            AppCommand(
                id: "composer.workspace",
                title: "Workspace",
                description: "Choose where the thread works on the repository",
                category: .composer,
                scopes: notTerminal,
                defaultKeys: ["cmd+shift+x"],
                icon: Icon.folder,
                isEnabled: { composer($0)?.hasDraftRepository ?? false }
            ) { context in
                revealedComposer(context)?.toggleWorkspaceMenu()
            },
            AppCommand(
                id: "composer.branch",
                title: "Branch",
                description: "Pick the git branch for the thread",
                category: .composer,
                scopes: notTerminal,
                defaultKeys: ["cmd+shift+g"],
                icon: Icon.gitBranch,
                isEnabled: { composer($0)?.hasDraftRepository ?? false }
            ) { context in
                revealedComposer(context)?.toggleBranchPicker()
            },
            AppCommand(
                id: "composer.sendAlternate",
                title: "Steer or Queue (opposite)",
                description: "Send as steer or queue, whichever isn't default",
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
                description: "Stop the running turn",
                category: .thread,
                icon: Icon.stop,
                isEnabled: { composer($0)?.canStop ?? false }
            ) { context in
                composer(context)?.stop()
            },
            AppCommand(
                id: "thread.compact",
                title: "Compact Conversation",
                description: "Summarize history to free up context",
                category: .thread,
                icon: "arrow.down.right.and.arrow.up.left",
                isEnabled: { composer($0)?.canCompact ?? false }
            ) { context in
                revealedComposer(context)?.compactConversation()
            },
        ]
    }
}
