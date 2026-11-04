import AppKit
import SopranoAgentsCore

/// Thread actions shared by the sidebar, the chat header and the commands: selection, the
/// thread action menu, delete and archive flows, copy.
@MainActor
enum ThreadActions {
    /// Opens a thread (also from one of its subagents). The sidebar marks every newly selected
    /// thread visited (clearing its Done / Failed pill); re-opening the open thread clears a pill
    /// it got meanwhile. Either way the statistics board closes (`WorkspaceState.select`).
    static func open(_ threadID: String, engine: AgentEngine, state: WorkspaceState) {
        let wasSelected = state.selection == .thread(threadID)
        state.select(.thread(threadID))
        guard wasSelected, let thread = engine.thread(threadID) else { return }
        let status = ThreadStatus.of(thread)
        if status == .done || status == .failed { engine.markVisited(threadID) }
    }

    /// New-thread draft in `projectID` (nil = without a project).
    static func newDraft(projectID: String?, state: WorkspaceState) {
        state.select(.draft(projectID: projectID))
    }

    /// The project a new thread starts in: the open thread's or draft's project, else the one
    /// the sidebar is filtered to, else the most recently active project.
    static func currentProjectID(engine: AgentEngine, state: WorkspaceState) -> String? {
        switch state.selection {
        case let .thread(id), let .subagent(id, _):
            if let projectID = engine.thread(id)?.projectID, engine.project(projectID) != nil { return projectID }
        case let .draft(projectID):
            if let projectID, engine.project(projectID) != nil { return projectID }
        }
        if state.projectFilter.count == 1, let only = state.projectFilter.first, engine.project(only) != nil { return only }
        let recent = engine.threads
            .filter { $0.archivedAt == nil && $0.projectID.flatMap(engine.project) != nil }
            .max { $0.activityDate < $1.activityDate }
        return recent?.projectID ?? engine.projects.first?.id
    }

    /// After the open thread goes away, show a draft in its project (an open statistics board
    /// stays).
    private static func leave(_ thread: AgentThread, state: WorkspaceState) {
        guard state.selectedThreadID == thread.id else { return }
        state.select(.draft(projectID: thread.projectID), closingOverlays: false)
    }

    static func archive(_ threadID: String, engine: AgentEngine, state: WorkspaceState) {
        guard let thread = engine.thread(threadID), !thread.isRunning else { return }
        engine.setArchived(threadID, true)
        leave(thread, state: state)
    }

    /// Confirms, then deletes.
    static func delete(_ threadID: String, engine: AgentEngine, state: WorkspaceState, window: NSWindow?) {
        guard let thread = engine.thread(threadID) else { return }
        Task { @MainActor in
            let confirmed = await Dialogs.confirm(
                title: "Delete thread \"\(thread.title)\"?",
                message: "This permanently clears conversation history for this thread.",
                confirmTitle: "Delete",
                isDestructive: true,
                in: window
            )
            guard confirmed else { return }
            leave(thread, state: state)
            await engine.deleteThread(threadID)
        }
    }

    static func toggleSettled(_ threadID: String, engine: AgentEngine) {
        guard let thread = engine.thread(threadID) else { return }
        engine.setSettled(threadID, thread.settledAt == nil)
    }

    static func togglePinned(_ threadID: String, engine: AgentEngine) {
        guard let thread = engine.thread(threadID) else { return }
        engine.setPinned(threadID, thread.pinnedAt == nil)
    }

    /// The text "Copy ▸ Thread" and ⇧⌘C put on the pasteboard: title and id.
    static func reference(for thread: AgentThread) -> String {
        "\(thread.title) (thread \(thread.id))"
    }

    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// The thread action menu, in display order. `rename` starts the inline rename of whichever
    /// surface opened the menu.
    static func menu(
        for threadID: String,
        engine: AgentEngine,
        state: WorkspaceState,
        window: NSWindow?,
        rename: @escaping @MainActor () -> Void
    ) -> NSMenu? {
        guard let thread = engine.thread(threadID) else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false

        if state.selectedThreadID == threadID,
           let controller = window?.windowController as? AgentsWindowController,
           CommandRegistry.shared.command("chat.find") != nil {
            menu.addItem(ActionMenuItem("Find in thread", symbol: SidebarSymbol.textSearch) {
                controller.perform("chat.find")
            })
        }
        let pinned = thread.pinnedAt != nil
        menu.addItem(ActionMenuItem(pinned ? "Unpin thread" : "Pin thread", symbol: pinned ? SidebarSymbol.pinOff : "pin") {
            engine.setPinned(threadID, !pinned)
        })
        let settled = thread.settledAt != nil
        menu.addItem(ActionMenuItem(settled ? "Un-settle thread" : "Settle thread", symbol: Icon.circleCheck) {
            engine.setSettled(threadID, !settled)
        })

        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Rename thread", symbol: SidebarSymbol.pencil, action: rename))
        let regenerating = thread.isGeneratingTitle
        let regenerate = ActionMenuItem(regenerating ? "Regenerating…" : "Regenerate title", symbol: SidebarSymbol.refresh) {
            Task { await engine.regenerateTitle(threadID) }
        }
        regenerate.isEnabled = !regenerating
        menu.addItem(regenerate)
        menu.addItem(ActionMenuItem("Mark unread", symbol: SidebarSymbol.mailOpen) {
            engine.markUnread(threadID)
        })
        if let project = engine.project(thread.projectID) {
            let filtering = !state.projectFilter.isEmpty
            menu.addItem(ActionMenuItem(filtering ? "Show all projects" : "Filter by \(project.title)", symbol: SidebarSymbol.folderTree) {
                state.setProjectFilter(filtering ? [] : [project.id])
            })
        }

        menu.addItem(.separator())
        let copyItem = NSMenuItem(title: "Copy", action: nil, keyEquivalent: "")
        copyItem.image = NSImage.symbol(Icon.copy, size: 13)
        let copyMenu = NSMenu()
        copyMenu.autoenablesItems = false
        let path = engine.workingDirectory(for: thread)
        copyMenu.addItem(ActionMenuItem("Path", symbol: "folder") { copy(path) })
        if let branch = thread.branch {
            copyMenu.addItem(ActionMenuItem("Branch", symbol: Icon.gitBranch) { copy(branch) })
        }
        copyMenu.addItem(ActionMenuItem("Thread", symbol: SidebarSymbol.messageSquare) {
            if let current = engine.thread(threadID) { copy(reference(for: current)) }
        })
        copyMenu.addItem(ActionMenuItem("Thread ID", symbol: SidebarSymbol.hash) { copy(threadID) })
        copyItem.submenu = copyMenu
        menu.addItem(copyItem)

        menu.addItem(.separator())
        let archive = ActionMenuItem("Archive thread", symbol: SidebarSymbol.archive) {
            ThreadActions.archive(threadID, engine: engine, state: state)
        }
        archive.isEnabled = !thread.isRunning
        menu.addItem(archive)
        let delete = ActionMenuItem("Delete", symbol: SidebarSymbol.trash) {
            ThreadActions.delete(threadID, engine: engine, state: state, window: window)
        }
        delete.attributedTitle = NSAttributedString(string: "Delete", attributes: [
            .foregroundColor: PaletteCenter.shared.palette.errorForeground,
            .font: NSFont.menuFont(ofSize: 0),
        ])
        menu.addItem(delete)
        return menu
    }
}

/// A menu item that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, symbol: String? = nil, action handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        if let symbol { image = NSImage.symbol(symbol, size: 13) }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() {
        let handler = handler
        MainActor.assumeIsolated { handler() }
    }
}
