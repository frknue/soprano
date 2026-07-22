import AppKit

/// Root view controller managing the sidebar + tiling layout + status bar composition.
final class MainContentViewController: NSViewController {
    let agentManager: AgentManager
    let sessionManager: SessionManager
    let themeManager: ThemeManager
    let gitBranchMonitor: GitBranchMonitor
    private let onSettingsRequested: (() -> Void)?
    private var sidebarVisible: Bool

    private var sidebarView: SidebarView!
    private var splitTreeView: SplitTreeView!
    private var statusBarView: StatusBarView!
    private var sidebarWidthConstraint: NSLayoutConstraint!
    private var settingsContainerView: NSView!
    private var settingsHeaderView: NSView!
    private var settingsTitleLabel: NSTextField!
    private var settingsCloseButton: NSButton!
    private var settingsViewController: SettingsViewController?
    private var settingsViewConstraints: [NSLayoutConstraint] = []

    private static let sidebarVisibleKey = "soprano-sidebar-visible"

    init(
        agentManager: AgentManager,
        sessionManager: SessionManager,
        themeManager: ThemeManager,
        gitBranchMonitor: GitBranchMonitor,
        onSettingsRequested: (() -> Void)? = nil
    ) {
        self.agentManager = agentManager
        self.sessionManager = sessionManager
        self.themeManager = themeManager
        self.gitBranchMonitor = gitBranchMonitor
        self.onSettingsRequested = onSettingsRequested
        self.sidebarVisible =
            UserDefaults.standard.object(forKey: Self.sidebarVisibleKey) as? Bool ?? true
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
        splitTreeView = SplitTreeView(agentManager: agentManager, themeManager: themeManager)
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
        sidebarView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebarView, positioned: .above, relativeTo: splitTreeView)

        // Status bar
        statusBarView = StatusBarView(agentManager: agentManager, themeManager: themeManager)
        statusBarView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(statusBarView)

        // Layout
        sidebarWidthConstraint = sidebarView.widthAnchor.constraint(
            equalToConstant: sidebarVisible ? SidebarView.width : 0
        )

        NSLayoutConstraint.activate([
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
        UserDefaults.standard.set(sidebarVisible, forKey: Self.sidebarVisibleKey)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.sidebarWidthConstraint.animator().constant = self.sidebarVisible
                ? SidebarView.width
                : 0
            self.view.layoutSubtreeIfNeeded()
        }
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

    func showSettings(
        settings: AppSettings,
        keybindingConfig: KeyBindingConfig,
        onSettingsChanged: @escaping (AppSettings) -> Void,
        onKeybindingConfigChanged: @escaping (KeyBindingConfig) -> Void
    ) {
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

        settingsViewController.onSettingsChanged = onSettingsChanged
        settingsViewController.onKeybindingConfigChanged = onKeybindingConfigChanged
        settingsViewController.apply(theme: themeManager.currentTheme)

        splitTreeView.isHidden = true
        settingsContainerView.isHidden = false
        view.window?.makeFirstResponder(settingsCloseButton)
    }

    func closeSettings() {
        guard !settingsContainerView.isHidden else { return }
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

        splitTreeView.restoreKeyboardFocus()
    }

    func refreshTheme() {
        applyTheme()
        sidebarView.refreshTheme()
        splitTreeView.refreshTheme()
        statusBarView.refreshTheme()
    }

    private func applyTheme() {
        let theme = themeManager.currentTheme
        view.layer?.backgroundColor = theme.backgroundColor.cgColor
        settingsContainerView?.layer?.backgroundColor = theme.colors.bgBase.cgColor
        settingsHeaderView?.layer?.backgroundColor = theme.colors.bgPanel.cgColor
        settingsTitleLabel?.textColor = theme.colors.textPrimary
        settingsCloseButton?.contentTintColor = theme.colors.textPrimary
        settingsViewController?.apply(theme: theme)
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
