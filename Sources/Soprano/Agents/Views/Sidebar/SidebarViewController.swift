import AppKit
import SopranoAgentsCore

/// Sidebar slice: thread inbox (search row, project filter, add project, new thread, Pinned/Active cards, Working/Settled shelves, footer).
@MainActor
final class SidebarViewController: NSViewController {
    let engine: AgentEngine
    let state: WorkspaceState

    init(engine: AgentEngine, state: WorkspaceState) {
        self.engine = engine
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        view = PaletteView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    }
}
