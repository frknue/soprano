import AppKit
import SopranoAgentsCore
import SwiftTerm

/// The bottom terminal drawer of the chat column (`ThreadTerminalDrawer.tsx`): SwiftTerm
/// terminals running the user's login shell in the thread's working directory. Each thread keeps
/// its terminals while the user switches threads; processes end when their thread is deleted or
/// the app quits. A 6 pt handle on the top edge resizes the drawer; with several terminals a
/// 144 pt list sits on the right, a single one gets a floating New / Close toolbar.
@MainActor
final class TerminalDrawerViewController: NSViewController, FocusRegionController, LocalProcessTerminalViewDelegate {
    let engine: AgentEngine
    let state: WorkspaceState

    private(set) var sessions = TerminalSessions()
    private var terminals: [String: LocalProcessTerminalView] = [:]
    /// Threads whose drawer already opened once (the first open creates a terminal).
    private var autoCreated: Set<String> = []

    private let resizeHandle = ResizeRail(axis: .horizontal)
    private let terminalHost = NSView()
    private let listPanel = TerminalListPanel()
    private let toolbar = TerminalFloatingToolbar()
    private let emptyState = TerminalEmptyState()
    private var listWidth: NSLayoutConstraint?

    static let listWidth: CGFloat = 144

    init(engine: AgentEngine, state: WorkspaceState) {
        self.engine = engine
        self.state = state
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
        engine.addObserver(self) { [weak self] event in
            if event == .threadListChanged || event == .projectsChanged { self?.pruneDeletedThreads() }
        }
        PaletteCenter.shared.addObserver(self) { [weak self] palette in self?.applyPalette(palette) }
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationWillTerminate), name: NSApplication.willTerminateNotification, object: nil
        )
        update()
    }

    // MARK: - Threads and sessions

    private var threadID: String? { state.selectedThreadID }

    /// Shows the selected thread's active terminal (creating the first one when the drawer opens).
    private func update() {
        guard isViewLoaded else { return }
        if state.isTerminalVisible, let threadID, !autoCreated.contains(threadID) {
            autoCreated.insert(threadID)
            if sessions.sessions(for: threadID).isEmpty, workingDirectory(for: threadID) != nil {
                _ = createTerminal(in: threadID)
            }
        }
        let list = threadID.map { sessions.sessions(for: $0) } ?? []
        let active = threadID.flatMap { sessions.activeSession(for: $0) }
        for (id, terminal) in terminals where id != active?.id && terminal.superview != nil {
            terminal.removeFromSuperview()
        }
        if let active, let terminal = terminals[active.id], terminal.superview !== terminalHost {
            terminal.translatesAutoresizingMaskIntoConstraints = false
            terminalHost.addSubview(terminal)
            NSLayoutConstraint.activate([
                terminal.topAnchor.constraint(equalTo: terminalHost.topAnchor),
                terminal.leadingAnchor.constraint(equalTo: terminalHost.leadingAnchor),
                terminal.trailingAnchor.constraint(equalTo: terminalHost.trailingAnchor),
                terminal.bottomAnchor.constraint(equalTo: terminalHost.bottomAnchor),
            ])
        }
        emptyState.isHidden = !list.isEmpty || threadID == nil
        emptyState.isEnabled = threadID != nil
        toolbar.isHidden = list.count != 1
        listPanel.isHidden = list.count < 2
        listWidth?.constant = list.count < 2 ? 0 : Self.listWidth
        listPanel.update(sessions: list, activeID: active?.id)
    }

    /// The directory a new terminal starts in: the thread's working directory (a scratch
    /// directory is created on demand); nil when it does not exist.
    private func workingDirectory(for threadID: String) -> String? {
        guard let thread = engine.thread(threadID) else { return nil }
        let path = engine.workingDirectory(for: thread)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return path
        }
        if thread.projectID == nil && thread.worktreePath == nil {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            return FileManager.default.fileExists(atPath: path) ? path : nil
        }
        return nil
    }

    /// Starts a terminal for `threadID` and makes it active. Returns its session id.
    @discardableResult
    private func createTerminal(in threadID: String) -> String? {
        let cwd = workingDirectory(for: threadID) ?? NSHomeDirectory()
        let session = sessions.add(to: threadID)
        let terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        terminal.processDelegate = self
        terminal.optionAsMetaKey = false
        terminal.font = Typography.mono(Typography.terminalSize)
        style(terminal, palette: PaletteCenter.shared.palette)
        terminals[session.id] = terminal
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        terminal.startProcess(
            executable: shell,
            args: ["-l"],
            environment: Self.environment(),
            execName: "-" + URL(fileURLWithPath: shell).lastPathComponent,
            currentDirectory: cwd
        )
        return session.id
    }

    /// The app's environment for the shell, with terminal capabilities set.
    static func environment() -> [String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Soprano Agents"
        if environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }
        return environment.map { "\($0.key)=\($0.value)" }
    }

    /// "New Terminal" (⌘N in the drawer): opens the drawer and adds a terminal to the thread.
    func newTerminal() {
        guard let threadID else { return }
        autoCreated.insert(threadID)
        createTerminal(in: threadID)
        if !state.isTerminalVisible {
            state.setTerminalVisible(true)
        } else {
            update()
        }
        focusActiveTerminal()
    }

    /// Opens the drawer on a new terminal of `threadID` and types `command` into it (project
    /// scripts; the leading space keeps it out of shell history).
    func run(command: String, in threadID: String) {
        autoCreated.insert(threadID)
        guard let sessionID = createTerminal(in: threadID), let terminal = terminals[sessionID] else { return }
        if state.selectedThreadID == threadID {
            if !state.isTerminalVisible { state.setTerminalVisible(true) } else { update() }
        }
        terminal.send(txt: " \(command)\r")
        focusActiveTerminal()
    }

    /// "Close Terminal" (⌘W in the drawer), confirming first like T3 Code.
    func closeActiveTerminal() {
        guard let threadID, let active = sessions.activeSession(for: threadID) else { return }
        Task { @MainActor in
            let confirmed = await Dialogs.confirm(
                title: "Close terminal \"\(active.title)\"?",
                message: "This stops the running process and clears its history.",
                confirmTitle: "Close",
                isDestructive: true,
                in: view.window
            )
            guard confirmed else { return }
            close(sessionID: active.id, in: threadID)
        }
    }

    private func close(sessionID: String, in threadID: String) {
        guard sessions.close(sessionID, in: threadID) else { return }
        end(sessionID)
        update()
        if sessions.sessions(for: threadID).isEmpty, state.selectedThreadID == threadID {
            focusActiveTerminal()
        }
    }

    private func select(sessionID: String) {
        guard let threadID else { return }
        sessions.select(sessionID, in: threadID)
        update()
        focusActiveTerminal()
    }

    private func end(_ sessionID: String) {
        guard let terminal = terminals.removeValue(forKey: sessionID) else { return }
        terminal.processDelegate = nil
        let pid = terminal.process?.shellPid ?? 0
        if pid > 0 { kill(pid, SIGHUP) }
        terminal.terminate()
        terminal.removeFromSuperview()
    }

    private func pruneDeletedThreads() {
        let live = Set(engine.threads.map(\.id))
        for session in sessions.prune(keeping: live) {
            end(session.id)
        }
        autoCreated.formIntersection(live)
        update()
    }

    @objc private func applicationWillTerminate() {
        for session in sessions.removeAll() {
            end(session.id)
        }
    }

    private func focusActiveTerminal() {
        guard let threadID, let active = sessions.activeSession(for: threadID), let terminal = terminals[active.id] else {
            return
        }
        view.window?.makeFirstResponder(terminal)
    }

    // MARK: - Resize

    private func resize(by delta: CGFloat) {
        guard let chat = parent as? ChatViewController else { return }
        let column = chat.view.bounds.height
        let maximum = max(Metrics.terminalMinHeight, min(column * 0.75, column - Metrics.topbarHeight - 120))
        chat.terminalDrawerHeight = min(max(chat.terminalDrawerHeight + delta, Metrics.terminalMinHeight), maximum)
    }

    // MARK: - Palette

    private func applyPalette(_ palette: Palette) {
        for terminal in terminals.values {
            style(terminal, palette: palette)
        }
    }

    private func style(_ terminal: LocalProcessTerminalView, palette: Palette) {
        terminal.nativeBackgroundColor = palette.terminalBackground
        terminal.nativeForegroundColor = palette.terminalForeground
        terminal.caretColor = palette.terminalCursor
        terminal.selectedTextBackgroundColor = palette.terminalSelection
        terminal.installColors(TerminalANSIColors.colors(dark: palette.isDark))
    }

    // MARK: - LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    /// The shell exited: its session closes (T3 Code closes exited terminals).
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        let identifier = ObjectIdentifier(source)
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let (sessionID, _) = terminals.first(where: { ObjectIdentifier($0.value) == identifier }) else { return }
            for threadID in sessions.threadIDs where sessions.sessions(for: threadID).contains(where: { $0.id == sessionID }) {
                close(sessionID: sessionID, in: threadID)
            }
        }
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

/// "No terminal sessions for this thread yet." + "New Terminal".
final class TerminalEmptyState: PaletteView {
    var onNewTerminal: (() -> Void)?
    var isEnabled = true {
        didSet { button.isEnabled = isEnabled }
    }

    private let label = NSTextField.label("No terminal sessions for this thread yet.", size: Typography.rowSize)
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

/// The 16 ANSI colors for light and dark terminals (VS Code's default terminal palettes, which
/// sit well on T3 Code's zinc and black canvases).
enum TerminalANSIColors {
    static func colors(dark: Bool) -> [SwiftTerm.Color] {
        let hexes: [UInt32] = dark
            ? [0x000000, 0xcd3131, 0x0dbc79, 0xe5e510, 0x2472c8, 0xbc3fbc, 0x11a8cd, 0xe5e5e5,
               0x666666, 0xf14c4c, 0x23d18b, 0xf5f543, 0x3b8eea, 0xd670d6, 0x29b8db, 0xe5e5e5]
            : [0x000000, 0xcd3131, 0x00bc00, 0x949800, 0x0451a5, 0xbc05bc, 0x0598bc, 0x555555,
               0x666666, 0xcd3131, 0x14ce14, 0xb5ba00, 0x0451a5, 0xbc05bc, 0x0598bc, 0xa5a5a5]
        return hexes.map { value in
            func channel(_ shift: UInt32) -> UInt16 { UInt16((value >> shift) & 0xff) * 257 }
            return SwiftTerm.Color(red: channel(16), green: channel(8), blue: channel(0))
        }
    }
}
