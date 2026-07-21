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

    func refreshTheme() {
        applyTheme()
        sidebarView.refreshTheme()
        splitTreeView.refreshTheme()
        statusBarView.refreshTheme()
    }

    private func applyTheme() {
        let theme = themeManager.currentTheme
        view.layer?.backgroundColor = theme.backgroundColor.cgColor
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
