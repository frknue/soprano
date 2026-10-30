import AppKit
import SopranoAgentsCore

/// Panels slice: the right panel (Diff surface: scope picker, file tree, stacked/split diff).
@MainActor
final class RightPanelViewController: NSViewController {
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
