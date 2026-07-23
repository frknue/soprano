import AppKit

/// Renders the binary tree tiling layout as nested NSSplitViews.
///
/// Key design decisions:
/// - **Pane containers are cached** by pane ID in `paneContainers`. Creating a new
///   container is expensive (terminal views hold PTY state), so we never destroy them
///   unless the pane is actually removed from the layout.
/// - **Layout topology changes** (tracked by `AgentManager.layoutGeneration`) trigger
///   a full NSSplitView tree rebuild, but cached pane containers are detached and
///   reattached — not recreated.
/// - **Non-topology changes** (focus, agent status, tab switch) only update styling
///   (borders, header labels) via `updatePaneStyles()`.
final class SplitTreeView: NSView {
    typealias TerminalViewFactory = (TerminalTarget, TerminalConfig, Bool) -> NSView

    let agentManager: AgentManager
    let themeManager: ThemeManager
    private let terminalViewFactory: TerminalViewFactory
    private let destroyTerminalView: (NSView) -> Void
    private let restartTerminalView: (NSView) -> Void

    /// Cached pane container views keyed by pane ID.
    /// These survive layout rebuilds — only removed when the pane itself is closed.
    private var paneContainers: [String: PaneContainerView] = [:]
    /// Cached content views keyed by exact pane/tab target so even malformed
    /// restored sessions with duplicate tab IDs cannot alias terminal surfaces.
    private var tabContentViews: [TerminalTarget: NSView] = [:]

    /// The root NSSplitView (or single pane view) currently displayed.
    private var rootView: NSView?

    /// Last observed layout generation, to detect topology changes.
    private var lastLayoutGeneration: Int = -1
    /// Last restore generation whose terminal cache has been invalidated.
    private var lastWorkspaceRestoreGeneration: Int

    /// Observer ID for AgentManager notifications.
    private let observerId = "SplitTreeView"

    init(
        agentManager: AgentManager,
        themeManager: ThemeManager,
        terminalViewFactory: @escaping TerminalViewFactory = {
            target,
            config,
            startsSurface in
            TerminalSurfaceView(
                paneId: target.paneId,
                tabId: target.tabId,
                config: config,
                startsSurface: startsSurface
            )
        },
        destroyTerminalView: @escaping (NSView) -> Void = { view in
            (view as? TerminalSurfaceView)?.destroySurface()
        },
        restartTerminalView: @escaping (NSView) -> Void = { view in
            (view as? TerminalSurfaceView)?.recreateSurface()
        }
    ) {
        self.agentManager = agentManager
        self.themeManager = themeManager
        self.terminalViewFactory = terminalViewFactory
        self.destroyTerminalView = destroyTerminalView
        self.restartTerminalView = restartTerminalView
        self.lastWorkspaceRestoreGeneration = agentManager.workspaceRestoreGeneration
        super.init(frame: .zero)
        wantsLayer = true

        agentManager.addObserver(id: observerId) { [weak self] in
            self?.handleStateChange()
        }
        agentManager.addTerminalLifecycleObserver(id: observerId) { [weak self] action in
            self?.handleTerminalLifecycle(action)
        }

        rebuildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        agentManager.removeObserver(id: observerId)
        agentManager.removeTerminalLifecycleObserver(id: observerId)
    }

    // MARK: - State Change Handler

    private func handleStateChange() {
        let currentRestoreGeneration = agentManager.workspaceRestoreGeneration
        if currentRestoreGeneration != lastWorkspaceRestoreGeneration {
            lastWorkspaceRestoreGeneration = currentRestoreGeneration
            invalidateCachedTabContentViews()
        }

        pruneOrphanedTabContentViews()
        syncVisiblePaneContents()
        let currentGen = agentManager.layoutGeneration
        if currentGen != lastLayoutGeneration {
            rebuildLayout()
        } else {
            syncVisibleSplitPercentages()
            updatePaneStyles()
        }
        syncKeyboardFocus()
    }

    private func handleTerminalLifecycle(_ action: TerminalLifecycleAction) {
        let target = action.target
        switch action {
        case .stop:
            guard let view = tabContentViews[target] else { return }
            destroyTerminalView(view)

        case .restart:
            if let view = tabContentViews[target] {
                restartTerminalView(view)
                return
            }

            guard let tab = agentManager.panes[target.paneId]?.tabs.first(
                where: { $0.id == target.tabId }
            ) else { return }
            _ = contentViewForTab(tab, paneId: target.paneId)
        }
    }

    /// Keeps the window's first responder on the active pane's terminal.
    /// Without this, closing the focused pane leaves the window with no first
    /// responder and every keystroke is silently dropped (the app appears
    /// frozen), and pane navigation/splits move the visual focus but not
    /// keyboard input.
    /// Re-focus the active pane's terminal after the split tree becomes
    /// visible again (e.g. when the settings overlay closes).
    func restoreKeyboardFocus() {
        syncKeyboardFocus()
    }

    func changeActiveTerminalFontSize(delta: Int) {
        activeTerminalView()?.changeFontSize(delta: delta)
    }

    func resetActiveTerminalFontSize() {
        activeTerminalView()?.resetFontSize()
    }

    private func activeTerminalView() -> TerminalSurfaceView? {
        let paneId = agentManager.activePaneId
        guard let activeTab = agentManager.panes[paneId]?.activeTab,
              let contentView = tabContentViews[
                  TerminalTarget(paneId: paneId, tabId: activeTab.id)
              ]
        else {
            return nil
        }
        return findTerminalView(in: contentView)
    }

    private func syncKeyboardFocus() {
        // While the split tree is hidden (settings overlay open), leave the
        // first responder alone — focusing an invisible terminal would send
        // the user's typing into a hidden shell.
        guard !isHidden, let window else { return }
        guard let container = paneContainers[agentManager.activePaneId],
              let terminalView = findTerminalView(in: container)
        else { return }

        if let responder = window.firstResponder as? NSView {
            if responder === terminalView { return }
            // Leave focus alone when it's on a live view outside the split
            // tree (settings form fields, etc.). A responder detached from
            // this window (e.g. its pane was just closed) is dead — reclaim.
            if responder.window === window, !responder.isDescendant(of: self) { return }
        }

        window.makeFirstResponder(terminalView)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            syncKeyboardFocus()
        }
    }

    // MARK: - Full Layout Rebuild

    /// Rebuilds the NSSplitView tree from the current layout.
    /// Pane containers are reused from cache — never destroyed unless the pane is gone.
    private func rebuildLayout() {
        lastLayoutGeneration = agentManager.layoutGeneration

        // Detach old root (doesn't destroy cached pane containers — they're retained in dict)
        rootView?.removeFromSuperview()
        rootView = nil

        guard let layout = agentManager.layout else {
            let placeholder = makePlaceholder("No panes open")
            mountRootView(placeholder)
            pruneOrphanedContainers()
            return
        }

        // Maximize renders a single-leaf effective layout. Orphan pruning
        // below still uses the real layout, so hidden panes' containers
        // (and their PTYs) survive.
        let effectiveLayout: SplitNode
        if let maximizedId = agentManager.maximizedPaneId, agentManager.panes[maximizedId] != nil {
            effectiveLayout = .leaf(maximizedId)
        } else {
            effectiveLayout = layout
        }
        let view = buildView(for: effectiveLayout, at: [])
        mountRootView(view)
        pruneOrphanedContainers()
        updatePaneStyles()
    }

    /// Recursively builds the NSSplitView tree. Leaf nodes pull from the container cache.
    private func buildView(for node: SplitNode, at path: [SplitBranchSide]) -> NSView {
        switch node {
        case .leaf(let paneId):
            return containerForPane(paneId)

        case .split(let branch):
            let splitView = ThemedSplitView(themeManager: themeManager, branchPath: path)
            splitView.isVertical = branch.direction == .horizontal
            splitView.dividerStyle = .thin
            splitView.translatesAutoresizingMaskIntoConstraints = false
            splitView.onDividerPercentageChanged = { [weak self] branchPath, percentage in
                self?.agentManager.setSplitPercentage(at: branchPath, to: percentage)
            }

            let firstView = buildView(for: branch.first, at: path + [.first])
            let secondView = buildView(for: branch.second, at: path + [.second])

            splitView.addSubview(firstView)
            splitView.addSubview(secondView)

            splitView.applyModelPercentage(branch.splitPercentage)

            return splitView
        }
    }

    // MARK: - Pane Container Cache

    /// Returns the cached container for a pane, creating one if needed.
    private func containerForPane(_ paneId: String) -> PaneContainerView {
        if let existing = paneContainers[paneId] {
            // Detach from old parent so it can be reparented
            existing.removeFromSuperview()
            return existing
        }

        let container = PaneContainerView(
            paneId: paneId,
            agentManager: agentManager,
            themeManager: themeManager
        )
        syncContainerContent(container, for: paneId)
        paneContainers[paneId] = container
        return container
    }

    /// Remove containers for panes that no longer exist in the layout.
    private func pruneOrphanedContainers() {
        // Keep detached containers for panes in inactive logical windows so
        // switching windows preserves their terminal surfaces and PTY state.
        let activeIds = Set(agentManager.panes.keys)
        let orphanIds = paneContainers.keys.filter { !activeIds.contains($0) }
        for id in orphanIds {
            if let container = paneContainers[id] {
                clearFirstResponderIfNeeded(in: container)
                if let terminalView = findTerminalView(in: container) {
                    terminalView.destroySurface()
                }
            }
            paneContainers[id]?.removeFromSuperview()
            paneContainers.removeValue(forKey: id)
        }
    }

    private func pruneOrphanedTabContentViews() {
        let activeTargets = Set(agentManager.panes.values.flatMap { pane in
            pane.tabs.map { TerminalTarget(paneId: pane.id, tabId: $0.id) }
        })
        let orphanTargets = tabContentViews.keys.filter { !activeTargets.contains($0) }
        for target in orphanTargets {
            if let view = tabContentViews[target] {
                clearFirstResponderIfNeeded(in: view)
                if let terminalView = findTerminalView(in: view) {
                    terminalView.destroySurface()
                }
                view.removeFromSuperview()
            }
            tabContentViews.removeValue(forKey: target)
        }
    }

    private func invalidateCachedTabContentViews() {
        for view in tabContentViews.values {
            clearFirstResponderIfNeeded(in: view)
            findTerminalView(in: view)?.destroySurface()
            view.removeFromSuperview()
        }
        tabContentViews.removeAll()
    }

    private func syncVisiblePaneContents() {
        for (paneId, container) in paneContainers {
            syncContainerContent(container, for: paneId)
        }
    }

    private func syncContainerContent(_ container: PaneContainerView, for paneId: String) {
        guard let tab = agentManager.panes[paneId]?.activeTab else {
            container.setContentView(makePlaceholderContent(), tabId: nil)
            return
        }

        let content = contentViewForTab(tab, paneId: paneId)
        container.setContentView(content, tabId: tab.id)
    }

    private func contentViewForTab(_ tab: PaneTab, paneId: String) -> NSView {
        let target = TerminalTarget(paneId: paneId, tabId: tab.id)
        if let existing = tabContentViews[target] {
            return existing
        }

        let view: NSView
        switch tab.type {
        case .terminal, .agent:
            let terminalConfig: TerminalConfig
            if tab.type == .agent,
               let agent = tab.agent,
               let profile = DefaultAgents.profile(for: agent.profileId)
            {
                terminalConfig = .forAgent(
                    profile,
                    cwd: tab.cwd,
                    paneId: paneId,
                    tabId: tab.id
                )
            } else {
                terminalConfig = TerminalConfig(workingDirectory: tab.cwd)
            }

            let startsSurface = tab.type != .agent || tab.agent?.status != .stopped
            let terminalView = terminalViewFactory(
                target,
                terminalConfig,
                startsSurface
            )
            if let terminalView = terminalView as? TerminalSurfaceView {
                terminalView.onFocusRequested = { [weak self] in
                    self?.agentManager.focusTab(paneId: paneId, tabId: tab.id)
                }
                terminalView.onTitleChanged = { [weak self] title in
                    self?.agentManager.renameTab(paneId, tabId: tab.id, to: title)
                }
                terminalView.onAgentInputSubmitted = { [weak self] in
                    guard self?.agentManager.agent(
                        paneId: paneId,
                        tabId: tab.id
                    ) != nil else { return }
                    self?.agentManager.updateAgentStatus(
                        paneId: paneId,
                        tabId: tab.id,
                        status: .running,
                        needsAttention: false
                    )
                }
            }
            if tab.agent?.profileId == "codex" {
                // Codex exposes completion and approval notifications but no
                // trust-free initial-ready event. Its TUI is normally ready by
                // this point; later lifecycle events remain authoritative.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    self?.agentManager.markAgentReadyIfStarting(paneId: paneId, tabId: tab.id)
                }
            }
            view = terminalView
        }

        tabContentViews[target] = view
        return view
    }

    private func findTerminalView(in view: NSView) -> TerminalSurfaceView? {
        if let terminalView = view as? TerminalSurfaceView {
            return terminalView
        }

        for subview in view.subviews {
            if let found = findTerminalView(in: subview) {
                return found
            }
        }

        return nil
    }

    private func clearFirstResponderIfNeeded(in container: NSView) {
        guard let window = container.window,
              let responderView = window.firstResponder as? NSView,
              responderView.isDescendant(of: container)
        else {
            return
        }

        window.makeFirstResponder(nil)
    }

    // MARK: - Style Updates (No Rebuild)

    /// Applies model-only percentage changes (for example keyboard resizing)
    /// to the existing AppKit split tree without rebuilding terminal surfaces.
    private func syncVisibleSplitPercentages() {
        guard agentManager.maximizedPaneId == nil,
              let layout = agentManager.layout,
              let rootView
        else { return }

        syncSplitPercentages(in: rootView, layout: layout)
    }

    private func syncSplitPercentages(in view: NSView, layout: SplitNode) {
        if let splitView = view as? ThemedSplitView,
           let percentage = splitPercentage(in: layout, at: splitView.branchPath)
        {
            splitView.applyModelPercentage(percentage)
        }

        for subview in view.subviews {
            syncSplitPercentages(in: subview, layout: layout)
        }
    }

    private func splitPercentage(in node: SplitNode, at path: [SplitBranchSide]) -> Double? {
        var current = node
        for side in path {
            guard case .split(let branch) = current else { return nil }
            current = side == .first ? branch.first : branch.second
        }
        guard case .split(let branch) = current else { return nil }
        return branch.splitPercentage
    }

    /// Updates visual state (borders, headers) without rebuilding the view tree.
    private func updatePaneStyles() {
        for (_, container) in paneContainers {
            container.update()
        }
    }

    func refreshTheme() {
        rebuildLayout()
    }

    // MARK: - Helpers

    private func mountRootView(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        rootView = view
    }

    private func makePlaceholder(_ text: String) -> NSView {
        let theme = themeManager.currentTheme
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = theme.backgroundColor.cgColor

        let label = NSTextField(labelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        label.textColor = theme.colors.textMuted
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        return view
    }

    private func makePlaceholderContent() -> NSView {
        let theme = themeManager.currentTheme
        let placeholder = NSView()
        placeholder.wantsLayer = true
        placeholder.layer?.backgroundColor = theme.colors.bgBase.cgColor

        let label = NSTextField(labelWithString: "Empty")
        label.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        label.textColor = theme.colors.textMuted
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        placeholder.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: placeholder.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: placeholder.centerYAnchor),
        ])

        return placeholder
    }
}

// MARK: - PaneContainerView

/// A cached container for a single pane. Holds the header and content area.
/// This view survives layout rebuilds — it's detached and reattached, never destroyed.
final class PaneContainerView: NSView {
    let paneId: String
    let agentManager: AgentManager
    let themeManager: ThemeManager

    private var headerView: PaneHeaderView
    private var contentView: NSView
    private var displayedTabId: String?

    init(paneId: String, agentManager: AgentManager, themeManager: ThemeManager) {
        self.paneId = paneId
        self.agentManager = agentManager
        self.themeManager = themeManager

        self.headerView = PaneHeaderView(
            paneId: paneId,
            agentManager: agentManager,
            themeManager: themeManager
        )
        self.headerView.onFocusRequested = { [weak agentManager] in
            agentManager?.focusPane(paneId)
        }

        let placeholder = NSView()
        placeholder.wantsLayer = true
        placeholder.layer?.backgroundColor = themeManager.currentTheme.colors.bgBase.cgColor
        self.contentView = placeholder

        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = themeManager.currentTheme.panelColor.cgColor

        setupSubviews()
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Replaces the content area (e.g., swapping placeholder for a terminal view).
    func setContentView(_ newContent: NSView, tabId: String?) {
        if contentView === newContent, displayedTabId == tabId {
            return
        }

        clearFirstResponderIfNeeded(in: contentView)
        contentView.removeFromSuperview()
        contentView = newContent
        displayedTabId = tabId
        newContent.translatesAutoresizingMaskIntoConstraints = false
        addSubview(newContent)
        NSLayoutConstraint.activate([
            newContent.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            newContent.leadingAnchor.constraint(equalTo: leadingAnchor),
            newContent.trailingAnchor.constraint(equalTo: trailingAnchor),
            newContent.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func updateHeader() {
        headerView.update()
    }

    func update() {
        let theme = themeManager.currentTheme
        let isActive = paneId == agentManager.activePaneId
        let needsAttention = agentManager.panes[paneId]?.tabs.contains {
            $0.agent?.needsAttention == true
        } ?? false
        layer?.borderWidth = needsAttention ? 2 : (isActive ? 1 : 0)
        layer?.borderColor = if needsAttention {
            theme.colors.blue.cgColor
        } else if isActive {
            theme.accentColor.cgColor
        } else {
            nil
        }
        headerView.update()
    }

    private func setupSubviews() {
        headerView.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerView)
        addSubview(contentView)

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: topAnchor),
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 32),

            contentView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func clearFirstResponderIfNeeded(in view: NSView) {
        guard let window,
              let responderView = window.firstResponder as? NSView,
              responderView.isDescendant(of: view)
        else {
            return
        }

        window.makeFirstResponder(nil)
    }

}

// MARK: - ThemedSplitView

/// NSSplitView subclass that themes the divider and applies split percentages.
final class ThemedSplitView: NSSplitView, NSSplitViewDelegate {
    let themeManager: ThemeManager
    let branchPath: [SplitBranchSide]
    var onDividerPercentageChanged: (([SplitBranchSide], Double) -> Void)?

    /// The desired split percentage (0–100) from the SplitNode model.
    private(set) var desiredSplitPercentage: Double = 50.0

    /// Whether we've applied the initial split position.
    private var hasAppliedInitialPosition = false
    /// Prevents `setPosition` delegate callbacks from being written back to the model.
    private var isApplyingModelPercentage = false

    init(themeManager: ThemeManager, branchPath: [SplitBranchSide]) {
        self.themeManager = themeManager
        self.branchPath = branchPath
        super.init(frame: .zero)
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var dividerColor: NSColor {
        themeManager.currentTheme.colors.borderSubtle
    }

    override var dividerThickness: CGFloat { 1 }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyInitialPosition()
    }

    override func layout() {
        super.layout()
        applyInitialPosition()
    }

    private func applyInitialPosition() {
        guard !hasAppliedInitialPosition, subviews.count >= 2 else { return }
        applyModelPercentage(desiredSplitPercentage)
    }

    func applyModelPercentage(_ percentage: Double) {
        let clampedPercentage = max(10, min(90, percentage))
        if hasAppliedInitialPosition,
           abs(desiredSplitPercentage - clampedPercentage) < 0.0001
        {
            return
        }
        desiredSplitPercentage = clampedPercentage
        guard subviews.count >= 2 else { return }
        let totalSize = isVertical ? bounds.width : bounds.height
        guard totalSize > 0 else { return }

        let availableSize = max(0, totalSize - dividerThickness)
        let position = availableSize * CGFloat(desiredSplitPercentage / 100.0)
        isApplyingModelPercentage = true
        defer { isApplyingModelPercentage = false }
        setPosition(position, ofDividerAt: 0)
        hasAppliedInitialPosition = true
    }

    static func percentageForDividerPosition(
        _ position: Double,
        totalSize: Double,
        dividerThickness: Double
    ) -> Double {
        let availableSize = totalSize - dividerThickness
        guard availableSize > 0 else { return 50 }
        return max(10, min(90, position / availableSize * 100))
    }

    // MARK: - NSSplitViewDelegate

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard notification.userInfo?["NSSplitViewDividerIndex"] != nil,
              !isApplyingModelPercentage,
              hasAppliedInitialPosition,
              subviews.count >= 2
        else { return }

        let position = isVertical ? subviews[0].frame.width : subviews[0].frame.height
        let totalSize = isVertical ? bounds.width : bounds.height
        let percentage = Self.percentageForDividerPosition(
            Double(position),
            totalSize: Double(totalSize),
            dividerThickness: Double(dividerThickness)
        )
        desiredSplitPercentage = percentage
        onDividerPercentageChanged?(branchPath, percentage)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        let availableSize = max(0, (isVertical ? bounds.width : bounds.height) - dividerThickness)
        return max(proposedMinimumPosition, availableSize * 0.10)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        let availableSize = max(0, (isVertical ? bounds.width : bounds.height) - dividerThickness)
        return min(proposedMaximumPosition, availableSize * 0.90)
    }

    func splitView(
        _ splitView: NSSplitView,
        canCollapseSubview subview: NSView
    ) -> Bool {
        false
    }
}
