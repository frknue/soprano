import AppKit
import SopranoAgentsCore

/// The window content: sidebar | chat column | right panel. The sidebar and the right panel are
/// resizable by dragging their inner edge; double-clicking the sidebar rail resets its width.
@MainActor
final class WorkspaceViewController: NSViewController {
    let engine: AgentEngine
    let state: WorkspaceState

    let sidebar: SidebarViewController
    let chat: ChatViewController
    let rightPanel: RightPanelViewController

    private var sidebarWidth: NSLayoutConstraint?
    private var rightPanelWidth: NSLayoutConstraint?
    private let defaults: UserDefaults

    private static let sidebarWidthKey = "SidebarWidth"
    private static let rightPanelWidthKey = "RightPanelWidth"

    init(engine: AgentEngine, state: WorkspaceState, defaults: UserDefaults = .standard) {
        self.engine = engine
        self.state = state
        self.defaults = defaults
        sidebar = SidebarViewController(engine: engine, state: state)
        chat = ChatViewController(engine: engine, state: state)
        // The panel's terminal tabs live in the drawer's store: one numbering, one set of shells.
        rightPanel = RightPanelViewController(engine: engine, state: state, terminals: chat.terminal.store)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = WorkspaceRootView(frame: NSRect(origin: .zero, size: Metrics.windowDefaultSize))
        view = root
        for child in [sidebar, chat, rightPanel] as [NSViewController] {
            addChild(child)
        }

        let sidebarView = sidebar.view
        let chatView = chat.view
        let panelView = rightPanel.view
        let sidebarRail = ResizeRail(axis: .vertical)
        let panelRail = ResizeRail(axis: .vertical)
        let sidebarEdge = HairlineView()
        let panelEdge = HairlineView()
        for subview in [sidebarView, chatView, panelView, sidebarEdge, panelEdge, sidebarRail, panelRail] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }

        let storedSidebar = defaults.double(forKey: Self.sidebarWidthKey)
        let storedPanel = defaults.double(forKey: Self.rightPanelWidthKey)
        let sidebarWidth = sidebarView.widthAnchor.constraint(equalToConstant: storedSidebar > 0 ? storedSidebar : Metrics.sidebarWidth)
        let rightPanelWidth = panelView.widthAnchor.constraint(equalToConstant: storedPanel > 0 ? storedPanel : Metrics.rightPanelWidth)
        self.sidebarWidth = sidebarWidth
        self.rightPanelWidth = rightPanelWidth

        let chatMinWidth = chatView.widthAnchor.constraint(greaterThanOrEqualToConstant: Metrics.rightPanelMinWidth)
        let chatTrailing = chatView.trailingAnchor.constraint(equalTo: panelEdge.leadingAnchor)

        NSLayoutConstraint.activate([
            sidebarView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebarView.topAnchor.constraint(equalTo: root.topAnchor),
            sidebarView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarWidth,

            sidebarEdge.leadingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            sidebarEdge.topAnchor.constraint(equalTo: root.topAnchor),
            sidebarEdge.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarEdge.widthAnchor.constraint(equalToConstant: 1),

            chatView.leadingAnchor.constraint(equalTo: sidebarEdge.trailingAnchor),
            chatView.topAnchor.constraint(equalTo: root.topAnchor),
            chatView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            chatTrailing,

            panelEdge.topAnchor.constraint(equalTo: root.topAnchor),
            panelEdge.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            panelEdge.widthAnchor.constraint(equalToConstant: 1),
            panelEdge.trailingAnchor.constraint(equalTo: panelView.leadingAnchor),

            panelView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            panelView.topAnchor.constraint(equalTo: root.topAnchor),
            panelView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            rightPanelWidth,

            sidebarRail.centerXAnchor.constraint(equalTo: sidebarEdge.centerXAnchor),
            sidebarRail.topAnchor.constraint(equalTo: root.topAnchor),
            sidebarRail.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarRail.widthAnchor.constraint(equalToConstant: 8),

            panelRail.centerXAnchor.constraint(equalTo: panelEdge.centerXAnchor),
            panelRail.topAnchor.constraint(equalTo: root.topAnchor),
            panelRail.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            panelRail.widthAnchor.constraint(equalToConstant: 8),

            chatMinWidth,
        ])
        self.chatMinWidth = chatMinWidth
        self.chatTrailing = chatTrailing
        maximizedPanelLeading = panelView.leadingAnchor.constraint(equalTo: sidebarEdge.trailingAnchor, constant: 1)
        // The hidden chat column keeps a sane width under the maximized panel.
        maximizedChatWidth = chatView.widthAnchor.constraint(equalToConstant: Metrics.mainMinWidth)

        sidebarRail.onDrag = { [weak self] delta in self?.resizeSidebar(by: delta) }
        sidebarRail.onDoubleClick = { [weak self] in self?.setSidebarWidth(Metrics.sidebarWidth) }
        panelRail.onDrag = { [weak self] delta in self?.resizeRightPanel(by: -delta) }

        self.sidebarEdgeView = sidebarEdge
        self.panelEdgeView = panelEdge
        self.sidebarRailView = sidebarRail
        self.panelRailView = panelRail

        state.addObserver(self) { [weak self] change in
            if change == .panels { self?.updateVisibility() }
        }
        updateVisibility()
    }

    private weak var sidebarEdgeView: NSView?
    private weak var panelEdgeView: NSView?
    private weak var sidebarRailView: NSView?
    private weak var panelRailView: NSView?
    private var storedSidebarWidth: CGFloat?
    private var storedPanelWidth: CGFloat?
    /// Maximized right panel: it pins its leading edge next to the sidebar and the hidden chat
    /// column detaches from it, keeping a fixed width underneath.
    private var chatMinWidth: NSLayoutConstraint?
    private var chatTrailing: NSLayoutConstraint?
    private var maximizedPanelLeading: NSLayoutConstraint?
    private var maximizedChatWidth: NSLayoutConstraint?

    private func updateVisibility() {
        let showSidebar = state.isSidebarVisible
        if showSidebar {
            if let stored = storedSidebarWidth { sidebarWidth?.constant = stored }
            storedSidebarWidth = nil
        } else if storedSidebarWidth == nil {
            storedSidebarWidth = sidebarWidth?.constant
            sidebarWidth?.constant = 0
        }
        sidebar.view.isHidden = !showSidebar
        sidebarEdgeView?.isHidden = !showSidebar
        sidebarRailView?.isHidden = !showSidebar

        let showPanel = state.isRightPanelVisible
        if showPanel {
            if let stored = storedPanelWidth { rightPanelWidth?.constant = stored }
            storedPanelWidth = nil
        } else if storedPanelWidth == nil {
            storedPanelWidth = rightPanelWidth?.constant
            rightPanelWidth?.constant = 0
        }
        rightPanel.view.isHidden = !showPanel
        panelEdgeView?.isHidden = !showPanel

        let maximized = showPanel && state.isRightPanelMaximized
        if maximized {
            NSLayoutConstraint.deactivate([chatMinWidth, chatTrailing, rightPanelWidth].compactMap { $0 })
            NSLayoutConstraint.activate([maximizedPanelLeading, maximizedChatWidth].compactMap { $0 })
        } else {
            NSLayoutConstraint.deactivate([maximizedPanelLeading, maximizedChatWidth].compactMap { $0 })
            NSLayoutConstraint.activate([chatMinWidth, chatTrailing, rightPanelWidth].compactMap { $0 })
        }
        chat.view.isHidden = maximized
        panelRailView?.isHidden = !showPanel || maximized
    }

    private func resizeSidebar(by delta: CGFloat) {
        guard let current = sidebarWidth?.constant else { return }
        setSidebarWidth(current + delta)
    }

    private func setSidebarWidth(_ width: CGFloat) {
        let maximum = max(Metrics.sidebarMinWidth, view.bounds.width - Metrics.mainMinWidth)
        let clamped = min(max(width, Metrics.sidebarMinWidth), maximum)
        sidebarWidth?.constant = clamped
        defaults.set(Double(clamped), forKey: Self.sidebarWidthKey)
    }

    private func resizeRightPanel(by delta: CGFloat) {
        guard let current = rightPanelWidth?.constant else { return }
        let maximum = min(view.bounds.width * 0.7, view.bounds.width - Metrics.rightPanelMinWidth)
        let clamped = min(max(current + delta, Metrics.rightPanelMinWidth), max(Metrics.rightPanelMinWidth, maximum))
        rightPanelWidth?.constant = clamped
        defaults.set(Double(clamped), forKey: Self.rightPanelWidthKey)
    }
}

final class WorkspaceRootView: PaletteView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.background.cgColor
    }
}

/// 1 pt `border` line between regions.
final class HairlineView: PaletteView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.border.cgColor
    }
}

/// Invisible drag handle over a region edge.
final class ResizeRail: NSView {
    enum Axis { case vertical, horizontal }

    let axis: Axis
    var onDrag: ((CGFloat) -> Void)?
    var onDoubleClick: (() -> Void)?
    private var lastPoint: NSPoint?

    init(axis: Axis) {
        self.axis = axis
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: axis == .vertical ? .resizeLeftRight : .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        lastPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let last = lastPoint else { return }
        let point = event.locationInWindow
        onDrag?(axis == .vertical ? point.x - last.x : last.y - point.y)
        lastPoint = point
    }

    override func mouseUp(with event: NSEvent) {
        lastPoint = nil
    }
}
