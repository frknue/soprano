import AppKit
import SopranoAgentsCore

/// The right panel: a 52 pt tab strip level with the chat header (the selected thread's tabs,
/// "+" to add a surface, Maximize/Restore panel, Close panel) over the active surface: Diff,
/// Files, a file, or a terminal. With every tab closed it shows the "Open a surface" launcher.
@MainActor
final class RightPanelViewController: NSViewController, FocusRegionController {
    /// What "+" and the launcher can add.
    enum SurfaceKind: CaseIterable {
        case terminal
        case files
        case diff

        var title: String {
            switch self {
            case .terminal: "Terminal"
            case .files: "Files"
            case .diff: "Diff"
            }
        }

        var symbol: String {
            switch self {
            case .terminal: Icon.terminal
            case .files: Icon.files
            case .diff: diffGlyph
            }
        }

        /// The launcher's single-key shortcut.
        var key: String {
            switch self {
            case .terminal: "T"
            case .files: "F"
            case .diff: "D"
            }
        }

        /// Terminal and Files need a folder: a thread's or a project draft's.
        var needsWorkspace: Bool { self != .diff }
    }

    let engine: AgentEngine
    let state: WorkspaceState
    /// The window's terminals, shared with the terminal drawer.
    let terminals: ThreadTerminalStore
    let diff: DiffSurfaceViewController
    let files: FilesSurfaceViewController
    let fileViewer: FileViewerViewController
    let terminal: TerminalSurfaceViewController

    private let tabBar = RightPanelTabBar()
    private let surfaceHost = NSView()
    private let launcher = RightPanelLauncher()

    /// Reports a workspace whose folder is gone (no terminal starts). Defaults to an alert
    /// over the window; tests replace it.
    lazy var reportMissingWorkspace: (_ path: String) -> Void = { [weak self] path in
        let window = self?.view.window
        Task { @MainActor in
            await Dialogs.alert(
                title: "Workspace not found",
                message: "\(path) doesn't exist, so no terminal was started. Restore the folder or start a new thread.",
                in: window
            )
        }
    }

    init(engine: AgentEngine, state: WorkspaceState, terminals: ThreadTerminalStore) {
        self.engine = engine
        self.state = state
        self.terminals = terminals
        diff = DiffSurfaceViewController(engine: engine, state: state)
        files = FilesSurfaceViewController(engine: engine, state: state)
        fileViewer = FileViewerViewController(engine: engine, state: state)
        terminal = TerminalSurfaceViewController(store: terminals)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var surfaceControllers: [NSViewController] { [diff, files, fileViewer, terminal] }

    override func loadView() {
        let root = RightPanelRootView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view = root
        for subview in [tabBar, surfaceHost] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: root.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: Metrics.topbarHeight),

            surfaceHost.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            surfaceHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            surfaceHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            surfaceHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        for controller in surfaceControllers {
            addChild(controller)
            pin(controller.view)
        }
        pin(launcher)

        tabBar.onActivate = { [weak self] surface in
            guard let self else { return }
            state.showRightPanel(surface)
            takeFocus()
        }
        tabBar.onCloseTab = { [weak self] surface in self?.close(surface) }
        tabBar.onAdd = { [weak self] kind in self?.open(kind) }
        tabBar.onClose = { [weak self] in self?.state.setRightPanelVisible(false) }
        tabBar.onToggleMaximized = { [weak self] in
            guard let self else { return }
            state.setRightPanelMaximized(!state.isRightPanelMaximized)
        }
        launcher.onChoose = { [weak self] kind in self?.open(kind) }
        files.onOpenFile = { [weak self] in self?.takeFocus() }

        state.addObserver(self) { [weak self] change in
            switch change {
            case .panels, .selection: self?.update()
            case .filter, .composerRestore: break
            }
        }
        terminals.addObserver(self) { [weak self] change in
            guard let self else { return }
            switch change {
            case let .sessions(key): closeEndedTerminalTabs(of: key)
            case .moved: update()
            }
        }
        engine.addObserver(self) { [weak self] event in
            guard let self, event == .threadListChanged || event == .projectsChanged else { return }
            state.pruneRightPanelTabs(keeping: engine.workspaceKeys)
        }
        update()
    }

    private func pin(_ subview: NSView) {
        subview.translatesAutoresizingMaskIntoConstraints = false
        surfaceHost.addSubview(subview)
        NSLayoutConstraint.activate([
            subview.topAnchor.constraint(equalTo: surfaceHost.topAnchor),
            subview.leadingAnchor.constraint(equalTo: surfaceHost.leadingAnchor),
            subview.trailingAnchor.constraint(equalTo: surfaceHost.trailingAnchor),
            subview.bottomAnchor.constraint(equalTo: surfaceHost.bottomAnchor),
        ])
    }

    // MARK: - State

    private func update() {
        guard isViewLoaded else { return }
        let active = state.rightPanelSurface
        tabBar.isMaximized = state.isRightPanelMaximized
        tabBar.update(
            items: state.rightPanelSurfaces.map { RightPanelTabBar.Item(surface: $0, title: title(for: $0), symbol: symbol(for: $0)) },
            active: active,
            canUseWorkspace: state.workspace != nil
        )
        var terminalID: String?
        var showsFile = false
        switch active {
        case let .terminal(id): terminalID = id
        case .file: showsFile = true
        case .diff, .files, nil: break
        }
        diff.view.isHidden = active != .diff
        files.view.isHidden = active != .files
        fileViewer.view.isHidden = !showsFile
        terminal.view.isHidden = terminalID == nil
        terminal.show(sessionID: terminalID)
        launcher.isHidden = active != nil
        launcher.canUseWorkspace = state.workspace != nil
    }

    private func title(for surface: WorkspaceState.RightPanelSurface) -> String {
        if case let .terminal(id) = surface, let session = terminals.session(id) {
            return session.info.title
        }
        return surface.title
    }

    private func symbol(for surface: WorkspaceState.RightPanelSurface) -> String {
        switch surface {
        case .diff: diffGlyph
        case .files: Icon.files
        case .file: Icon.fileText
        case .terminal: Icon.terminal
        }
    }

    /// A terminal that exited or was closed takes its tab with it, in whichever workspace it ran.
    private func closeEndedTerminalTabs(of key: String) {
        for case let .terminal(id) in state.rightPanelSurfaces(for: key) where terminals.session(id) == nil {
            state.closeRightPanelTab(.terminal(id), key: key)
        }
        update()
    }

    // MARK: - Actions

    /// "+" menu, launcher and commands: adds (or shows) a surface and focuses it.
    func open(_ kind: SurfaceKind) {
        switch kind {
        case .terminal:
            newTerminal()
            return
        case .files:
            guard state.workspace != nil else { return }
            state.showRightPanel(.files)
        case .diff:
            state.showRightPanel(.diff)
        }
        takeFocus()
    }

    /// Opens a new terminal tab of the selected workspace in its working directory.
    func newTerminal() {
        guard let workspace = state.workspace else { return }
        guard let session = terminals.create(in: workspace, placement: .panel) else {
            if let path = terminals.missingWorkspace(for: workspace) { reportMissingWorkspace(path) }
            return
        }
        state.showRightPanel(.terminal(session.id))
        terminal.focusTerminal()
    }

    /// Closes a tab; a terminal tab asks first, then ends its shell.
    func close(_ surface: WorkspaceState.RightPanelSurface) {
        let hadFocus = ownsFirstResponder
        guard case let .terminal(id) = surface else {
            state.closeRightPanelTab(surface)
            if hadFocus { takeFocus() }
            return
        }
        let title = title(for: surface)
        Task { @MainActor in
            let confirmed = await Dialogs.confirm(
                title: "Close terminal \"\(title)\"?",
                message: "This stops the running process and clears its history.",
                confirmTitle: "Close",
                isDestructive: true,
                in: view.window
            )
            guard confirmed else { return }
            terminals.close(id)
            if hadFocus { takeFocus() }
        }
    }

    /// "Close Tab" (⌘W in the right panel).
    func closeActiveTab() {
        guard let active = state.rightPanelSurface else { return }
        close(active)
    }

    /// Whether the keyboard focus is inside the panel (a panel terminal reports `.terminal`).
    var ownsFirstResponder: Bool {
        guard let responder = view.window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: view)
    }

    // MARK: FocusRegionController

    var focusRegion: FocusRegion { .rightPanel }
    var focusRootView: NSView { view }

    func takeFocus() {
        switch state.rightPanelSurface {
        case .diff: diff.focusList()
        case .files: files.focusTree()
        case .file: fileViewer.focusText()
        case .terminal: terminal.focusTerminal()
        case nil: view.window?.makeFirstResponder(launcher)
        }
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

/// The tab strip: tabs and "+" left (`h-6 rounded-md pl-1.5 pr-2 text-xs`, active `bg-accent`),
/// panel controls right. Tabs that don't fit scroll sideways (trackpad or wheel); "+" stays
/// right after them and the active tab is scrolled into view.
final class RightPanelTabBar: PaletteView {
    struct Item: Equatable {
        var surface: WorkspaceState.RightPanelSurface
        var title: String
        var symbol: String
    }

    var onActivate: ((WorkspaceState.RightPanelSurface) -> Void)?
    var onCloseTab: ((WorkspaceState.RightPanelSurface) -> Void)?
    var onAdd: ((RightPanelViewController.SurfaceKind) -> Void)?
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

    private var items: [Item] = []
    private var tabs: [RightPanelTab] = []
    private var canUseWorkspace = false
    private let tabStack = NSStackView()
    private let tabScroll = TabStripScrollView()
    private let addButton = GhostIconButton(symbol: "plus", size: 24, symbolSize: 12, toolTip: "Add panel surface")
    private let maximizeButton = GhostIconButton(symbol: "arrow.up.left.and.arrow.down.right", symbolSize: 12, toolTip: "Maximize panel")
    private let closeButton = GhostIconButton(symbol: "xmark", symbolSize: 12, toolTip: "Close panel")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        tabStack.orientation = .horizontal
        tabStack.alignment = .centerY
        tabStack.spacing = 4
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        tabStack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(tabStack)
        tabScroll.documentView = document
        tabScroll.drawsBackground = false
        tabScroll.hasHorizontalScroller = false
        tabScroll.hasVerticalScroller = false
        tabScroll.horizontalScrollElasticity = .allowed
        tabScroll.verticalScrollElasticity = .none
        tabScroll.automaticallyAdjustsContentInsets = false
        let clip = tabScroll.contentView
        let controls = NSStackView(views: [maximizeButton, closeButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 4
        for view in [tabScroll, addButton, controls] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        // Few tabs: the strip is as wide as its tabs; many: it shrinks to the room left and scrolls.
        let hugTabs = tabScroll.widthAnchor.constraint(equalTo: document.widthAnchor)
        hugTabs.priority = .defaultLow
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.heightAnchor.constraint(equalTo: clip.heightAnchor),
            tabStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            tabStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            tabStack.centerYAnchor.constraint(equalTo: document.centerYAnchor),

            tabScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            tabScroll.topAnchor.constraint(equalTo: topAnchor),
            tabScroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            tabScroll.widthAnchor.constraint(lessThanOrEqualTo: document.widthAnchor),
            hugTabs,
            addButton.leadingAnchor.constraint(equalTo: tabScroll.trailingAnchor, constant: 4),
            addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.trailingAnchor.constraint(lessThanOrEqualTo: controls.leadingAnchor, constant: -8),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            controls.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addButton.onClick = { [weak self] in self?.showAddMenu() }
        maximizeButton.onClick = { [weak self] in self?.onToggleMaximized?() }
        closeButton.onClick = { [weak self] in self?.onClose?() }
        applyPalette(palette)
    }

    func update(items: [Item], active: WorkspaceState.RightPanelSurface?, canUseWorkspace: Bool) {
        self.canUseWorkspace = canUseWorkspace
        if items != self.items {
            self.items = items
            for tab in tabs { tab.removeFromSuperview() }
            tabs = items.map { item in
                let tab = RightPanelTab(title: item.title, symbol: item.symbol)
                tab.onClick = { [weak self] in self?.onActivate?(item.surface) }
                tab.onClose = { [weak self] in self?.onCloseTab?(item.surface) }
                tabStack.addArrangedSubview(tab)
                return tab
            }
        }
        for (item, tab) in zip(items, tabs) {
            tab.isActive = item.surface == active
        }
        activeTab = items.firstIndex(where: { $0.surface == active }).map { tabs[$0] }
        revealActiveTab()
    }

    private weak var activeTab: RightPanelTab?
    private var revealedWidth: CGFloat = -1

    /// Scrolls the active tab into view (after a tab change and whenever the strip's width changes:
    /// the panel comes back, is maximized or resized).
    private func revealActiveTab() {
        layoutSubtreeIfNeeded()
        revealedWidth = tabScroll.bounds.width
        guard let tab = activeTab else { return }
        tab.scrollToVisible(tab.bounds.insetBy(dx: -8, dy: 0))
    }

    override func layout() {
        super.layout()
        if tabScroll.bounds.width != revealedWidth {
            DispatchQueue.main.async { [weak self] in self?.revealActiveTab() }
        }
    }

    /// Native menu under "+": Terminal, Files, Diff.
    private func showAddMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for kind in RightPanelViewController.SurfaceKind.allCases {
            let item = NSMenuItem(title: kind.title, action: #selector(addMenuItemChosen(_:)), keyEquivalent: "")
            item.target = self
            item.image = NSImage.symbol(kind.symbol, size: 12)
            item.representedObject = kind.title
            item.isEnabled = !kind.needsWorkspace || canUseWorkspace
            item.toolTip = item.isEnabled ? nil : RightPanelLauncher.noWorkspaceHint
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: addButton.bounds.maxY + 4), in: addButton)
    }

    @objc private func addMenuItemChosen(_ sender: NSMenuItem) {
        guard let kind = RightPanelViewController.SurfaceKind.allCases.first(where: { $0.title == sender.representedObject as? String }) else {
            return
        }
        onAdd?(kind)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.background.cgColor
    }
}

/// The tab strip's scroller: a vertical wheel scrolls it sideways (it has no vertical extent).
final class TabStripScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX), let document = documentView else {
            super.scrollWheel(with: event)
            return
        }
        let clip = contentView
        let maxX = max(0, document.frame.width - clip.bounds.width)
        // A notched wheel reports lines, a trackpad points (as `DiffTableView` does).
        let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 24)
        let x = min(max(0, clip.bounds.origin.x - delta), maxX)
        clip.scroll(to: NSPoint(x: x, y: clip.bounds.origin.y))
        reflectScrolledClipView(clip)
    }
}

/// One right-panel tab: 12 pt glyph and title (at most 160 pt, middle-truncated), close ✕ on hover.
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
        label.lineBreakMode = .byTruncatingMiddle
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
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 160),
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

/// "Open a surface": shown with every tab closed. One row per surface with its single-key
/// shortcut (T, F, D) that works while the launcher has the keyboard.
final class RightPanelLauncher: PaletteView {
    var onChoose: ((RightPanelViewController.SurfaceKind) -> Void)?

    /// Terminal and Files need a folder; in a projectless draft their rows are disabled.
    var canUseWorkspace = true {
        didSet {
            for (kind, row) in rows {
                row.isEnabled = !kind.needsWorkspace || canUseWorkspace
                row.toolTip = row.isEnabled ? nil : Self.noWorkspaceHint
            }
        }
    }

    /// Why Terminal and Files are off: a projectless draft has no folder until it starts.
    static let noWorkspaceHint = "Choose a project or start the thread first"

    private let titleLabel = NSTextField.label("Open a surface", size: Typography.rowSize, weight: .medium)
    private var rows: [(RightPanelViewController.SurfaceKind, RightPanelLauncherRow)] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.alignment = .center
        rows = RightPanelViewController.SurfaceKind.allCases.map { ($0, RightPanelLauncherRow(kind: $0)) }
        let stack = NSStackView(views: [titleLabel] + rows.map(\.1))
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 2
        stack.setCustomSpacing(12, after: titleLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -Metrics.topbarHeight / 2),
            stack.widthAnchor.constraint(equalToConstant: 280),
        ])
        for (kind, row) in rows {
            row.onClick = { [weak self] in self?.onChoose?(kind) }
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Open a surface")
        applyPalette(palette)
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        guard flags.isEmpty, let key = event.charactersIgnoringModifiers?.uppercased(),
              let (kind, row) = rows.first(where: { $0.0.key == key }) else {
            super.keyDown(with: event)
            return
        }
        if row.isEnabled { onChoose?(kind) }
    }

    override func applyPalette(_ palette: Palette) {
        titleLabel.textColor = palette.foreground
    }
}

/// One launcher row: `h-8 rounded px-2.5 text-sm`, glyph, title, keycap.
final class RightPanelLauncherRow: InteractiveView {
    private let icon = NSImageView()
    private let label: NSTextField
    private let keycap: KbdView

    init(kind: RightPanelViewController.SurfaceKind) {
        label = NSTextField.label(kind.title, size: Typography.rowSize)
        keycap = KbdView(kind.key)
        super.init(frame: .zero)
        layer?.cornerRadius = Radius.md
        icon.image = NSImage.symbol(kind.symbol, size: 14)
        icon.imageScaling = .scaleNone
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [icon, label, spacer, keycap])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 32),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel(kind.title)
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = (isHovered && isEnabled ? palette.accent.fading(0.6) : .clear).cgColor
        let text = isEnabled ? palette.foreground : palette.mutedForeground
        label.textColor = text
        icon.contentTintColor = isEnabled ? palette.mutedForeground : palette.mutedForeground.withAlphaComponent(0.5)
        alphaValue = isEnabled ? 1 : 0.5
    }
}
