import AppKit

/// Root view controller managing the sidebar + tiling layout + status bar composition.
final class MainContentViewController: NSViewController {
    let agentManager: AgentManager
    let sessionManager: SessionManager
    let themeManager: ThemeManager
    let gitBranchMonitor: GitBranchMonitor
    private let onSettingsRequested: (() -> Void)?
    private let splitTreeViewFactory: (AgentManager, ThemeManager) -> SplitTreeView
    private let defaults: UserDefaults
    private var sidebarVisible: Bool

    private var sidebarView: SidebarView!
    private var splitTreeView: SplitTreeView!
    private var statusBarView: StatusBarView!
    private var sidebarWidthConstraint: NSLayoutConstraint!
    private var sidebarResizeHandle: SidebarResizeHandleView!
    private var sidebarWidth: CGFloat
    private var settingsContainerView: NSView!
    private var settingsHeaderView: NSView!
    private var settingsTitleLabel: NSTextField!
    private var settingsCloseButton: NSButton!
    private var settingsViewController: SettingsViewController?
    private var settingsViewConstraints: [NSLayoutConstraint] = []
    private var dashboardViewController: AgentDashboardViewController?
    private var dashboardViewConstraints: [NSLayoutConstraint] = []

    private static let sidebarVisibleKey = "soprano-sidebar-visible"

    init(
        agentManager: AgentManager,
        sessionManager: SessionManager,
        themeManager: ThemeManager,
        gitBranchMonitor: GitBranchMonitor,
        onSettingsRequested: (() -> Void)? = nil,
        defaults: UserDefaults = .standard,
        splitTreeViewFactory: @escaping (AgentManager, ThemeManager) -> SplitTreeView = {
            SplitTreeView(agentManager: $0, themeManager: $1)
        }
    ) {
        self.agentManager = agentManager
        self.sessionManager = sessionManager
        self.themeManager = themeManager
        self.gitBranchMonitor = gitBranchMonitor
        self.onSettingsRequested = onSettingsRequested
        self.splitTreeViewFactory = splitTreeViewFactory
        self.defaults = defaults
        self.sidebarVisible = defaults.object(forKey: Self.sidebarVisibleKey) as? Bool ?? true
        self.sidebarWidth = SidebarWidthStore.load(from: defaults)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = MainContentRootView(frame: .zero)
        root.wantsLayer = true
        let safeArea = root.safeAreaLayoutGuide

        // Split tree (tiling layout)
        splitTreeView = splitTreeViewFactory(agentManager, themeManager)
        splitTreeView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(splitTreeView)

        // Sidebar
        sidebarView = SidebarView(
            agentManager: agentManager,
            sessionManager: sessionManager,
            themeManager: themeManager,
            gitBranchMonitor: gitBranchMonitor
        )
        sidebarView.onSettingsRequested = onSettingsRequested
        sidebarView.onDashboardRequested = { [weak self] in
            self?.showDashboard()
        }
        sidebarView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebarView, positioned: .above, relativeTo: splitTreeView)

        // Status bar
        statusBarView = StatusBarView(agentManager: agentManager, themeManager: themeManager)
        statusBarView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(statusBarView)
        splitTreeView.onCopyModeStateChanged = { [weak self] state in
            self?.setKeybindingMode(state)
        }

        sidebarView.setContentWidth(sidebarWidth)

        // Resize handle, above the sidebar and the tiling layout
        sidebarResizeHandle = makeSidebarResizeHandle()
        sidebarResizeHandle.isHidden = !sidebarVisible
        root.addSubview(sidebarResizeHandle, positioned: .above, relativeTo: sidebarView)

        // Layout
        sidebarWidthConstraint = sidebarView.widthAnchor.constraint(
            equalToConstant: sidebarVisible ? sidebarWidth : 0
        )

        NSLayoutConstraint.activate([
            sidebarResizeHandle.centerXAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            sidebarResizeHandle.topAnchor.constraint(equalTo: sidebarView.topAnchor),
            sidebarResizeHandle.bottomAnchor.constraint(equalTo: sidebarView.bottomAnchor),
            sidebarResizeHandle.widthAnchor.constraint(
                equalToConstant: SidebarResizeHandleView.grabWidth
            ),

            // Respect the window safe area so content stays out of the titlebar/traffic-light region.
            sidebarView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebarView.topAnchor.constraint(equalTo: safeArea.topAnchor),
            sidebarView.bottomAnchor.constraint(equalTo: statusBarView.topAnchor),
            sidebarWidthConstraint,

            // Split tree: right of sidebar, above status bar
            splitTreeView.leadingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            splitTreeView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            splitTreeView.topAnchor.constraint(equalTo: safeArea.topAnchor),
            splitTreeView.bottomAnchor.constraint(equalTo: statusBarView.topAnchor),

            // Status bar: full width, bottom
            statusBarView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBarView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBarView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusBarView.heightAnchor.constraint(equalToConstant: 28),
        ])

        buildSettingsScreen(in: root, below: safeArea.topAnchor)

        self.view = root
        applyTheme()
    }

    func toggleSidebar() {
        sidebarVisible.toggle()
        defaults.set(sidebarVisible, forKey: Self.sidebarVisibleKey)
        // Hidden sidebars have no edge to grab, and the handle would otherwise sit
        // over the leftmost pane.
        sidebarResizeHandle.isHidden = !sidebarVisible
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.sidebarWidthConstraint.animator().constant = self.sidebarVisible
                ? self.sidebarWidth
                : 0
            self.view.layoutSubtreeIfNeeded()
        }
    }

    // MARK: - Sidebar Resizing

    private func makeSidebarResizeHandle() -> SidebarResizeHandleView {
        let handle = SidebarResizeHandleView()
        handle.translatesAutoresizingMaskIntoConstraints = false
        handle.toolTip = "Drag to resize the sidebar, double-click to reset"
        handle.onDragBegan = { [weak self] in self?.sidebarWidth ?? SidebarWidthStore.defaultWidth }
        handle.onDragged = { [weak self] proposedWidth in
            self?.applySidebarWidth(proposedWidth)
        }
        handle.onDragEnded = { [weak self] in
            guard let self else { return }
            SidebarWidthStore.save(self.sidebarWidth, to: self.defaults)
        }
        handle.onResetRequested = { [weak self] in
            guard let self else { return }
            self.applySidebarWidth(SidebarWidthStore.defaultWidth)
            SidebarWidthStore.save(self.sidebarWidth, to: self.defaults)
        }
        handle.onHoverChanged = { [weak self] isHighlighted in
            self?.sidebarView.setResizeHighlighted(isHighlighted)
        }
        return handle
    }

    /// Applies a dragged width to both the sidebar and its content, clamped to the
    /// allowed range and to what the current window can spare for panes.
    private func applySidebarWidth(_ proposedWidth: CGFloat) {
        guard sidebarVisible else { return }

        let width = SidebarWidthStore.clamp(
            proposedWidth,
            availableWidth: view.bounds.width
        )
        guard width != sidebarWidth else { return }

        sidebarWidth = width
        sidebarWidthConstraint.constant = width
        sidebarView.setContentWidth(width)
        view.layoutSubtreeIfNeeded()
        // The handle moves with the sidebar edge, so its cursor rect is stale.
        view.window?.invalidateCursorRects(for: sidebarResizeHandle)
    }

    func setKeybindingMode(_ mode: KeybindingState) {
        statusBarView.setKeybindingMode(mode)
    }

    func setControlKeyHeld(_ isHeld: Bool) {
        sidebarView.setControlKeyHeld(isHeld)
    }

    func changeActiveTerminalFontSize(delta: Int) {
        splitTreeView.changeActiveTerminalFontSize(delta: delta)
    }

    func resetActiveTerminalFontSize() {
        splitTreeView.resetActiveTerminalFontSize()
    }

    func beginActiveTerminalCopyMode() {
        splitTreeView.beginActiveTerminalCopyMode()
    }

    func saveSessionAs() {
        loadViewIfNeeded()
        sidebarView.saveSessionAs()
    }

    func renameActiveWindow() {
        loadViewIfNeeded()
        sidebarView.promptToRenameActiveWindow()
    }

    func showSettings(
        settings: AppSettings,
        keybindingConfig: KeyBindingConfig
    ) {
        loadViewIfNeeded()
        if dashboardViewController != nil {
            closeDashboard(restoreKeyboardFocus: false)
        }
        preservingWindowFrame {
            let settingsViewController: SettingsViewController
            if let existingController = self.settingsViewController {
                settingsViewController = existingController
            } else {
                let controller = SettingsViewController(
                    themeManager: themeManager,
                    settings: settings,
                    keybindingConfig: keybindingConfig
                )
                addChild(controller)
                controller.view.translatesAutoresizingMaskIntoConstraints = false
                settingsContainerView.addSubview(controller.view)
                settingsViewConstraints = [
                    controller.view.leadingAnchor.constraint(equalTo: settingsContainerView.leadingAnchor),
                    controller.view.trailingAnchor.constraint(equalTo: settingsContainerView.trailingAnchor),
                    controller.view.topAnchor.constraint(equalTo: settingsHeaderView.bottomAnchor),
                    controller.view.bottomAnchor.constraint(equalTo: settingsContainerView.bottomAnchor),
                ]
                NSLayoutConstraint.activate(settingsViewConstraints)
                self.settingsViewController = controller
                settingsViewController = controller
            }

            settingsViewController.update(
                settings: settings,
                keybindingConfig: keybindingConfig
            )
            settingsViewController.apply(theme: themeManager.currentTheme)

            splitTreeView.isHidden = true
            settingsContainerView.isHidden = false
        }
        view.window?.makeFirstResponder(settingsCloseButton)
    }

    /// Pushes new values into the settings screen while it is on screen, so a
    /// hand edit to settings.json is visible without closing and reopening it.
    func refreshSettingsScreenIfVisible(
        settings: AppSettings,
        keybindingConfig: KeyBindingConfig
    ) {
        guard !settingsContainerView.isHidden,
              let settingsViewController
        else { return }
        settingsViewController.update(
            settings: settings,
            keybindingConfig: keybindingConfig
        )
    }

    func closeSettings() {
        guard !settingsContainerView.isHidden else { return }
        view.window?.endEditing(for: nil)
        preservingWindowFrame {
            settingsContainerView.isHidden = true
            splitTreeView.isHidden = false

            // Hidden views still participate in Auto Layout. Detach the settings
            // hierarchy so its content-size constraints cannot restrict the main
            // window after returning to the workspace.
            NSLayoutConstraint.deactivate(settingsViewConstraints)
            settingsViewConstraints.removeAll()
            settingsViewController?.view.removeFromSuperview()
            settingsViewController?.removeFromParent()
            settingsViewController = nil
        }

        splitTreeView.restoreKeyboardFocus()
    }

    func showDashboard() {
        loadViewIfNeeded()
        if !settingsContainerView.isHidden {
            closeSettings()
        }
        guard dashboardViewController == nil else { return }

        preservingWindowFrame {
            let controller = AgentDashboardViewController(
                agentManager: agentManager,
                themeManager: themeManager,
                terminalStateProvider: { [weak splitTreeView] target in
                    splitTreeView?.terminalInteractionState(for: target)
                        ?? .unavailable
                },
                promptSender: { [weak splitTreeView] target, prompt in
                    splitTreeView?.submitAgentPrompt(prompt, to: target) ?? false
                }
            )
            controller.onDismiss = { [weak self] in
                self?.closeDashboard()
            }
            controller.onAgentSelected = { [weak self] paneId, tabId in
                guard let self else { return }
                self.closeDashboard(restoreKeyboardFocus: false)
                self.agentManager.focusTab(paneId: paneId, tabId: tabId)
                self.splitTreeView.restoreKeyboardFocus()
            }
            addChild(controller)
            controller.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(controller.view, positioned: .above, relativeTo: nil)
            dashboardViewConstraints = [
                controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                controller.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ]
            NSLayoutConstraint.activate(dashboardViewConstraints)
            dashboardViewController = controller
            splitTreeView.isHidden = true
        }
        view.window?.makeFirstResponder(dashboardViewController?.view)
    }

    func closeDashboard(restoreKeyboardFocus: Bool = true) {
        guard let dashboardViewController else { return }
        preservingWindowFrame {
            NSLayoutConstraint.deactivate(dashboardViewConstraints)
            dashboardViewConstraints.removeAll()
            dashboardViewController.view.removeFromSuperview()
            dashboardViewController.removeFromParent()
            self.dashboardViewController = nil
            splitTreeView.isHidden = false
        }
        if restoreKeyboardFocus {
            splitTreeView.restoreKeyboardFocus()
        }
    }

    func refreshTheme() {
        applyTheme()
        sidebarView.refreshTheme()
        splitTreeView.refreshTheme()
        statusBarView.refreshTheme()
        dashboardViewController?.apply(theme: themeManager.currentTheme)
    }

    private func applyTheme() {
        let theme = themeManager.currentTheme
        view.layer?.backgroundColor = theme.backgroundColor.cgColor
        settingsContainerView?.layer?.backgroundColor = theme.colors.bgBase.cgColor
        settingsHeaderView?.layer?.backgroundColor = theme.colors.bgPanel.cgColor
        settingsTitleLabel?.textColor = theme.colors.textPrimary
        settingsCloseButton?.contentTintColor = theme.colors.textPrimary
        settingsViewController?.apply(theme: theme)
        dashboardViewController?.apply(theme: theme)
    }

    private func preservingWindowFrame(_ update: () -> Void) {
        WindowFramePreservation.perform(
            window: view.window,
            layoutView: view,
            update: update
        )
    }

    private func buildSettingsScreen(in root: NSView, below topAnchor: NSLayoutYAxisAnchor) {
        settingsContainerView = NSView()
        settingsContainerView.wantsLayer = true
        settingsContainerView.isHidden = true
        settingsContainerView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(settingsContainerView, positioned: .above, relativeTo: nil)

        settingsHeaderView = NSView()
        settingsHeaderView.wantsLayer = true
        settingsHeaderView.translatesAutoresizingMaskIntoConstraints = false
        settingsContainerView.addSubview(settingsHeaderView)

        settingsTitleLabel = NSTextField(labelWithString: "Settings")
        settingsTitleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        settingsTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        settingsHeaderView.addSubview(settingsTitleLabel)

        settingsCloseButton = NSButton(title: "Done", target: self, action: #selector(settingsCloseClicked))
        settingsCloseButton.bezelStyle = .rounded
        settingsCloseButton.keyEquivalent = "\u{1b}"
        settingsCloseButton.keyEquivalentModifierMask = []
        settingsCloseButton.toolTip = "Return to the workspace (Esc)"
        settingsCloseButton.translatesAutoresizingMaskIntoConstraints = false
        settingsHeaderView.addSubview(settingsCloseButton)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        settingsHeaderView.addSubview(separator)

        NSLayoutConstraint.activate([
            settingsContainerView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            settingsContainerView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            settingsContainerView.topAnchor.constraint(equalTo: topAnchor),
            settingsContainerView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            settingsHeaderView.leadingAnchor.constraint(equalTo: settingsContainerView.leadingAnchor),
            settingsHeaderView.trailingAnchor.constraint(equalTo: settingsContainerView.trailingAnchor),
            settingsHeaderView.topAnchor.constraint(equalTo: settingsContainerView.topAnchor),
            settingsHeaderView.heightAnchor.constraint(equalToConstant: 52),

            settingsTitleLabel.leadingAnchor.constraint(equalTo: settingsHeaderView.leadingAnchor, constant: 20),
            settingsTitleLabel.centerYAnchor.constraint(equalTo: settingsHeaderView.centerYAnchor),

            settingsCloseButton.trailingAnchor.constraint(equalTo: settingsHeaderView.trailingAnchor, constant: -20),
            settingsCloseButton.centerYAnchor.constraint(equalTo: settingsHeaderView.centerYAnchor),

            separator.leadingAnchor.constraint(equalTo: settingsHeaderView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: settingsHeaderView.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: settingsHeaderView.bottomAnchor),
        ])
    }

    @objc private func settingsCloseClicked() {
        closeSettings()
    }
}

/// Invisible grab strip straddling the sidebar's trailing edge. It sits above both
/// the sidebar and the tiling layout so its cursor and clicks win over the
/// terminal surfaces underneath.
private final class SidebarResizeHandleView: NSView {
    static let grabWidth: CGFloat = 8

    /// Returns the width the drag starts from.
    var onDragBegan: (() -> CGFloat)?
    var onDragged: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    var onResetRequested: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    private var initialWidth: CGFloat = 0
    private var initialLocationX: CGFloat = 0
    private var isDragging = false

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .cursorUpdate, .mouseEnteredAndExited],
            owner: self
        ))
    }

    // Tracking-area cursor updates take precedence over the terminal surfaces
    // this strip overlaps, which cursor rects alone do not reliably win.
    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        guard !isDragging else { return }
        onHoverChanged?(false)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onResetRequested?()
            return
        }

        isDragging = true
        initialWidth = onDragBegan?() ?? 0
        // Window coordinates stay fixed while the handle itself moves with the drag.
        initialLocationX = event.locationInWindow.x
        onHoverChanged?(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        onDragged?(initialWidth + (event.locationInWindow.x - initialLocationX))
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        onDragEnded?()
        let isInside = bounds.contains(convert(event.locationInWindow, from: nil))
        onHoverChanged?(isInside)
    }
}

/// Restores native title-bar interactions for the portion of a full-size content
/// view that sits above the safe area. The visible application content covers the
/// rest of this view, so these interactions are limited to the empty title bar.
private final class MainContentRootView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.performZoom(nil)
            return
        }

        if event.clickCount == 1, let window {
            window.performDrag(with: event)
            return
        }

        super.mouseDown(with: event)
    }
}
