import Foundation

/// A logical terminal window containing its own tiled pane layout.
final class WorkspaceWindowState: Identifiable {
    let id: String
    var title: String
    var isTitleCustom: Bool
    var layout: SplitNode?
    var activePaneId: String

    init(
        id: String,
        title: String,
        isTitleCustom: Bool = false,
        layout: SplitNode?,
        activePaneId: String
    ) {
        self.id = id
        self.title = title
        self.isTitleCustom = isTitleCustom
        self.layout = layout
        self.activePaneId = activePaneId
    }

    var paneIds: Set<String> {
        layout?.leafIds ?? []
    }
}
