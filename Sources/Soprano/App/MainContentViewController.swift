import AppKit

/// Root view controller managing the sidebar + tiling layout + status bar composition.
final class MainContentViewController: NSViewController {
    let agentManager: AgentManager
    let sessionManager: SessionManager
    let themeManager: ThemeManager
    private let onSettingsRequested: (() -> Void)?

    private var sidebarView: SidebarView!
    private var splitTreeView: SplitTreeView!
    private var statusBarView: StatusBarView!
    private var sidebarWidthConstraint: NSLayoutConstraint!

    private static let collapsedSidebarWidth: CGFloat = 48
    private static let expandedSidebarWidth: CGFloat = 248

    init(
        agentManager: AgentManager,
        sessionManager: SessionManager,
        themeManager: ThemeManager,
        onSettingsRequested: (() -> Void)? = nil
    ) {
        self.agentManager = agentManager
        self.sessionManager = sessionManager
        self.themeManager = themeManager
        self.onSettingsRequested = onSettingsRequested
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
        sidebarView = SidebarView(agentManager: agentManager, sessionManager: sessionManager, themeManager: themeManager)
        sidebarView.onSettingsRequested = onSettingsRequested
        sidebarView.onExpandedChanged = { [weak self] expanded in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.sidebarWidthConstraint.animator().constant = expanded
                    ? Self.expandedSidebarWidth
                    : Self.collapsedSidebarWidth
                self.view.layoutSubtreeIfNeeded()
            }
        }
        sidebarView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebarView, positioned: .above, relativeTo: splitTreeView)

        // Status bar
        statusBarView = StatusBarView(agentManager: agentManager, themeManager: themeManager)
        statusBarView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(statusBarView)

        // Layout
        sidebarWidthConstraint = sidebarView.widthAnchor.constraint(
            equalToConstant: Self.collapsedSidebarWidth
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

        self.view = root
        applyTheme()
    }

    func toggleSidebar() {
        if sidebarView.activeSection != nil {
            sidebarView.activeSection = nil
        } else {
            sidebarView.activeSection = .agents
        }
    }

    func setKeybindingMode(_ mode: KeybindingState) {
        statusBarView.setKeybindingMode(mode)
    }

    private func applyTheme() {
        let theme = themeManager.currentTheme
        view.layer?.backgroundColor = theme.backgroundColor.cgColor
    }
}
