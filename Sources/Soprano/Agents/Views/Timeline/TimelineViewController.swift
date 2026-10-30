import AppKit
import SopranoAgentsCore

/// Timeline slice: the selected thread's messages, work groups and cards in the centered chat lane.
@MainActor
final class TimelineViewController: NSViewController {
    let engine: AgentEngine
    let state: WorkspaceState

    /// Space at the bottom the floating composer covers; the timeline pads its content by it.
    var bottomInset: CGFloat = 0

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
