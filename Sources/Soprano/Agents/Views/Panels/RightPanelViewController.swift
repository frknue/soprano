import AppKit
import SopranoAgentsCore

/// The right panel (`RightPanelTabs.tsx`): a 52 pt tab strip level with the chat header (the
/// "Diff" tab, Maximize/Restore panel, Close panel) over the active surface. Diff is the only
/// surface this app has.
@MainActor
final class RightPanelViewController: NSViewController, FocusRegionController {
    let engine: AgentEngine
    let state: WorkspaceState
    let diff: DiffSurfaceViewController

    private let tabBar = RightPanelTabBar()

    init(engine: AgentEngine, state: WorkspaceState) {
        self.engine = engine
        self.state = state
        diff = DiffSurfaceViewController(engine: engine, state: state)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = RightPanelRootView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view = root
        addChild(diff)
        let surface = diff.view
        for subview in [tabBar, surface] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: root.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: Metrics.topbarHeight),

            surface.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            surface.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        tabBar.onActivateDiff = { [weak self] in self?.state.showRightPanel(.diff) }
        tabBar.onClose = { [weak self] in self?.state.setRightPanelVisible(false) }
        tabBar.onToggleMaximized = { [weak self] in
            guard let self else { return }
            state.setRightPanelMaximized(!state.isRightPanelMaximized)
        }
        state.addObserver(self) { [weak self] change in
            if change == .panels { self?.updateTabBar() }
        }
        updateTabBar()
    }

    private func updateTabBar() {
        tabBar.isMaximized = state.isRightPanelMaximized
        tabBar.activeSurface = state.rightPanelSurface
    }

    // MARK: FocusRegionController

    var focusRegion: FocusRegion { .rightPanel }
    var focusRootView: NSView { view }

    func takeFocus() {
        diff.focusList()
    }
}

final class RightPanelRootView: PaletteView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.background.cgColor
    }
}

/// The tab strip: tabs left (`h-6 rounded-md pl-1.5 pr-2 text-xs`, active `bg-accent`), panel
/// controls right.
final class RightPanelTabBar: PaletteView {
    var onActivateDiff: (() -> Void)?
    var onClose: (() -> Void)?
    var onToggleMaximized: (() -> Void)?

    var isMaximized = false {
        didSet {
            maximizeButton.setSymbol(isMaximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", size: 12)
            let title = isMaximized ? "Restore panel size" : "Maximize panel"
            maximizeButton.toolTip = title
            maximizeButton.setAccessibilityLabel(title)
        }
    }

    var activeSurface: WorkspaceState.RightPanelSurface = .diff {
        didSet { diffTab.isActive = activeSurface == .diff }
    }

    private let diffTab = RightPanelTab(title: WorkspaceState.RightPanelSurface.diff.title, symbol: diffGlyph)
    private let maximizeButton = GhostIconButton(symbol: "arrow.up.left.and.arrow.down.right", symbolSize: 12, toolTip: "Maximize panel")
    private let closeButton = GhostIconButton(symbol: "xmark", symbolSize: 12, toolTip: "Close panel")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [diffTab, spacer, maximizeButton, closeButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        diffTab.onClick = { [weak self] in self?.onActivateDiff?() }
        diffTab.onClose = { [weak self] in self?.onClose?() }
        maximizeButton.onClick = { [weak self] in self?.onToggleMaximized?() }
        closeButton.onClick = { [weak self] in self?.onClose?() }
        diffTab.isActive = true
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.background.cgColor
    }
}

/// One right-panel tab: 12 pt glyph and title, close ✕ on hover.
final class RightPanelTab: InteractiveView {
    var onClose: (() -> Void)?
    var isActive = false {
        didSet { applyPalette(palette) }
    }

    private let icon = NSImageView()
    private let label = NSTextField.label(size: Typography.smallSize)
    private let close = GhostIconButton(symbol: "xmark", size: 16, symbolSize: 8, toolTip: "Close tab")

    init(title: String, symbol: String) {
        super.init(frame: .zero)
        layer?.cornerRadius = Radius.md
        icon.image = NSImage.symbol(symbol, size: 11)
        icon.imageScaling = .scaleNone
        label.stringValue = title
        let stack = NSStackView(views: [icon, label, close])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 24),
        ])
        close.onClick = { [weak self] in self?.onClose?() }
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(title)
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = (isActive ? palette.accent : isHovered ? palette.accent.fading(0.6) : .clear).cgColor
        let text = isActive || isHovered ? palette.foreground : palette.mutedForeground
        label.textColor = text
        icon.contentTintColor = text
        close.alphaValue = isActive || isHovered ? 1 : 0
    }
}
