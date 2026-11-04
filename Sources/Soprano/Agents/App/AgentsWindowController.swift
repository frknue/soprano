import AppKit
import SopranoAgentsCore

/// The app window: hidden-inset title bar (traffic lights over the sidebar), full-size content, the workspace as content.
final class AgentsWindow: NSWindow {
    /// Draw as key even when offscreen (snapshot harness) so focus marks render.
    var rendersAsKey = false
    /// Keep a frame outside every screen (snapshot harness renders offscreen).
    var allowsOffscreenFrame = false

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        allowsOffscreenFrame ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }

    override var isKeyWindow: Bool { rendersAsKey || super.isKeyWindow }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AgentsWindowController: NSWindowController, NSWindowDelegate {
    let engine: AgentEngine
    let state: WorkspaceState
    let workspace: WorkspaceViewController
    private(set) lazy var router = KeyboardRouter(
        keymap: { SettingsCenter.shared.keymap },
        context: { [weak self] in self?.commandContext() }
    )
    /// The command palette and Open Project… of this window.
    private(set) lazy var palette = CommandPalette(controller: self)
    private let persistsFrame: Bool
    /// Brings Soprano's terminal window forward; set by `AgentsAppController`.
    var showTerminals: (() -> Void)?

    private static let frameAutosaveName = "SopranoAgentsMainWindow"

    var mainWindow: AgentsWindow? { window as? AgentsWindow }

    /// `terminalAgents`: Soprano's pane agents for the sidebar's Terminals section and the
    /// Terminal Agents board; nil leaves both out.
    init(
        engine: AgentEngine,
        state: WorkspaceState = WorkspaceState(),
        defaults: UserDefaults = .standard,
        persistsFrame: Bool = true,
        frame: NSRect? = nil,
        terminalAgents: TerminalAgentsSource? = nil
    ) {
        self.engine = engine
        self.state = state
        self.persistsFrame = persistsFrame
        workspace = WorkspaceViewController(engine: engine, state: state, defaults: defaults, terminalAgentsSource: terminalAgents)

        let initialFrame = frame ?? NSRect(origin: .zero, size: Metrics.windowDefaultSize)
        let window = AgentsWindow(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // An empty unified toolbar makes the titlebar `Metrics.topbarHeight` tall, so the traffic
        // lights center on the same line as the sidebar toggle, brand and chat header.
        window.toolbar = NSToolbar(identifier: "SopranoAgentsMainWindow")
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = false
        window.minSize = Metrics.windowMinSize
        window.title = "Soprano Agents"
        window.isReleasedWhenClosed = false
        window.contentViewController = workspace
        window.setFrame(initialFrame, display: false)
        super.init(window: window)
        window.delegate = self

        if persistsFrame {
            if !window.setFrameUsingName(Self.frameAutosaveName) {
                window.center()
            }
            window.setFrameAutosaveName(Self.frameAutosaveName)
        }
        applyPalette(PaletteCenter.shared.palette)
        PaletteCenter.shared.addObserver(self) { [weak self] palette in
            self?.applyPalette(palette)
        }
        router.startMonitoring(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func applyPalette(_ palette: Palette) {
        window?.appearance = palette.appearance
        window?.backgroundColor = palette.background
    }

    /// The context commands run in: engine, state, focused region, text-input flag.
    func commandContext() -> CommandContext {
        let responder = window?.firstResponder
        return CommandContext(
            window: window,
            engine: engine,
            state: state,
            workspace: workspace,
            focus: focusedRegion(),
            isTextInput: responder is NSTextView || responder is NSTextField
        )
    }

    /// Walks up from the first responder to the nearest view owned by a `FocusRegionController`.
    func focusedRegion() -> FocusRegion? {
        guard var view = window?.firstResponder as? NSView else { return nil }
        let regions = focusRegionControllers()
        while true {
            if let match = regions.first(where: { $0.focusRootView === view }) {
                return match.focusRegion
            }
            guard let parent = view.superview else { return nil }
            view = parent
        }
    }

    /// Every region controller in the window, found by walking the view-controller tree.
    func focusRegionControllers() -> [any FocusRegionController] {
        var result: [any FocusRegionController] = []
        func visit(_ controller: NSViewController) {
            if let region = controller as? any FocusRegionController { result.append(region) }
            controller.children.forEach(visit)
        }
        visit(workspace)
        return result
    }

    /// Runs a command by id in the current context (menus, palette, buttons).
    @discardableResult
    func perform(_ id: String) -> Bool {
        CommandRegistry.shared.perform(id, in: commandContext())
    }

    /// Open from showing until closed, also while minimized or while Soprano is
    /// hidden (when `isVisible` is false): what the next launch restores.
    private(set) var isOpen = false

    /// Re-arms the keyboard after the window was closed; it reopens while Soprano runs.
    func prepareToShow() {
        isOpen = true
        if let window { router.startMonitoring(window: window) }
        workspace.chat.details.isWindowOpen = true
    }

    override func showWindow(_ sender: Any?) {
        prepareToShow()
        super.showWindow(sender)
    }

    /// What takes the keyboard when the window comes forward: the dialog or settings screen
    /// still open over it, so its keys never reach the views it covers, else the window.
    var keyTarget: NSWindow? { OverlayWindow.topmost(over: window) ?? window }

    /// Shows the window and makes `keyTarget` key.
    func showAndMakeKey() {
        showWindow(nil)
        keyTarget?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        isOpen = false
        router.stopMonitoring()
        // The Terminal Agents board's dashboard polls transcripts and terminals every second,
        // and the details card git status every 30 s; a closed window must not keep them running.
        state.setTerminalAgentsVisible(false)
        workspace.chat.details.isWindowOpen = false
    }
}
