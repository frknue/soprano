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
///   (attention frames, unfocused veils, headers) via `updatePaneStyles()`.
final class SplitTreeView: NSView {
    typealias TerminalViewFactory = (TerminalTarget, TerminalConfig, Bool) -> NSView
    typealias CodexReadinessScheduler = (
        @escaping @MainActor @Sendable () -> Void
    ) -> Void

    let agentManager: AgentManager
    let themeManager: ThemeManager
    private let terminalViewFactory: TerminalViewFactory
    private let destroyTerminalView: (NSView) -> Void
    private let restartTerminalView: (NSView, TerminalConfig) -> Bool
    private let terminalViewHasLiveSurface: (NSView) -> Bool
    private let terminalVisibleText: (NSView) -> String?
    private let terminalPromptSubmitter: (NSView, String) -> Bool
    private let terminalIsRunningCommand: (NSView) -> Bool
    private let scheduleCodexReadiness: CodexReadinessScheduler
    var onCopyModeStateChanged: ((KeybindingState) -> Void)?

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
    private var copyModeTarget: TerminalTarget?
    private var isSynchronizingKeyboardFocus = false
    nonisolated(unsafe) private var runningCommandTimer: Timer?

    /// Seconds between samples of which terminals are running a command.
    static let runningCommandSampleInterval: TimeInterval = 1

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
        restartTerminalView: @escaping (NSView, TerminalConfig) -> Bool = { view, config in
            guard let terminalView = view as? TerminalSurfaceView else { return false }
            return terminalView.recreateSurface(config: config)
        },
        terminalViewHasLiveSurface: @escaping (NSView) -> Bool = { view in
            (view as? TerminalSurfaceView)?.surface != nil
        },
        terminalVisibleText: @escaping (NSView) -> String? = { view in
            (view as? TerminalSurfaceView)?.visibleText()
        },
        terminalPromptSubmitter: @escaping (NSView, String) -> Bool = { view, prompt in
            (view as? TerminalSurfaceView)?.submitText(prompt) ?? false
        },
        terminalIsRunningCommand: @escaping (NSView) -> Bool = { view in
            (view as? TerminalSurfaceView)?.isRunningCommand() ?? false
        },
        scheduleCodexReadiness: @escaping CodexReadinessScheduler = { callback in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                callback()
            }
        }
    ) {
        self.agentManager = agentManager
        self.themeManager = themeManager
        self.terminalViewFactory = terminalViewFactory
        self.destroyTerminalView = destroyTerminalView
        self.restartTerminalView = restartTerminalView
        self.terminalViewHasLiveSurface = terminalViewHasLiveSurface
        self.terminalVisibleText = terminalVisibleText
        self.terminalPromptSubmitter = terminalPromptSubmitter
        self.terminalIsRunningCommand = terminalIsRunningCommand
        self.scheduleCodexReadiness = scheduleCodexReadiness
        self.lastWorkspaceRestoreGeneration = agentManager.workspaceRestoreGeneration
        super.init(frame: .zero)
        wantsLayer = true

        agentManager.addObserver(id: observerId) { [weak self] change in
            self?.handleStateChange(change)
        }
        agentManager.addTerminalLifecycleObserver(id: observerId) { [weak self] action in
            self?.handleTerminalLifecycle(action)
        }

        rebuildLayout()
        runningCommandTimer = Timer.scheduledTimer(
            withTimeInterval: Self.runningCommandSampleInterval,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sampleRunningCommands()
            }
        }
        runningCommandTimer?.tolerance = 0.2
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        runningCommandTimer?.invalidate()
        agentManager.removeObserver(id: observerId)
        agentManager.removeTerminalLifecycleObserver(id: observerId)
    }

    // MARK: - Running Commands

    /// Publishes which terminals, in every window, are running a command.
    /// Ghostty reports no action when a command starts, so the timer polls.
    func sampleRunningCommands() {
        agentManager.setRunningCommandTargets(Set(
            tabContentViews.compactMap { target, view in
                terminalIsRunningCommand(view) ? target : nil
            }
        ))
    }

    /// Shell integration reported the command's end: clear it without waiting
    /// for the next sample.
    private func clearRunningCommand(at target: TerminalTarget) {
        var targets = agentManager.runningCommandTargets
        targets.remove(target)
        agentManager.setRunningCommandTargets(targets)
    }

    // MARK: - State Change Handler

    private func handleStateChange(_ change: AgentManagerChange) {
        switch change {
        case .model:
            handleStateChange()

        case .tabTitle(let target):
            paneContainers[target.paneId]?.updateHeader()

        case .tabWorkingDirectory, .browserURL:
            break

        case .document(let target):
            // Editor views follow their document's own location; a Markdown
            // reader is told to load the new file and a diff view is rebuilt.
            paneContainers[target.paneId]?.updateHeader()
            guard let tab = agentManager.panes[target.paneId]?.tabs.first(
                where: { $0.id == target.tabId }
            ),
                  let value = tab.url,
                  let fileURL = URL(string: value),
                  fileURL.isFileURL
            else { return }
            if tab.isDiff {
                tabContentViews[target] = nil
                if let container = paneContainers[target.paneId] {
                    syncContainerContent(container, for: target.paneId)
                }
                return
            }
            MarkdownPaneRegistry.shared.view(for: target)?.openDocument(
                fileURL,
                recordHistory: true
            )
        }
    }

    private func handleStateChange() {
        cancelCopyModeOutsideActiveTerminal()
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
            destroyTerminalSurface(in: view)

        case .restart:
            guard let tab = agentManager.panes[target.paneId]?.tabs.first(
                where: { $0.id == target.tabId }
            ) else { return }
            if let view = tabContentViews[target] {
                guard restartTerminalView(view, terminalConfig(for: tab, paneId: target.paneId))
                else { return }
                scheduleCodexReadinessIfNeeded(for: target)
                return
            }

            _ = contentViewForTab(tab, paneId: target.paneId)
        }
    }

    /// Keeps the window's first responder on the active pane's content.
    /// Without this, closing the focused pane leaves the window with no first
    /// responder and every keystroke is silently dropped (the app appears
    /// frozen), and pane navigation/splits move the visual focus but not
    /// keyboard input.
    /// Re-focus the active pane after the split tree becomes
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

    func beginActiveTerminalCopyMode() {
        activeTerminalView()?.beginCopyMode()
    }

    func terminalInteractionState(
        for target: TerminalTarget
    ) -> TerminalInteractionState {
        guard let contentView = tabContentViews[target],
              terminalViewHasLiveSurface(contentView)
        else {
            return .unavailable
        }
        return TerminalInteractionState(
            isAvailable: true,
            visibleText: terminalVisibleText(contentView) ?? ""
        )
    }

    @discardableResult
    func submitAgentPrompt(
        _ prompt: String,
        to target: TerminalTarget
    ) -> Bool {
        guard let contentView = tabContentViews[target],
              terminalViewHasLiveSurface(contentView)
        else {
            return false
        }
        guard terminalPromptSubmitter(contentView, prompt) else { return false }
        agentManager.updateAgentStatus(
            paneId: target.paneId,
            tabId: target.tabId,
            status: .running,
            needsAttention: false
        )
        return true
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
        // first responder alone — focusing invisible content would send the
        // user's typing into a hidden terminal or browser.
        guard !isHidden, let window else { return }
        guard !isSynchronizingKeyboardFocus else { return }
        isSynchronizingKeyboardFocus = true
        defer { isSynchronizingKeyboardFocus = false }

        guard let container = paneContainers[agentManager.activePaneId] else { return }

        if let responder = window.firstResponder as? NSView {
            if responder === container || responder.isDescendant(of: container) { return }
            // Leave focus alone when it's on a live view outside the split
            // tree (settings form fields, etc.). A responder detached from
            // this window (e.g. its pane was just closed) is dead — reclaim.
            if responder.window === window, !responder.isDescendant(of: self) { return }
        }

        if let terminalView = findTerminalView(in: container) {
            window.makeFirstResponder(terminalView)
        } else if let markdownView = findMarkdownView(in: container) {
            markdownView.focusPreferredControl()
        } else if let editorView = findEditorView(in: container) {
            editorView.focusPreferredControl()
        } else if let diffView = findDiffView(in: container) {
            diffView.focusPreferredControl()
        } else {
            findBrowserView(in: container)?.focusPreferredControl()
        }
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
                destroyTerminalSurface(in: container)
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
                discardCachedTabContentView(view)
            }
            tabContentViews.removeValue(forKey: target)
        }
    }

    private func invalidateCachedTabContentViews() {
        for view in tabContentViews.values {
            discardCachedTabContentView(view)
        }
        tabContentViews.removeAll()
    }

    private func discardCachedTabContentView(_ view: NSView) {
        clearFirstResponderIfNeeded(in: view)
        destroyTerminalSurface(in: view)
        view.removeFromSuperview()
    }

    private func destroyTerminalSurface(in view: NSView) {
        destroyTerminalView(findTerminalView(in: view) ?? view)
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

    private func terminalConfig(for tab: PaneTab, paneId: String) -> TerminalConfig {
        if tab.type == .terminal, let command = tab.startupCommand {
            return .forCommand(command, cwd: tab.cwd)
        }
        guard tab.type == .agent,
              let agent = tab.agent,
              let profile = AgentCatalog.profile(for: agent.profileId)
        else { return TerminalConfig(workingDirectory: tab.cwd) }
        return .forAgent(
            profile,
            cwd: tab.cwd,
            paneId: paneId,
            tabId: tab.id,
            conversation: agent.conversation,
            launch: agent.launch
        )
    }

    /// Starts the agent of a tab in a window nobody is looking at, such as an
    /// automation's run: no pane container would start it until the window is
    /// shown. The terminal gets this view's size (or a typical one before it
    /// has a size), so the CLI lays out for a real screen until it is shown
    /// and resized. False when the surface could not start, which happens
    /// while every display sleeps; calling again later retries.
    @discardableResult
    func startBackgroundTerminal(for target: TerminalTarget) -> Bool {
        guard let tab = agentManager.panes[target.paneId]?.tabs.first(where: { $0.id == target.tabId }),
              tab.type == .agent
        else { return false }
        let view: NSView
        if let existing = tabContentViews[target] {
            if terminalViewHasLiveSurface(existing) { return true }
            view = existing
        } else {
            view = contentViewForTab(tab, paneId: target.paneId, startsSurface: false)
            let size = bounds.width > 0 && bounds.height > 0 ? bounds.size : NSSize(width: 1_000, height: 700)
            view.setFrameSize(size)
        }
        guard restartTerminalView(view, terminalConfig(for: tab, paneId: target.paneId)) else { return false }
        scheduleCodexReadinessIfNeeded(for: target)
        return true
    }

    /// The text a live terminal shows, or nil when it has no surface.
    func visibleTerminalText(for target: TerminalTarget) -> String? {
        guard let contentView = tabContentViews[target],
              terminalViewHasLiveSurface(contentView)
        else { return nil }
        return terminalVisibleText(contentView)
    }

    private func contentViewForTab(_ tab: PaneTab, paneId: String, startsSurface: Bool? = nil) -> NSView {
        let target = TerminalTarget(paneId: paneId, tabId: tab.id)
        if let existing = tabContentViews[target] {
            return existing
        }

        let view: NSView
        let startsSurface = startsSurface ?? (tab.type != .agent || tab.agent?.status != .stopped)
        switch tab.type {
        case .browser:
            if tab.isDiff,
               let value = tab.url,
               let fileURL = URL(string: value),
               fileURL.isFileURL
            {
                let diffView = DiffPaneView(
                    target: target,
                    fileURL: fileURL,
                    staged: tab.contentKind == PaneContentKind.stagedDiff,
                    themeManager: themeManager
                )
                diffView.onFocusRequested = { [weak self] in
                    self?.agentManager.focusTab(paneId: paneId, tabId: tab.id)
                }
                diffView.onOpenFileRequested = { [weak self] fileURL in
                    self?.agentManager.openEditor(fileURL: fileURL, preview: false, in: paneId)
                }
                view = diffView
                break
            }
            if tab.isEditor,
               let value = tab.url,
               let fileURL = URL(string: value),
               fileURL.isFileURL
            {
                let editorView = EditorPaneView(
                    target: target,
                    document: EditorDocumentStore.shared.document(for: fileURL),
                    themeManager: themeManager
                )
                editorView.onFocusRequested = { [weak self] in
                    self?.agentManager.focusTab(paneId: paneId, tabId: tab.id)
                }
                editorView.onTitleChanged = { [weak self] title in
                    self?.agentManager.renameTab(paneId, tabId: tab.id, to: title)
                }
                editorView.onEdited = { [weak self] in
                    self?.agentManager.keepEditorTab(paneId: paneId, tabId: tab.id)
                }
                editorView.onMarkdownPreviewRequested = { [weak self] fileURL in
                    _ = self?.agentManager.previewMarkdown(fileURL: fileURL, in: paneId)
                }
                // A file already modified in another tab shows its ● here too;
                // after this rebuild, not during it.
                DispatchQueue.main.async { [weak editorView] in
                    editorView?.publishTitle()
                }
                view = editorView
                break
            }
            if tab.isMarkdown,
               let value = tab.url,
               let fileURL = URL(string: value),
               fileURL.isFileURL
            {
                let markdownView = MarkdownPaneView(
                    target: target,
                    fileURL: fileURL,
                    themeManager: themeManager
                )
                markdownView.onFocusRequested = { [weak self] in
                    self?.agentManager.focusTab(paneId: paneId, tabId: tab.id)
                }
                markdownView.onTitleChanged = { [weak self] title in
                    self?.agentManager.renameTab(paneId, tabId: tab.id, to: title)
                }
                markdownView.onDocumentChanged = { [weak self] fileURL in
                    self?.agentManager.updateFileDocument(
                        paneId: paneId,
                        tabId: tab.id,
                        to: fileURL
                    )
                }
                markdownView.onExternalURLRequested = { [weak self] url in
                    DispatchQueue.main.async {
                        _ = self?.agentManager.spawnBrowser(url: url.absoluteString)
                    }
                }
                view = markdownView
                break
            }
            let browserView = BrowserPaneView(
                target: BrowserTarget(paneId: paneId, tabId: tab.id),
                initialURL: tab.url,
                themeManager: themeManager
            )
            browserView.onFocusRequested = { [weak self] in
                self?.agentManager.focusTab(paneId: paneId, tabId: tab.id)
            }
            browserView.onTitleChanged = { [weak self] title in
                self?.agentManager.renameTab(paneId, tabId: tab.id, to: title)
            }
            browserView.onURLChanged = { [weak self] url in
                self?.agentManager.updateBrowserURL(
                    paneId: paneId,
                    tabId: tab.id,
                    to: url
                )
            }
            view = browserView

        case .terminal, .agent:
            let terminalConfig = terminalConfig(for: tab, paneId: paneId)

            let terminalView = terminalViewFactory(
                target,
                terminalConfig,
                startsSurface
            )
            if let terminalView = terminalView as? TerminalSurfaceView {
                terminalView.chromeColors = themeManager.currentTheme.colors
                terminalView.onFocusRequested = { [weak self] in
                    self?.agentManager.focusTab(paneId: paneId, tabId: tab.id)
                }
                terminalView.onTitleChanged = { [weak self] title in
                    self?.agentManager.renameTab(paneId, tabId: tab.id, to: title)
                }
                terminalView.onWorkingDirectoryChanged = { [weak self] workingDirectory in
                    self?.agentManager.updateWorkingDirectory(
                        paneId: paneId,
                        tabId: tab.id,
                        to: workingDirectory
                    )
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
                terminalView.onShellCommandFinished = { [weak self] exitCode in
                    self?.clearRunningCommand(at: target)
                    self?.agentManager.agentCommandDidFinish(target: target, exitCode: exitCode)
                }
                terminalView.onAgentProcessExited = { [weak self] exitCode in
                    self?.agentManager.agentProcessDidExit(target: target, exitCode: exitCode)
                }
                terminalView.onCopyModeStateChanged = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .copy, .copySelection:
                        self.copyModeTarget = target
                    case .normal:
                        guard self.copyModeTarget == target else { return }
                        self.copyModeTarget = nil
                    case .prefix:
                        break
                    }
                    self.onCopyModeStateChanged?(state)
                }
            }
            view = terminalView
        }

        tabContentViews[target] = view
        if startsSurface, terminalViewHasLiveSurface(view) {
            scheduleCodexReadinessIfNeeded(for: target)
        }
        return view
    }

    private func scheduleCodexReadinessIfNeeded(for target: TerminalTarget) {
        guard let generation = agentManager.beginAgentReadinessGeneration(for: target) else {
            return
        }

        scheduleCodexReadiness { [weak agentManager] in
            agentManager?.markAgentReadyIfStarting(generation: generation)
        }
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

    private func findBrowserView(in view: NSView) -> BrowserPaneView? {
        if let browserView = view as? BrowserPaneView {
            return browserView
        }
        for subview in view.subviews {
            if let found = findBrowserView(in: subview) {
                return found
            }
        }
        return nil
    }

    private func findMarkdownView(in view: NSView) -> MarkdownPaneView? {
        if let markdownView = view as? MarkdownPaneView {
            return markdownView
        }
        for subview in view.subviews {
            if let found = findMarkdownView(in: subview) {
                return found
            }
        }
        return nil
    }

    private func findEditorView(in view: NSView) -> EditorPaneView? {
        if let editorView = view as? EditorPaneView {
            return editorView
        }
        for subview in view.subviews {
            if let found = findEditorView(in: subview) {
                return found
            }
        }
        return nil
    }

    private func findDiffView(in view: NSView) -> DiffPaneView? {
        if let diffView = view as? DiffPaneView {
            return diffView
        }
        for subview in view.subviews {
            if let found = findDiffView(in: subview) {
                return found
            }
        }
        return nil
    }

    private func cancelCopyModeOutsideActiveTerminal() {
        guard let copyModeTarget else { return }
        let activeTarget = agentManager.panes[agentManager.activePaneId]?.activeTab.map {
            TerminalTarget(paneId: agentManager.activePaneId, tabId: $0.id)
        }
        guard copyModeTarget != activeTarget else { return }
        if let contentView = tabContentViews[copyModeTarget],
           let terminalView = findTerminalView(in: contentView) {
            terminalView.cancelCopyMode()
            return
        }
        self.copyModeTarget = nil
        onCopyModeStateChanged?(.normal)
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
        let colors = themeManager.currentTheme.colors
        for view in tabContentViews.values {
            findBrowserView(in: view)?.applyTheme()
            findMarkdownView(in: view)?.applyTheme()
            findEditorView(in: view)?.applyTheme()
            findDiffView(in: view)?.applyTheme()
            findTerminalView(in: view)?.chromeColors = colors
        }
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
        label.alignment = .center
        label.setChromeText(text, font: ChromeFont.empty, color: theme.colors.textMuted)
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
        label.alignment = .center
        label.setChromeText("Empty", font: ChromeFont.empty, color: theme.colors.textMuted)
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
///
/// Folio (direction §6): the focused pane has no frame, only its raised
/// header and focus rule; every other pane's body sits under the unfocused
/// veil; an attention pane gets a 2 pt `attention` frame and is never veiled.
final class PaneContainerView: NSView {
    let paneId: String
    let agentManager: AgentManager
    let themeManager: ThemeManager

    private var headerView: PaneHeaderView
    private let veilView = PaneVeilView()
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

        setupSubviews()
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Whether the body is under the unfocused veil (for tests and the harness).
    var isVeiled: Bool { !veilView.isHidden }

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
        // The veil stays above whatever body the pane shows.
        addSubview(newContent, positioned: .below, relativeTo: veilView)
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
        let colors = themeManager.currentTheme.colors
        let isActive = paneId == agentManager.activePaneId
        let needsAttention = agentManager.panes[paneId]?.tabs.contains {
            $0.agent?.needsAttention == true
        } ?? false
        // Containers are cached for the lifetime of a pane, so colors set
        // once would otherwise keep the old theme forever.
        layer?.backgroundColor = colors.bgBase.cgColor
        // A layer border composites above every sublayer, so the frame
        // stays on top of the header and a Metal terminal body alike.
        layer?.borderWidth = needsAttention ? Chrome.attentionFrame : 0
        layer?.borderColor = colors.attention.cgColor
        veilView.isHidden = isActive || needsAttention
        veilView.apply(colors: colors)
        headerView.update()
    }

    private func setupSubviews() {
        headerView.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerView)
        addSubview(contentView)
        addSubview(veilView)

        let headerHeightConstraint = headerView.heightAnchor.constraint(equalToConstant: PaneHeaderView.height)
        headerHeightConstraint.priority = .defaultHigh

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: topAnchor),
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerHeightConstraint,

            contentView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),

            veilView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            veilView.leadingAnchor.constraint(equalTo: leadingAnchor),
            veilView.trailingAnchor.constraint(equalTo: trailingAnchor),
            veilView.bottomAnchor.constraint(equalTo: bottomAnchor),
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

// MARK: - PaneVeilView

/// The unfocused-pane veil over a pane body. It hosts its own layer, so
/// AppKit never resets the veil's compositing filter, and it is invisible to
/// hit-testing, so clicks, drags and cursor rects reach the body beneath.
private final class PaneVeilView: NSView {
    private let veilLayer = CALayer()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer = veilLayer
        wantsLayer = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The veil layer is standalone, so its property changes would animate
    /// implicitly (a 0.25 s cross-fade on a theme switch); they snap instead.
    func apply(colors: ThemeColors) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ChromeSurface.applyVeil(to: veilLayer, colors: colors)
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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

    /// Panes are separated by one borderStrong hairline (tiled panes keep
    /// square corners and no other edge).
    override var dividerColor: NSColor {
        themeManager.currentTheme.colors.borderStrong
    }

    override var dividerThickness: CGFloat { Chrome.hairline }

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
