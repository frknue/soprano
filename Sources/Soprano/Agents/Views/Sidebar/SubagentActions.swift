import AppKit
import SopranoAgentsCore

/// Subagent actions shared by the sidebar rows, the chat header and the composer: opening one,
/// stopping it, its action menu.
@MainActor
enum SubagentActions {
    static func open(threadID: String, subagentID: String, state: WorkspaceState) {
        state.select(.subagent(threadID: threadID, subagentID: subagentID))
    }

    /// Stops a running subagent; a refusal is shown as an alert.
    static func stop(threadID: String, subagentID: String, engine: AgentEngine, window: NSWindow?) {
        Task { @MainActor in
            do {
                try await engine.cancelSubagent(threadID, subagentID)
            } catch {
                let name = engine.subagent(threadID, subagentID)?.name ?? subagentID
                await Dialogs.alert(title: "Couldn’t stop \(name)", message: error.localizedDescription, in: window)
            }
        }
    }

    static func menu(threadID: String, subagentID: String, engine: AgentEngine, state: WorkspaceState, window: NSWindow?) -> NSMenu? {
        guard let thread = engine.thread(threadID), let subagent = thread.subagent(subagentID) else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        if state.selection != .subagent(threadID: threadID, subagentID: subagentID) {
            menu.addItem(ActionMenuItem("Open subagent", symbol: Icon.subagent) {
                open(threadID: threadID, subagentID: subagentID, state: state)
            })
        }
        menu.addItem(ActionMenuItem("Open \(thread.title)", symbol: SidebarSymbol.messageSquare) {
            ThreadActions.open(threadID, engine: engine, state: state)
        })
        let stopItem = ActionMenuItem("Stop subagent", symbol: Icon.stop) {
            stop(threadID: threadID, subagentID: subagentID, engine: engine, window: window)
        }
        stopItem.isEnabled = subagent.isRunning
        menu.addItem(stopItem)

        menu.addItem(.separator())
        let copyItem = NSMenuItem(title: "Copy", action: nil, keyEquivalent: "")
        copyItem.image = NSImage.symbol(Icon.copy, size: 13)
        let copyMenu = NSMenu()
        copyMenu.autoenablesItems = false
        copyMenu.addItem(ActionMenuItem("Name", symbol: SidebarSymbol.hash) { ThreadActions.copy(subagent.name) })
        if let assignment = subagent.assignment {
            copyMenu.addItem(ActionMenuItem("Assignment", symbol: SidebarSymbol.messageSquare) { ThreadActions.copy(assignment) })
        }
        if let file = subagent.sessionFile {
            copyMenu.addItem(ActionMenuItem("Transcript path", symbol: "doc.text") { ThreadActions.copy(file) })
        }
        copyItem.submenu = copyMenu
        menu.addItem(copyItem)
        return menu
    }
}
