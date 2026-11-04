import AppKit
import SopranoAgentsCore

/// Panels module: diff and files toggles, right-panel tabs, diff view options, terminal
/// new/close (drawer or panel tab, whichever has focus), open in editor, git actions.
@MainActor
enum PanelCommands {
    private static let notTerminal = FocusRegion.outsideTerminal

    static var all: [AppCommand] {
        [
            AppCommand(
                id: "diff.toggle",
                title: "Toggle Diff",
                description: "Show or hide the changes panel",
                category: .diff,
                scopes: notTerminal,
                defaultKeys: ["cmd+d"],
                icon: Icon.fileDiff
            ) { context in
                guard let state = context.state else { return }
                if !state.isStatisticsVisible && state.isRightPanelVisible && state.rightPanelSurface == .diff {
                    state.setRightPanelVisible(false)
                } else {
                    state.showRightPanel(.diff)
                }
            },
            AppCommand(
                id: "diff.toggleLayout",
                title: "Toggle Split Diff View",
                description: "Switch between unified and side-by-side diff",
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
                description: "Show or hide the changed files list",
                category: .diff,
                icon: "list.bullet.indent"
            ) { context in
                guard let state = context.state, let diff = context.workspace?.rightPanel.diff else { return }
                state.showRightPanel(.diff)
                diff.toggleFileTree()
            },
            AppCommand(
                id: "files.toggle",
                title: "Toggle Files",
                description: "Show or hide the project file browser",
                category: .view,
                scopes: notTerminal,
                defaultKeys: ["cmd+shift+f"],
                icon: Icon.files,
                isEnabled: { $0.state?.workspace != nil }
            ) { context in
                guard let state = context.state else { return }
                if !state.isStatisticsVisible && state.isRightPanelVisible && state.rightPanelSurface == .files {
                    state.setRightPanelVisible(false)
                } else {
                    context.workspace?.rightPanel.open(.files)
                }
            },
            AppCommand(
                id: "files.search",
                title: "Search Files",
                description: "Find a file in the project by name",
                category: .view,
                icon: "magnifyingglass",
                isEnabled: { $0.state?.workspace != nil }
            ) { context in
                guard let panel = context.workspace?.rightPanel else { return }
                panel.open(.files)
                panel.files.focusSearch()
            },
            AppCommand(
                id: "rightPanel.newTerminal",
                title: "New Terminal in Right Panel",
                description: "Open a terminal tab in the right panel",
                category: .terminal,
                defaultKeys: ["cmd+shift+j"],
                icon: Icon.terminal,
                isEnabled: { $0.state?.workspace != nil }
            ) { context in
                context.workspace?.rightPanel.newTerminal()
            },
            AppCommand(
                id: "rightPanel.closeTab",
                title: "Close Tab",
                description: "Close the active right panel tab",
                category: .view,
                scopes: [.rightPanel],
                defaultKeys: ["cmd+w"],
                icon: "xmark",
                isEnabled: { $0.state?.isRightPanelVisible == true && $0.state?.rightPanelSurface != nil }
            ) { context in
                context.workspace?.rightPanel.closeActiveTab()
            },
            AppCommand(
                id: "rightPanel.find",
                title: "Find in Panel",
                description: "Search the open file, files or thread",
                category: .view,
                scopes: [.rightPanel],
                defaultKeys: ["cmd+f"],
                icon: "magnifyingglass",
                isEnabled: { $0.state?.workspace != nil }
            ) { context in
                // The open file's find bar, the Files search field, else Find in Thread.
                guard let workspace = context.workspace else { return }
                switch context.state?.rightPanelSurface {
                case .file where workspace.rightPanel.fileViewer.showFind():
                    return
                case .files:
                    workspace.rightPanel.files.focusSearch()
                default:
                    workspace.chat.timeline.showFind()
                }
            },
            AppCommand(
                id: "rightPanel.toggleMarkdownPreview",
                title: "Toggle Markdown Preview",
                description: "Switch a Markdown file tab between the reader and its source",
                category: .view,
                scopes: [.rightPanel],
                defaultKeys: ["cmd+shift+v"],
                icon: "eye",
                isEnabled: { $0.workspace?.rightPanel.fileViewer.showsMarkdownFile == true }
            ) { context in
                context.workspace?.rightPanel.fileViewer.toggleMarkdownPreview()
            },
            AppCommand(
                id: "rightPanel.toggleMaximized",
                title: "Maximize Right Panel",
                description: "Expand the right panel or restore its size",
                category: .view,
                icon: "arrow.up.left.and.arrow.down.right",
                isEnabled: { $0.state?.isRightPanelVisible == true }
            ) { context in
                guard let state = context.state else { return }
                if state.isStatisticsVisible {
                    // Under the board: show the panel maximized.
                    state.setRightPanelVisible(true)
                    state.setRightPanelMaximized(true)
                } else {
                    state.setRightPanelMaximized(!state.isRightPanelMaximized)
                }
            },
            AppCommand(
                id: "terminal.new",
                title: "New Terminal",
                description: "Open another terminal session",
                category: .terminal,
                scopes: [.terminal],
                defaultKeys: ["cmd+n"],
                icon: Icon.terminal,
                isEnabled: { $0.state?.workspace != nil }
            ) { context in
                guard let workspace = context.workspace else { return }
                if workspace.rightPanel.ownsFirstResponder {
                    workspace.rightPanel.newTerminal()
                } else {
                    workspace.chat.terminal.newTerminal()
                }
            },
            AppCommand(
                id: "terminal.close",
                title: "Close Terminal",
                description: "Close the active terminal session",
                category: .terminal,
                scopes: [.terminal],
                defaultKeys: ["cmd+w"],
                icon: "trash",
                isEnabled: { $0.state?.workspace != nil }
            ) { context in
                guard let workspace = context.workspace else { return }
                if workspace.rightPanel.ownsFirstResponder {
                    workspace.rightPanel.closeActiveTab()
                } else {
                    workspace.chat.terminal.closeActiveTerminal()
                }
            },
            AppCommand(
                id: "editor.openFavorite",
                title: "Open in Editor",
                description: "Open the working folder in your editor",
                category: .project,
                defaultKeys: ["cmd+o"],
                icon: "arrow.up.forward.app",
                isEnabled: { $0.workspace?.chat.details.workingDirectory != nil }
            ) { context in
                context.workspace?.chat.details.openInEditor()
            },
            AppCommand(
                id: "git.openInSopranoGit",
                title: "Open in Soprano Git",
                description: "Open the workspace's Git repository in Soprano Git",
                category: .project,
                defaultKeys: ["prefix+g"],
                icon: "arrow.triangle.branch",
                isEnabled: { context in
                    context.state?.workspace.flatMap { context.engine?.workingDirectory(of: $0) } != nil
                }
            ) { context in
                guard let engine = context.engine, let ref = context.state?.workspace else { return }
                let window = context.window
                Task { await SopranoGitLauncher.open(ref, engine: engine, window: window) }
            },
            AppCommand(
                id: "git.commit",
                title: "Commit",
                description: "Commit the thread's changes",
                category: .project,
                icon: "checkmark.circle",
                isEnabled: { $0.state?.selectedThreadID != nil }
            ) { context in
                context.workspace?.chat.details.openCommitDialog()
            },
            AppCommand(
                id: "git.push",
                title: "Push",
                description: "Push the current branch to the remote",
                category: .project,
                icon: "icloud.and.arrow.up",
                isEnabled: { $0.state?.selectedThreadID != nil }
            ) { context in
                context.workspace?.chat.details.run(.push)
            },
            AppCommand(
                id: "git.createPR",
                title: "Create PR",
                description: "Open a pull request for the current branch",
                category: .project,
                icon: "arrow.triangle.pull",
                isEnabled: { $0.state?.selectedThreadID != nil }
            ) { context in
                context.workspace?.chat.details.run(.createPullRequest)
            },
        ]
    }
}
