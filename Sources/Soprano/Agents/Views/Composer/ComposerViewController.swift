import AppKit
import SopranoAgentsCore

/// Composer slice: the floating composer (editor, attachments, model/effort/permissions chips, send/stop) and the draft context strip.
@MainActor
final class ComposerViewController: NSViewController {
    let engine: AgentEngine
    let state: WorkspaceState

    /// Called when the composer's height changes so the container can re-pin it and pad the timeline.
    var onHeightChange: ((CGFloat) -> Void)?

    /// Moves keyboard focus into the editor.
    func focusEditor() {}

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
