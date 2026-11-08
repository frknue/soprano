import AppKit

/// A chat tab: the conversation with an agent as Soprano Agents' chat column — the timeline of
/// turns in the centered lane and the floating composer over its end — instead of the agent's
/// terminal. Holds the tab's `AgentChatSession`, so the agent runs as long as the tab's view does.
///
/// ```
/// ┌ timeline (lane ≤ 736, centered) ───────────────────────────┐
/// │                         user bubble right (≤ 80%, r16)     │
/// │ Worked for 3m 12s ⌄                                        │
/// │ assistant markdown 14/1.625                                │
/// │ N changed files card                                       │
/// │      ┌ composer r16 (≤ 736, 20 above the bottom) ┐         │
/// └──────┴───────────────────────────────────────────┴─────────┘
/// ```
@MainActor
final class AgentChatPaneView: PaletteView {
    let target: TerminalTarget
    let session: AgentChatSession
    var onFocusRequested: (() -> Void)?
    /// Restarts the agent through the tab, so its status starts over too.
    var onRestartRequested: (() -> Void)?

    /// Delay that batches streamed chunks into one redraw.
    private static let renderDelay: TimeInterval = 0.05

    private let timeline: ChatTimelineView
    private let composer: ChatComposerView
    private var renderScheduled = false
    private var firstResponderObservation: NSKeyValueObservation?

    /// `themeManager` is not read: the chat colors itself from `PaletteCenter`, which follows it.
    init(target: TerminalTarget, session: AgentChatSession, agentName: String, themeManager: ThemeManager) {
        self.target = target
        self.session = session
        timeline = ChatTimelineView(source: session, agentName: agentName)
        composer = ChatComposerView(session: session, agentName: agentName)
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        identifier = NSUserInterfaceItemIdentifier("agent-chat")
        build()
        applyPalette(palette)
        session.onChange = { [weak self] in
            self?.scheduleRender()
        }
        render()
    }

    private func build() {
        timeline.translatesAutoresizingMaskIntoConstraints = false
        composer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(timeline)
        addSubview(composer)
        // Centered and capped at the chat lane width, keeping the page gutter; a narrow pane
        // squeezes the composer instead of growing.
        let composerWidth = composer.widthAnchor.constraint(equalToConstant: Metrics.chatMaxWidth)
        composerWidth.priority = .dragThatCannotResizeWindow
        let leading = composer.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Metrics.gutter)
        let trailing = composer.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Metrics.gutter)
        let bottom = composer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.gutter)
        gutterConstraints = (leading, trailing, bottom)
        NSLayoutConstraint.activate([
            timeline.topAnchor.constraint(equalTo: topAnchor),
            timeline.leadingAnchor.constraint(equalTo: leadingAnchor),
            timeline.trailingAnchor.constraint(equalTo: trailingAnchor),
            timeline.bottomAnchor.constraint(equalTo: bottomAnchor),
            composer.centerXAnchor.constraint(equalTo: centerXAnchor),
            composerWidth,
            leading,
            trailing,
            bottom,
            composer.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: Metrics.gutter),
        ])
        composer.onHeightChange = { [weak self] height in
            self?.composerHeight = height
        }
        composerHeight = 140
        composer.onFocusChange = { [weak self] focused in
            guard let self, focused else { return }
            // Clears the tab's attention and banners, as a focused terminal does.
            NotificationCenter.default.post(
                name: .ghosttyDidFocusSurface,
                object: self,
                userInfo: ["paneId": self.target.paneId, "tabId": self.target.tabId]
            )
            DispatchQueue.main.async { [weak self] in self?.onFocusRequested?() }
        }
        composer.onRestartRequested = { [weak self] in
            self?.onFocusRequested?()
            self?.onRestartRequested?()
        }
        composer.onSubmitted = { [weak self] in self?.timeline.jumpToLatest() }
        timeline.keyHandler = { [weak self] event in self?.handleTimelineKey(event) ?? false }
    }

    /// Ends the agent when the tab goes away.
    func close() {
        firstResponderObservation = nil
        timeline.close()
        composer.close()
        session.onChange = nil
        session.onEvent = nil
        session.stop()
    }

    func focusPreferredControl() {
        onFocusRequested?()
        window?.makeFirstResponder(composer.textView)
    }

    /// The palette follows the app's theme (`PaletteCenter`); the rows rebuild their colors.
    func applyTheme() {
        applyPalette(palette)
        render()
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.background.cgColor
    }

    /// The composer's gutters follow the timeline's: narrower in a narrow pane.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let gutter = TimelineListView.gutter(forWidth: newSize.width)
        guard let gutterConstraints, gutterConstraints.leading.constant != gutter else { return }
        gutterConstraints.leading.constant = gutter
        gutterConstraints.trailing.constant = -gutter
        gutterConstraints.bottom.constant = -gutter
        updateTimelineInset()
    }

    private var gutterConstraints: (leading: NSLayoutConstraint, trailing: NSLayoutConstraint, bottom: NSLayoutConstraint)?

    private var composerHeight: CGFloat = 0 {
        didSet { updateTimelineInset() }
    }

    private func updateTimelineInset() {
        let gutter = gutterConstraints.map { -$0.bottom.constant } ?? Metrics.gutter
        timeline.bottomInset = composerHeight + gutter * 2
    }

    // MARK: - Rendering

    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.renderDelay) { [weak self] in
            guard let self else { return }
            self.renderScheduled = false
            self.render()
        }
    }

    private func render() {
        timeline.reload()
        composer.refresh()
    }

    // MARK: - Keys

    /// Escape stops the running turn; plain keys typed while reading go to the composer.
    private func handleTimelineKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53, session.phase == .working {
            session.cancel()
            return true
        }
        guard modifiers.subtracting([.shift, .numericPad]).isEmpty,
              let characters = event.characters, !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return false }
        window?.makeFirstResponder(composer.textView)
        composer.textView.keyDown(with: event)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        onFocusRequested?()
        super.mouseDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeFirstResponder()
    }

    /// Selecting text in the transcript (or any other control of the chat) makes it the key
    /// view without reaching `mouseDown` here: the text view takes the click. Activate the pane
    /// then too, so pane commands (close, split) act on the chat the user is working in.
    private func observeFirstResponder() {
        firstResponderObservation = window?.observe(\.firstResponder, options: [.new]) { [weak self] window, _ in
            MainActor.assumeIsolated {
                guard let self,
                      let responder = window.firstResponder as? NSView,
                      responder !== self.composer.textView,
                      responder.isDescendant(of: self)
                else { return }
                // After the click that moved focus is handled: activating the pane re-syncs
                // keyboard focus, which must find the responder already inside the chat.
                DispatchQueue.main.async { [weak self] in self?.onFocusRequested?() }
            }
        }
    }
}
