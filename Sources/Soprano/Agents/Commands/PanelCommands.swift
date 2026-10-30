import AppKit
import SopranoAgentsCore

/// Panels module: diff toggle and view options, terminal new/close, open in editor, git actions.
@MainActor
enum PanelCommands {
    private static let notTerminal: Set<FocusRegion> = [.sidebar, .timeline, .composer, .rightPanel]

    static var all: [AppCommand] {
        [
            AppCommand(
                id: "diff.toggle",
                title: "Toggle Diff",
                category: .diff,
                scopes: notTerminal,
                defaultKeys: ["cmd+d"],
                icon: Icon.fileDiff
            ) { context in
                guard let state = context.state else { return }
                if state.isRightPanelVisible && state.rightPanelSurface == .diff {
                    state.setRightPanelVisible(false)
                } else {
                    state.showRightPanel(.diff)
                }
            },
            AppCommand(
                id: "diff.toggleLayout",
                title: "Toggle Split Diff View",
                category: .diff,
                icon: "rectangle.split.2x1"
            ) { context in
                guard let state = context.state, let diff = context.workspace?.rightPanel.diff else { return }
                state.showRightPanel(.diff)
                diff.toggleLayout()
            },
            AppCommand(
                id: "diff.toggleFileTree",
                title: "Toggle Diff File Tree",
                category: .diff,
                icon: "list.bullet.indent"
            ) { context in
                guard let state = context.state, let diff = context.workspace?.rightPanel.diff else { return }
                state.showRightPanel(.diff)
                diff.toggleFileTree()
            },
            AppCommand(
                id: "rightPanel.toggleMaximized",
                title: "Maximize Right Panel",
                category: .view,
                icon: "arrow.up.left.and.arrow.down.right",
                isEnabled: { $0.state?.isRightPanelVisible == true }
            ) { context in
                guard let state = context.state else { return }
                state.setRightPanelMaximized(!state.isRightPanelMaximized)
            },
            AppCommand(
                id: "terminal.new",
                title: "New Terminal",
                category: .terminal,
                scopes: [.terminal],
                defaultKeys: ["cmd+n"],
                icon: Icon.terminal,
                isEnabled: { $0.state?.selectedThreadID != nil }
            ) { context in
                context.workspace?.chat.terminal.newTerminal()
            },
            AppCommand(
                id: "terminal.close",
                title: "Close Terminal",
                category: .terminal,
                scopes: [.terminal],
                defaultKeys: ["cmd+w"],
                icon: "trash",
                isEnabled: { $0.state?.selectedThreadID != nil }
            ) { context in
                context.workspace?.chat.terminal.closeActiveTerminal()
            },
            AppCommand(
                id: "editor.openFavorite",
                title: "Open in Editor",
                category: .project,
                defaultKeys: ["cmd+o"],
                icon: "arrow.up.forward.app",
                isEnabled: { $0.workspace?.chat.details.workingDirectory != nil }
            ) { context in
                context.workspace?.chat.details.openInEditor()
            },
            AppCommand(
                id: "git.commit",
                title: "Commit",
                category: .project,
                icon: "checkmark.circle",
                isEnabled: { $0.state?.selectedThreadID != nil }
            ) { context in
                context.workspace?.chat.details.openCommitDialog()
            },
            AppCommand(
                id: "git.push",
                title: "Push",
                category: .project,
                icon: "icloud.and.arrow.up",
                isEnabled: { $0.state?.selectedThreadID != nil }
            ) { context in
                context.workspace?.chat.details.run(.push)
            },
            AppCommand(
                id: "git.createPR",
                title: "Create PR",
                category: .project,
                icon: "arrow.triangle.pull",
                isEnabled: { $0.state?.selectedThreadID != nil }
            ) { context in
                context.workspace?.chat.details.run(.createPullRequest)
            },
        ]
    }
}
