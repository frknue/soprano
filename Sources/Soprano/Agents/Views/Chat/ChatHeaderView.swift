import AppKit
import SopranoAgentsCore

/// Sidebar slice: the 52 pt chat header (project / thread title breadcrumb with rename and the
/// thread action menu) plus the fixed title-bar toggles (thread details, terminal, right panel).
@MainActor
final class ChatHeaderView: PaletteView {
    let engine: AgentEngine
    let state: WorkspaceState

    init(engine: AgentEngine, state: WorkspaceState) {
        self.engine = engine
        self.state = state
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: Metrics.topbarHeight))
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.background.cgColor
    }
}
