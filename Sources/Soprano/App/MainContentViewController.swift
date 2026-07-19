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
    private var settingsContainerView: NSView!
    private var settingsHeaderView: NSView!
    private var settingsHostView: NSView!
    private var settingsTitleLabel: NSTextField!
    private var settingsCloseButton: NSButton!
    private var sidebarWidthConstraint: NSLayoutConstraint!
    private var settingsViewController: SettingsViewController?

    private static let sidebarWidth: CGFloat = 220
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
        let root = NSView()
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

        settingsContainerView = NSView()
        settingsContainerView.wantsLayer = true
        settingsContainerView.layer?.cornerRadius = 12
        settingsContainerView.layer?.borderWidth = 1
        settingsContainerView.layer?.masksToBounds = true
        settingsContainerView.isHidden = true
        settingsContainerView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(settingsContainerView, positioned: .above, relativeTo: splitTreeView)

        settingsHeaderView = NSView()
        settingsHeaderView.wantsLayer = true
        settingsHeaderView.translatesAutoresizingMaskIntoConstraints = false
        settingsContainerView.addSubview(settingsHeaderView)

        settingsTitleLabel = NSTextField(labelWithString: "Settings")
        settingsTitleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        settingsTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        settingsHeaderView.addSubview(settingsTitleLabel)

        settingsCloseButton = NSButton(title: "Done", target: self, action: #selector(closeSettings))
        settingsCloseButton.bezelStyle = .rounded
        settingsCloseButton.translatesAutoresizingMaskIntoConstraints = false
        settingsHeaderView.addSubview(settingsCloseButton)

        settingsHostView = NSView()
        settingsHostView.translatesAutoresizingMaskIntoConstraints = false
        settingsContainerView.addSubview(settingsHostView)

        // Layout
        sidebarWidthConstraint = sidebarView.widthAnchor.constraint(
            equalToConstant: sidebarVisible ? Self.sidebarWidth : 0
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

            settingsContainerView.leadingAnchor.constraint(equalTo: splitTreeView.leadingAnchor, constant: 18),
            settingsContainerView.trailingAnchor.constraint(equalTo: splitTreeView.trailingAnchor, constant: -18),
            settingsContainerView.topAnchor.constraint(equalTo: splitTreeView.topAnchor, constant: 18),
            settingsContainerView.bottomAnchor.constraint(equalTo: splitTreeView.bottomAnchor, constant: -18),

            settingsHeaderView.leadingAnchor.constraint(equalTo: settingsContainerView.leadingAnchor),
            settingsHeaderView.trailingAnchor.constraint(equalTo: settingsContainerView.trailingAnchor),
            settingsHeaderView.topAnchor.constraint(equalTo: settingsContainerView.topAnchor),
            settingsHeaderView.heightAnchor.constraint(equalToConstant: 52),

            settingsTitleLabel.leadingAnchor.constraint(equalTo: settingsHeaderView.leadingAnchor, constant: 18),
            settingsTitleLabel.centerYAnchor.constraint(equalTo: settingsHeaderView.centerYAnchor),

            settingsCloseButton.trailingAnchor.constraint(equalTo: settingsHeaderView.trailingAnchor, constant: -16),
            settingsCloseButton.centerYAnchor.constraint(equalTo: settingsHeaderView.centerYAnchor),

            settingsHostView.leadingAnchor.constraint(equalTo: settingsContainerView.leadingAnchor),
            settingsHostView.trailingAnchor.constraint(equalTo: settingsContainerView.trailingAnchor),
            settingsHostView.topAnchor.constraint(equalTo: settingsHeaderView.bottomAnchor),
            settingsHostView.bottomAnchor.constraint(equalTo: settingsContainerView.bottomAnchor),

            // Status bar: full width, bottom
            statusBarView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBarView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBarView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusBarView.heightAnchor.constraint(equalToConstant: 28),
        ])

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
                ? Self.sidebarWidth
                : 0
            self.view.layoutSubtreeIfNeeded()
        }
    }

    func setKeybindingMode(_ mode: KeybindingState) {
        statusBarView.setKeybindingMode(mode)
    }

    func refreshTheme() {
        applyTheme()
        sidebarView.refreshTheme()
        splitTreeView.refreshTheme()
        statusBarView.refreshTheme()
    }

    func showSettings(
        settings: AppSettings,
        keybindingConfig: KeyBindingConfig,
        onSettingsChanged: @escaping (AppSettings) -> Void,
        onKeybindingConfigChanged: @escaping (KeyBindingConfig) -> Void
    ) {
        if let settingsViewController {
            settingsViewController.onSettingsChanged = onSettingsChanged
            settingsViewController.onKeybindingConfigChanged = onKeybindingConfigChanged
            settingsViewController.apply(theme: themeManager.currentTheme)
        } else {
            let controller = SettingsViewController(
                themeManager: themeManager,
                settings: settings,
                keybindingConfig: keybindingConfig
            )
            controller.onSettingsChanged = onSettingsChanged
            controller.onKeybindingConfigChanged = onKeybindingConfigChanged
            addChild(controller)
            controller.view.translatesAutoresizingMaskIntoConstraints = false
            settingsHostView.addSubview(controller.view)
            NSLayoutConstraint.activate([
                controller.view.leadingAnchor.constraint(equalTo: settingsHostView.leadingAnchor),
                controller.view.trailingAnchor.constraint(equalTo: settingsHostView.trailingAnchor),
                controller.view.topAnchor.constraint(equalTo: settingsHostView.topAnchor),
                controller.view.bottomAnchor.constraint(equalTo: settingsHostView.bottomAnchor),
            ])
            settingsViewController = controller
        }

        splitTreeView.isHidden = true
        settingsContainerView.isHidden = false
    }

    @objc private func closeSettings() {
        settingsContainerView.isHidden = true
        splitTreeView.isHidden = false
        // Hiding the split tree dropped the terminal from first responder;
        // without this, every keystroke after closing settings goes nowhere.
        splitTreeView.restoreKeyboardFocus()
    }

    private func applyTheme() {
        let theme = themeManager.currentTheme
        view.layer?.backgroundColor = theme.backgroundColor.cgColor
        settingsContainerView.layer?.backgroundColor = theme.colors.bgBase.cgColor
        settingsContainerView.layer?.borderColor = theme.colors.borderSubtle.cgColor
        settingsHeaderView.layer?.backgroundColor = theme.colors.bgPanel.cgColor
        settingsTitleLabel.textColor = theme.colors.textPrimary
        settingsViewController?.apply(theme: theme)
    }
}
