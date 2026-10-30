import AppKit
import SopranoAgentsCore

/// The chat column: header on top, timeline below it, the composer floating over the timeline's
/// bottom, the terminal drawer under both, and the Thread details card floating top-right.
///
/// ```
/// ┌ header 52 ────────────────────────────── [details][terminal][right panel] ┐
/// │ timeline (centered lane ≤ 736)                           ┌ details 280 ┐  │
/// │                                                          └─────────────┘  │
/// │            ┌ composer (overlay, ≤ 736, bottom gap 20) ┐                   │
/// ├ terminal drawer (optional, default 280, resizable) ───────────────────────┤
/// ```
/// Drafts center the composer vertically; the composer draws the hero headline above itself.
@MainActor
final class ChatViewController: NSViewController {
    let engine: AgentEngine
    let state: WorkspaceState

    let header: ChatHeaderView
    let timeline: TimelineViewController
    let composer: ComposerViewController
    let terminal: TerminalDrawerViewController
    let details: ThreadDetailsCardController

    private var terminalHeight: NSLayoutConstraint?
    /// Composer pinned above the drawer (threads) or vertically centered (draft hero).
    private var composerBottom: NSLayoutConstraint?
    private var composerCentered: NSLayoutConstraint?
    private var composerHeight: CGFloat = 120

    /// Height of the terminal drawer when open. The drawer's resize handle sets it.
    var terminalDrawerHeight: CGFloat = Metrics.terminalHeight {
        didSet { updatePanels() }
    }

    init(engine: AgentEngine, state: WorkspaceState) {
        self.engine = engine
        self.state = state
        header = ChatHeaderView(engine: engine, state: state)
        timeline = TimelineViewController(engine: engine, state: state)
        composer = ComposerViewController(engine: engine, state: state)
        terminal = TerminalDrawerViewController(engine: engine, state: state)
        details = ThreadDetailsCardController(engine: engine, state: state)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = ChatColumnView(frame: NSRect(x: 0, y: 0, width: 800, height: 700))
        view = root

        for child in [timeline, composer, terminal, details] as [NSViewController] {
            addChild(child)
        }

        let timelineView = timeline.view
        let composerView = composer.view
        let terminalView = terminal.view
        let detailsView = details.view
        for subview in [timelineView, header, terminalView, composerView, detailsView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }

        let terminalHeight = terminalView.heightAnchor.constraint(equalToConstant: 0)
        self.terminalHeight = terminalHeight
        // Centered and capped at the chat lane width, keeping the page gutter. Below the
        // window-size priority so a narrow column shrinks the composer instead of growing the window.
        let composerWidth = composerView.widthAnchor.constraint(equalToConstant: Metrics.chatMaxWidth)
        composerWidth.priority = .dragThatCannotResizeWindow
        let composerBottom = composerView.bottomAnchor.constraint(equalTo: terminalView.topAnchor, constant: -Metrics.gutter)
        let composerCentered = composerView.centerYAnchor.constraint(equalTo: timelineView.centerYAnchor)
        self.composerBottom = composerBottom
        self.composerCentered = composerCentered

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Metrics.topbarHeight),

            timelineView.topAnchor.constraint(equalTo: header.bottomAnchor),
            timelineView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            timelineView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            timelineView.bottomAnchor.constraint(equalTo: terminalView.topAnchor),

            terminalView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            terminalHeight,

            composerView.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            composerWidth,
            composerView.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: Metrics.gutter),
            composerView.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -Metrics.gutter),
            composerView.bottomAnchor.constraint(lessThanOrEqualTo: terminalView.topAnchor, constant: -Metrics.gutter),

            detailsView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            detailsView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            detailsView.widthAnchor.constraint(equalToConstant: Metrics.threadDetailsWidth),
        ])

        composer.onHeightChange = { [weak self] height in
            guard let self else { return }
            composerHeight = height
            timeline.bottomInset = height + Metrics.gutter * 2
        }
        timeline.bottomInset = composerHeight + Metrics.gutter * 2

        state.addObserver(self) { [weak self] change in
            switch change {
            case .panels: self?.updatePanels()
            case .selection: self?.updateComposerPlacement()
            case .filter, .composerRestore: break
            }
        }
        updatePanels()
        updateComposerPlacement()
    }

    private func updateComposerPlacement() {
        composerBottom?.isActive = !state.isDraft
        composerCentered?.isActive = state.isDraft
    }

    private func updatePanels() {
        terminalHeight?.constant = state.isTerminalVisible ? terminalDrawerHeight : 0
        terminal.view.isHidden = !state.isTerminalVisible
        details.view.isHidden = !state.isThreadDetailsVisible
    }
}

/// Background of the chat column (`bg-background`).
final class ChatColumnView: PaletteView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.background.cgColor
    }
}
