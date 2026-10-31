import AppKit
import SopranoAgentsCore
import SwiftTerm

/// The bottom terminal drawer of the chat column: the selected workspace's (thread or project
/// draft) `.drawer` terminals from the window's `ThreadTerminalStore` (SwiftTerm running the
/// user's login shell in its working directory). A 6 pt handle on the top edge resizes the drawer;
/// with several terminals a 144 pt list sits on the right, a single one gets a floating New / Close
/// toolbar.
@MainActor
final class TerminalDrawerViewController: NSViewController, FocusRegionController {
    let engine: AgentEngine
    let state: WorkspaceState
    /// Every terminal of the window; the right panel's terminal tabs share it.
    let store: ThreadTerminalStore

    /// Workspace keys whose drawer already opened once (the first open creates a terminal).
    private var autoCreated: Set<String> = []

    private let resizeHandle = ResizeRail(axis: .horizontal)
    private let terminalHost = NSView()
    private let listPanel = TerminalListPanel()
    private let toolbar = TerminalFloatingToolbar()
    let emptyState = TerminalEmptyState()
    private var listWidth: NSLayoutConstraint?

    /// Reports a workspace whose folder is gone (no terminal or script starts). Defaults to
    /// an alert over the window; tests replace it.
    lazy var reportMissingWorkspace: (_ path: String) -> Void = { [weak self] path in
        let window = self?.view.window
        Task { @MainActor in
            await Dialogs.alert(
                title: "Workspace not found",
                message: "\(path) doesn't exist, so no terminal or script was started. Restore the folder or start a new thread.",
                in: window
            )
        }
    }

    static let listWidth: CGFloat = 144

    init(engine: AgentEngine, state: WorkspaceState) {
        self.engine = engine
        self.state = state
        self.store = ThreadTerminalStore(engine: engine)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = TerminalDrawerRootView(frame: NSRect(x: 0, y: 0, width: 800, height: Metrics.terminalHeight))
        view = root
        terminalHost.wantsLayer = true
        for subview in [terminalHost, listPanel, emptyState, toolbar, resizeHandle] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        let listWidth = listPanel.widthAnchor.constraint(equalToConstant: 0)
        self.listWidth = listWidth
        NSLayoutConstraint.activate([
            resizeHandle.topAnchor.constraint(equalTo: root.topAnchor),
            resizeHandle.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            resizeHandle.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            resizeHandle.heightAnchor.constraint(equalToConstant: 6),

            terminalHost.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            terminalHost.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            terminalHost.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
            terminalHost.trailingAnchor.constraint(equalTo: listPanel.leadingAnchor, constant: -8),

            listPanel.topAnchor.constraint(equalTo: root.topAnchor, constant: 1),
            listPanel.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            listPanel.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            listWidth,

            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            emptyState.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])

        resizeHandle.onDrag = { [weak self] delta in self?.resize(by: -delta) }
        emptyState.onNewTerminal = { [weak self] in self?.newTerminal() }
        toolbar.onNew = { [weak self] in self?.newTerminal() }
        toolbar.onClose = { [weak self] in self?.closeActiveTerminal() }
        listPanel.onNew = { [weak self] in self?.newTerminal() }
        listPanel.onClose = { [weak self] in self?.closeActiveTerminal() }
        listPanel.onSelect = { [weak self] id in self?.select(sessionID: id) }

        state.addObserver(self) { [weak self] change in
            switch change {
            case .selection, .panels: self?.update()
            case .filter, .composerRestore: break
            }
        }
        store.addObserver(self) { [weak self] change in
            guard let self else { return }
            switch change {
            case .sessions(let key):
                if !engine.workspaceKeys.contains(key) { autoCreated.remove(key) }
                if key == workspace?.key { update() }
            case let .moved(from, to):
                // The thread inherits the draft's opened drawer; the project's next draft starts
                // fresh. No re-render: the draft is still selected and would spawn a new shell at
                // once; selecting the thread re-renders.
                if autoCreated.remove(from) != nil { autoCreated.insert(to) }
            }
        }
        // A worktree that appears after launch (or a project that moves back) ends "Workspace
        // not found" and starts the first terminal; the list changes when that happens.
        engine.addObserver(self) { [weak self] event in
            if event == .threadListChanged || event == .projectsChanged { self?.update() }
        }
        update()
    }

    // MARK: - Workspaces and sessions

    /// The selected thread or project draft; nil for a projectless draft (no folder yet).
    private var workspace: WorkspaceRef? { state.workspace }

    /// Shows the selected workspace's active drawer terminal (creating the first one when the
    /// drawer opens).
    private func update() {
        guard isViewLoaded else { return }
        // A workspace whose folder is missing shows that instead of an empty drawer, and gets its
        // first terminal once the folder is back.
        let workspace = workspace
        let key = workspace?.key
        let missingWorkspace = workspace.flatMap { store.missingWorkspace(for: $0) }
        if state.isTerminalVisible, let workspace, let key, missingWorkspace == nil, !autoCreated.contains(key) {
            autoCreated.insert(key)
            if store.sessions(for: key, placement: .drawer).isEmpty {
                // Re-renders through the store observer.
                if createTerminal(in: workspace) != nil { return }
            }
        }
        emptyState.missingWorkspace = missingWorkspace
        let list = key.map { store.sessions(for: $0, placement: .drawer) } ?? []
        let active = key.flatMap { store.activeSession(for: $0, placement: .drawer) }
        for subview in terminalHost.subviews where subview !== active.flatMap({ store.terminalView($0.id) }) {
            subview.removeFromSuperview()
        }
        if let active, let terminal = store.terminalView(active.id), terminal.superview !== terminalHost {
            terminal.removeFromSuperview()
            terminal.translatesAutoresizingMaskIntoConstraints = false
            terminalHost.addSubview(terminal)
            NSLayoutConstraint.activate([
                terminal.topAnchor.constraint(equalTo: terminalHost.topAnchor),
                terminal.leadingAnchor.constraint(equalTo: terminalHost.leadingAnchor),
                terminal.trailingAnchor.constraint(equalTo: terminalHost.trailingAnchor),
                terminal.bottomAnchor.constraint(equalTo: terminalHost.bottomAnchor),
            ])
        }
        emptyState.isHidden = !list.isEmpty || workspace == nil
        emptyState.isEnabled = workspace != nil
        toolbar.isHidden = list.count != 1
        listPanel.isHidden = list.count < 2
        listWidth?.constant = list.count < 2 ? 0 : Self.listWidth
        listPanel.update(sessions: list, activeID: active?.id)
    }

    /// Starts a drawer terminal for `workspace` and makes it active. Returns its session id, or
    /// nil (after reporting it) when the workspace's directory no longer exists: a terminal or
    /// project script never falls back to another folder.
    @discardableResult
    private func createTerminal(in workspace: WorkspaceRef) -> String? {
        guard engine.workingDirectory(of: workspace) != nil else { return nil }
        guard let session = store.create(in: workspace, placement: .drawer) else {
            if let path = store.missingWorkspace(for: workspace) { reportMissingWorkspace(path) }
            return nil
        }
        return session.id
    }

    /// "New Terminal" (⌘N in the drawer): opens the drawer and adds a terminal to the workspace.
    func newTerminal() {
        guard let workspace else { return }
        autoCreated.insert(workspace.key)
        guard createTerminal(in: workspace) != nil else { return }
        if !state.isTerminalVisible {
            state.setTerminalVisible(true)
        } else {
            update()
        }
        focusActiveTerminal()
    }

    /// Opens the drawer on a new terminal of `workspace` and types `command` into it (project
    /// scripts; the leading space keeps it out of shell history).
    func run(command: String, in workspace: WorkspaceRef) {
        autoCreated.insert(workspace.key)
        guard let sessionID = createTerminal(in: workspace), let terminal = store.terminalView(sessionID) else { return }
        if state.workspace == workspace {
            if !state.isTerminalVisible { state.setTerminalVisible(true) } else { update() }
        }
        terminal.send(txt: " \(command)\r")
        focusActiveTerminal()
    }

    /// "Close Terminal" (⌘W in the drawer), confirming first.
    func closeActiveTerminal() {
        guard let key = workspace?.key, let active = store.activeSession(for: key, placement: .drawer) else { return }
        Task { @MainActor in
            let confirmed = await Dialogs.confirm(
                title: "Close terminal \"\(active.title)\"?",
                message: "This stops the running process and clears its history.",
                confirmTitle: "Close",
                isDestructive: true,
                in: view.window
            )
            guard confirmed else { return }
            store.close(active.id)
        }
    }

    private func select(sessionID: String) {
        store.select(sessionID)
        update()
        focusActiveTerminal()
    }

    private func focusActiveTerminal() {
        guard let key = workspace?.key, let active = store.activeSession(for: key, placement: .drawer),
              let terminal = store.terminalView(active.id) else { return }
        view.window?.makeFirstResponder(terminal)
    }

    // MARK: - Resize

    private func resize(by delta: CGFloat) {
        guard let chat = parent as? ChatViewController else { return }
        let column = chat.view.bounds.height
        let maximum = max(Metrics.terminalMinHeight, min(column * 0.75, column - Metrics.topbarHeight - 120))
        chat.terminalDrawerHeight = min(max(chat.terminalDrawerHeight + delta, Metrics.terminalMinHeight), maximum)
    }

    // MARK: - FocusRegionController

    var focusRegion: FocusRegion { .terminal }
    var focusRootView: NSView { view }

    func takeFocus() {
        focusActiveTerminal()
    }
}

/// Drawer background (`bg-background`) with its `border-t border-border/80`.
final class TerminalDrawerRootView: PaletteView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.terminalBackground.cgColor
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        palette.border.fading(0.8).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

/// "No terminal sessions here yet." + "New Terminal".
final class TerminalEmptyState: PaletteView {
    var onNewTerminal: (() -> Void)?
    var isEnabled = true {
        didSet { button.isEnabled = isEnabled }
    }

    /// The workspace's folder that doesn't exist; the empty state says so instead of offering a shell.
    var missingWorkspace: String? {
        didSet {
            label.stringValue = missingWorkspace.map { "Workspace not found: \($0)" } ?? Self.emptyText
            button.isHidden = missingWorkspace != nil
        }
    }

    private static let emptyText = "No terminal sessions here yet."
    private let label = NSTextField.label(TerminalEmptyState.emptyText, size: Typography.rowSize)
    private let button = TextButton("New Terminal", symbol: "plus", variant: .outline, size: .xs)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let stack = NSStackView(views: [label, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        button.onClick = { [weak self] in self?.onNewTerminal?() }
        label.lineBreakMode = .byTruncatingMiddle
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        label.textColor = palette.mutedForeground
    }
}

/// Single-terminal toolbar floating top-right (`rounded-md border bg-background shadow-xs`).
final class TerminalFloatingToolbar: PaletteView {
    var onNew: (() -> Void)?
    var onClose: (() -> Void)?

    private let newButton = GhostIconButton(symbol: "plus", size: 24, symbolSize: 12, toolTip: "New Terminal (⌘N)")
    private let closeButton = GhostIconButton(symbol: "trash", size: 24, symbolSize: 12, toolTip: "Close Terminal (⌘W)")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = Radius.md
        layer?.borderWidth = 1
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 1
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        let stack = NSStackView(views: [newButton, closeButton])
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
        ])
        newButton.onClick = { [weak self] in self?.onNew?() }
        closeButton.onClick = { [weak self] in self?.onClose?() }
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.background.cgColor
        layer?.borderColor = palette.border.cgColor
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.05).cgColor
    }
}

/// The 144 pt terminal list shown with two or more terminals: New / Close on top, one 22 pt
/// row per terminal.
final class TerminalListPanel: PaletteView {
    var onNew: (() -> Void)?
    var onClose: (() -> Void)?
    var onSelect: ((String) -> Void)?

    private let edge = NSView()
    private let newButton = GhostIconButton(symbol: "plus", size: 22, symbolSize: 11, toolTip: "New Terminal (⌘N)")
    private let closeButton = GhostIconButton(symbol: "trash", size: 22, symbolSize: 11, toolTip: "Close Terminal (⌘W)")
    private let rows = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        edge.wantsLayer = true
        let toolbar = NSStackView(views: [newButton, closeButton])
        toolbar.orientation = .horizontal
        toolbar.spacing = 2
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 2
        for subview in [edge, toolbar, rows] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        NSLayoutConstraint.activate([
            edge.leadingAnchor.constraint(equalTo: leadingAnchor),
            edge.topAnchor.constraint(equalTo: topAnchor),
            edge.bottomAnchor.constraint(equalTo: bottomAnchor),
            edge.widthAnchor.constraint(equalToConstant: 1),
            toolbar.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            rows.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 6),
            rows.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])
        newButton.onClick = { [weak self] in self?.onNew?() }
        closeButton.onClick = { [weak self] in self?.onClose?() }
        clipsToBounds = true
        applyPalette(palette)
    }

    func update(sessions: [TerminalSessionInfo], activeID: String?) {
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for session in sessions {
            let row = TerminalListRow(title: session.title, isActive: session.id == activeID)
            row.onClick = { [weak self] in self?.onSelect?(session.id) }
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.terminalBackground.cgColor
        edge.layer?.backgroundColor = palette.border.cgColor
    }
}

/// One terminal in the list (`h-[22px] text-2xs`).
final class TerminalListRow: InteractiveView {
    private let icon = NSImageView()
    private let label = NSTextField.label(size: Typography.tinySize)
    private let isActive: Bool

    init(title: String, isActive: Bool) {
        self.isActive = isActive
        super.init(frame: .zero)
        layer?.cornerRadius = Radius.sm
        icon.image = NSImage.symbol(Icon.terminal, size: 10)
        icon.imageScaling = .scaleNone
        label.stringValue = title
        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 22),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = (isActive ? palette.accent : isHovered ? palette.accent.fading(0.6) : .clear).cgColor
        let text = isActive ? palette.foreground : palette.mutedForeground
        label.textColor = text
        icon.contentTintColor = text
    }
}

