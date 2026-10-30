import AppKit
import SopranoAgentsCore

/// Timeline module: find in thread, jump to latest, expand/collapse the work log.
@MainActor
enum TimelineCommands {
    /// T3 Code's `!terminalFocus`.
    private static let notTerminal: Set<FocusRegion> = [.sidebar, .timeline, .composer, .rightPanel]

    static var all: [AppCommand] {
        [
            AppCommand(
                id: "chat.find",
                title: "Find in Thread",
                category: .thread,
                scopes: notTerminal,
                defaultKeys: ["cmd+f"],
                icon: "magnifyingglass",
                isEnabled: { hasThread($0) },
                perform: { timeline(in: $0)?.showFind() }
            ),
            AppCommand(
                id: "timeline.jumpToLatest",
                title: "Jump to Latest",
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
                category: .thread,
                icon: "chevron.down",
                isEnabled: { hasThread($0) },
                perform: { timeline(in: $0)?.expandAll() }
            ),
            AppCommand(
                id: "timeline.collapseAll",
                title: "Collapse All Work",
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
