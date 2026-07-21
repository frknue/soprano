import Foundation

/// A logical terminal window containing its own tiled pane layout.
final class WorkspaceWindowState: Identifiable {
    let id: String
    var title: String
    var layout: SplitNode?
    var activePaneId: String

    init(id: String, title: String, layout: SplitNode?, activePaneId: String) {
        self.id = id
        self.title = title
        self.layout = layout
        self.activePaneId = activePaneId
    }

    var paneIds: Set<String> {
        layout?.leafIds ?? []
    }
}
