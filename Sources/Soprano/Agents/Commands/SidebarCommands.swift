import AppKit
import SopranoAgentsCore

/// Sidebar module: new thread, thread navigation (⇧⌘[ ⇧⌘] ⌘1–9), settle, pin, rename, archive,
/// delete, copy reference, add project, search, project filter.
@MainActor
enum SidebarCommands {
    /// T3 Code's `!terminalFocus`.
    private static let notTerminal: Set<FocusRegion> = [.sidebar, .timeline, .composer, .rightPanel]

    static var all: [AppCommand] {
        var commands: [AppCommand] = [
            AppCommand(
                id: "chat.new",
                title: "New Thread",
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
                category: .thread,
                scopes: notTerminal,
                defaultKeys: ["cmd+ctrl+n"],
                icon: Icon.squarePen
            ) { context in
                guard let state = context.state else { return }
                ThreadActions.newDraft(projectID: nil, state: state)
            },
            AppCommand(
                id: "project.add",
                title: "Add Project…",
                category: .project,
                icon: Icon.folderPlus
            ) { context in
                context.workspace?.sidebar.addProject()
            },
            AppCommand(
                id: "thread.previous",
                title: "Previous Thread",
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
                category: .navigation,
                defaultKeys: ["cmd+\(position)"],
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
