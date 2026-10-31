import AppKit
import SopranoAgentsCore

/// Timeline module: find in thread, jump to latest, expand/collapse the work log.
@MainActor
enum TimelineCommands {
    /// `!terminalFocus`.
    private static let notTerminal = FocusRegion.outsideTerminal

    static var all: [AppCommand] {
        [
            AppCommand(
                id: "chat.find",
                title: "Find in Thread",
                description: "Search text in the conversation",
                category: .thread,
                // The right panel has its own ⌘F (`rightPanel.find`), which falls back to this.
                scopes: [.sidebar, .timeline, .composer],
                defaultKeys: ["cmd+f"],
                icon: "magnifyingglass",
                isEnabled: { hasThread($0) },
                perform: { timeline(in: $0)?.showFind() }
            ),
            AppCommand(
                id: "timeline.jumpToLatest",
                title: "Jump to Latest",
                description: "Scroll to the newest message",
                category: .navigation,
                scopes: [.timeline],
                defaultKeys: ["cmd+down"],
                icon: "arrow.down.to.line",
                isEnabled: { hasThread($0) },
                perform: { timeline(in: $0)?.jumpToLatest() }
            ),
            AppCommand(
                id: "timeline.expandAll",
                title: "Expand All Work",
                description: "Open every tool call and step",
                category: .thread,
                icon: "chevron.down",
                isEnabled: { hasThread($0) },
                perform: { timeline(in: $0)?.expandAll() }
            ),
            AppCommand(
                id: "timeline.collapseAll",
                title: "Collapse All Work",
                description: "Fold every tool call and step",
                category: .thread,
                icon: "chevron.right",
                isEnabled: { hasThread($0) },
                perform: { timeline(in: $0)?.collapseAll() }
            ),
        ]
    }

    private static func timeline(in context: CommandContext) -> TimelineViewController? {
        context.workspace?.chat.timeline
    }

    private static func hasThread(_ context: CommandContext) -> Bool {
        context.state?.selectedThreadID != nil
    }
}
