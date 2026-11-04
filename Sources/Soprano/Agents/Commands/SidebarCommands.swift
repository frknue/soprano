import AppKit
import SopranoAgentsCore

/// Sidebar module: new thread, thread navigation (⇧⌘[ ⇧⌘] ⌃1–9), settle, pin, rename, archive,
/// delete, copy reference, add project, search, project filter.
@MainActor
enum SidebarCommands {
    /// `!terminalFocus`.
    private static let notTerminal = FocusRegion.outsideTerminal

    static var all: [AppCommand] {
        var commands: [AppCommand] = [
            AppCommand(
                id: "chat.new",
                title: "New Thread",
                description: "Start a new thread",
                category: .thread,
                scopes: notTerminal,
                defaultKeys: ["cmd+n", "cmd+shift+o"],
                icon: Icon.squarePen
            ) { context in
                guard let engine = context.engine, let state = context.state else { return }
                ThreadActions.newDraft(projectID: ThreadActions.currentProjectID(engine: engine, state: state), state: state)
            },
            AppCommand(
                id: "chat.newLocal",
                title: "New Thread in Current Project",
                description: "Start a thread in the current project",
                category: .thread,
                scopes: notTerminal,
                defaultKeys: ["cmd+shift+n"],
                icon: Icon.squarePen
            ) { context in
                guard let engine = context.engine, let state = context.state else { return }
                ThreadActions.newDraft(projectID: ThreadActions.currentProjectID(engine: engine, state: state), state: state)
            },
            AppCommand(
                id: "chat.newWithoutProject",
                title: "New Thread Without a Project",
                description: "Start a thread in a scratch folder",
                category: .thread,
                scopes: notTerminal,
                defaultKeys: ["cmd+ctrl+n"],
                icon: Icon.squarePen
            ) { context in
                guard let state = context.state else { return }
                ThreadActions.newDraft(projectID: nil, state: state)
            },
            AppCommand(
                id: "project.open",
                title: "Open Project…",
                description: "Start a thread in a project or a folder of your project directories",
                category: .project,
                defaultKeys: ["cmd+shift+k"],
                icon: Icon.folderPlus
            ) { context in
                CommandPalette.openProjects(in: context)
            },
            AppCommand(
                id: "thread.previous",
                title: "Previous Thread",
                description: "Select the thread above in the list",
                category: .navigation,
                defaultKeys: ["cmd+shift+["],
                icon: "chevron.up",
                inPalette: false,
                isEnabled: { !threadOrder($0).isEmpty }
            ) { context in
                context.workspace?.sidebar.selectAdjacent(-1)
            },
            AppCommand(
                id: "thread.next",
                title: "Next Thread",
                description: "Select the thread below in the list",
                category: .navigation,
                defaultKeys: ["cmd+shift+]"],
                icon: "chevron.down",
                inPalette: false,
                isEnabled: { !threadOrder($0).isEmpty }
            ) { context in
                context.workspace?.sidebar.selectAdjacent(1)
            },
            AppCommand(
                id: "thread.settle",
                title: "Settle Thread",
                description: "Mark the thread done or reopen it",
                category: .thread,
                scopes: notTerminal,
                defaultKeys: ["cmd+shift+s"],
                icon: Icon.circleCheck,
                isEnabled: { $0.thread != nil }
            ) { context in
                guard let engine = context.engine, let thread = context.thread else { return }
                ThreadActions.toggleSettled(thread.id, engine: engine)
            },
            AppCommand(
                id: "thread.pin",
                title: "Pin Thread",
                description: "Keep the thread at the top of the list",
                category: .thread,
                scopes: notTerminal,
                defaultKeys: ["cmd+shift+p"],
                icon: Icon.pin,
                isEnabled: { $0.thread != nil }
            ) { context in
                guard let engine = context.engine, let thread = context.thread else { return }
                ThreadActions.togglePinned(thread.id, engine: engine)
            },
            // F2 in the sidebar list renames too (the list handles it: KeyChord has no function keys).
            AppCommand(
                id: "thread.rename",
                title: "Rename Thread",
                description: "Change the thread's name",
                category: .thread,
                scopes: [.sidebar],
                icon: SidebarSymbol.pencil,
                isEnabled: { $0.thread != nil }
            ) { context in
                guard let thread = context.thread, let workspace = context.workspace else { return }
                if workspace.state.isSidebarVisible {
                    workspace.sidebar.beginRename(thread.id)
                } else {
                    workspace.chat.header.beginRename()
                }
            },
            AppCommand(
                id: "thread.archive",
                title: "Archive Thread",
                description: "Hide the thread from the list",
                category: .thread,
                icon: SidebarSymbol.archive,
                isEnabled: { $0.thread.map { !$0.isRunning } ?? false }
            ) { context in
                guard let engine = context.engine, let state = context.state, let thread = context.thread else { return }
                ThreadActions.archive(thread.id, engine: engine, state: state)
            },
            AppCommand(
                id: "thread.delete",
                title: "Delete Thread",
                description: "Remove the thread permanently",
                category: .thread,
                icon: SidebarSymbol.trash,
                isEnabled: { $0.thread != nil }
            ) { context in
                guard let engine = context.engine, let state = context.state, let thread = context.thread else { return }
                ThreadActions.delete(thread.id, engine: engine, state: state, window: context.window)
            },
            AppCommand(
                id: "thread.copyReference",
                title: "Copy Thread Reference",
                description: "Copy a link to this thread",
                category: .thread,
                scopes: notTerminal,
                defaultKeys: ["cmd+shift+c"],
                icon: Icon.copy,
                isEnabled: { $0.thread != nil }
            ) { context in
                guard let thread = context.thread else { return }
                ThreadActions.copy(ThreadActions.reference(for: thread))
            },
            AppCommand(
                id: "sidebar.search",
                title: "Search Threads",
                description: "Search threads by name",
                category: .navigation,
                icon: Icon.search
            ) { context in
                guard let workspace = context.workspace else { return }
                workspace.state.setSidebarVisible(true)
                workspace.sidebar.focusSearch()
            },
            AppCommand(
                id: "sidebar.filterProjects",
                title: "Filter Threads by Project",
                description: "Show only threads from chosen projects",
                category: .navigation,
                icon: Icon.listFilter,
                isEnabled: { !($0.engine?.projects.isEmpty ?? true) }
            ) { context in
                guard let workspace = context.workspace else { return }
                workspace.state.setSidebarVisible(true)
                workspace.view.layoutSubtreeIfNeeded()
                workspace.sidebar.toggleProjectFilter()
            },
        ]
        for position in 1...9 {
            commands.append(AppCommand(
                id: "thread.jump.\(position)",
                title: "Go to Thread \(position)",
                description: "Select the thread at this position",
                category: .navigation,
                defaultKeys: ["ctrl+\(position)"],
                icon: "number",
                inPalette: false,
                isEnabled: { threadOrder($0).count >= position }
            ) { context in
                context.workspace?.sidebar.jump(to: position)
            })
        }
        return commands
    }

    private static func threadOrder(_ context: CommandContext) -> [String] {
        context.workspace?.sidebar.threadOrder ?? []
    }
}
