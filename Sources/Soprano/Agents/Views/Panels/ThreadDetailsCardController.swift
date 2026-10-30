import AppKit
import SopranoAgentsCore

/// The floating Thread details card (`ThreadDetailsPanel.tsx`): 280 pt, top-right of the chat
/// column. Workspace section (workspace row with Reveal in Finder, "Open in <Editor>" split row,
/// project scripts split row), then Version Control (branch + PR badge, git actions split row with
/// T3 Code's quick action, Changes `+N −N`). Git status refreshes when the card opens, when a turn
/// finishes and every 30 s while it is visible.
@MainActor
final class ThreadDetailsCardController: NSViewController {
    let engine: AgentEngine
    let state: WorkspaceState

    static let refreshInterval: TimeInterval = 30
    static let successDuration: TimeInterval = 10

    private(set) var gitStatus: GitStatusSummary?
    private var statusGeneration = 0
    private var refreshTimer: Timer?
    private var wasRunning: [String: Bool] = [:]
    private var installedEditors: [InstalledEditor] = []

    /// A running git action (progress row) and the last result (success row).
    private var progress: (label: String, startedAt: Date)?
    private var progressTimer: Timer?
    private var success: (title: String, detail: String?, url: String?, threadID: String)?
    private var successDismiss: DispatchWorkItem?
    var isGitActionRunning: Bool { progress != nil }

    // Views
    private let card = ThreadDetailsCardView()
    private let workspaceSection = NSStackView()
    private let versionSection = NSStackView()
    private let rule = NSView()
    private let workspaceRow = DetailsRowButton(part: .row, symbol: "folder")
    private let revealButton = DetailsIconAction(symbol: "folder", toolTip: "Reveal in Finder")
    private let openInRow = DetailsSplitRow(symbol: nil, title: "Open in Finder", menuLabel: "Choose editor")
    private let scriptsRow = DetailsSplitRow(symbol: "play", title: "Run", menuLabel: "Project actions")
    private let branchRow = DetailsRowButton(part: .row, symbol: Icon.gitBranch)
    private let prBadge = PullRequestBadge()
    private let branchChevron = NSImageView()
    private let gitRow = DetailsSplitRow(symbol: "checkmark.circle", title: "Commit", menuLabel: "Git action options")
    private let progressRow = DetailsRowButton(part: .row, symbol: "arrow.triangle.2.circlepath")
    private let progressElapsed = NSTextField.label(size: Typography.tinySize)
    private let successRow = GitSuccessRow()
    private let changesRow = DetailsRowButton(part: .row, symbol: diffGlyph, title: "Changes")
    private let changesStats = NSTextField.label(size: Typography.smallSize)
    private let emptyLabel = NSTextField.label("No details for this selection.", size: Typography.smallSize)

    init(engine: AgentEngine, state: WorkspaceState) {
        self.engine = engine
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        MainActor.assumeIsolated {
            refreshTimer?.invalidate()
            progressTimer?.invalidate()
        }
    }

    override func loadView() {
        view = card
        buildRows()
        state.addObserver(self) { [weak self] change in
            switch change {
            case .selection:
                self?.selectionChanged()
            case .panels:
                self?.visibilityChanged()
            case .filter, .composerRestore: break
            }
        }
        engine.addObserver(self) { [weak self] event in
            self?.engineChanged(event)
        }
        PaletteCenter.shared.addObserver(self) { [weak self] _ in self?.render() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationDidBecomeActive), name: NSApplication.didBecomeActiveNotification, object: nil
        )
        visibilityChanged()
    }

    private func buildRows() {
        for section in [workspaceSection, versionSection] {
            section.orientation = .vertical
            section.alignment = .leading
            section.spacing = 0
            section.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 10, right: 8)
        }
        rule.wantsLayer = true

        workspaceRow.addTrailing(revealButton)
        workspaceRow.onClick = { [weak self] in self?.revealWorkspace() }
        revealButton.onClick = { [weak self] in self?.revealWorkspace() }
        openInRow.primary.onClick = { [weak self] in self?.openInEditor() }
        openInRow.secondary.onClick = { [weak self] in self?.showEditorMenu() }
        scriptsRow.primary.onClick = { [weak self] in self?.runPrimaryScript() }
        scriptsRow.secondary.onClick = { [weak self] in self?.showScriptsMenu() }

        branchChevron.image = NSImage.symbol(Icon.chevronDown, size: 11, weight: .medium)
        branchChevron.imageScaling = .scaleNone
        branchRow.addTrailing(prBadge)
        branchRow.addTrailing(branchChevron)
        branchRow.onClick = { [weak self] in self?.showBranchMenu() }
        gitRow.primary.onClick = { [weak self] in self?.runQuickAction() }
        gitRow.secondary.onClick = { [weak self] in self?.showGitMenu() }
        progressRow.isEnabled = false
        progressRow.isHighlighted = true
        progressRow.addTrailing(progressElapsed)
        successRow.onViewPR = { [weak self] in self?.openSuccessURL() }
        changesRow.addTrailing(changesStats)
        changesRow.onClick = { [weak self] in self?.state.showDiff(.uncommitted) }

        for row in [workspaceRow, openInRow, scriptsRow] as [NSView] {
            workspaceSection.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: workspaceSection.widthAnchor, constant: -16).isActive = true
        }
        for row in [branchRow, gitRow, progressRow, successRow, changesRow] as [NSView] {
            versionSection.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: versionSection.widthAnchor, constant: -16).isActive = true
        }
        let stack = NSStackView(views: [workspaceSection, rule, versionSection, emptyLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            workspaceSection.widthAnchor.constraint(equalTo: stack.widthAnchor),
            versionSection.widthAnchor.constraint(equalTo: stack.widthAnchor),
            rule.widthAnchor.constraint(equalTo: stack.widthAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
        ])
        emptyLabel.alignment = .center
        emptyLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        emptyLabel.heightAnchor.constraint(equalToConstant: 44).isActive = true
    }

    // MARK: - Context

    private var thread: AgentThread? { engine.thread(state.selectedThreadID) }

    private var project: Project? {
        if let thread { return engine.project(thread.projectID) }
        return engine.project(state.draftProjectID)
    }

    /// The selection's working directory: the thread's worktree, project root or scratch
    /// directory; the draft's project root.
    var workingDirectory: String? {
        if let thread { return engine.workingDirectory(for: thread) }
        return project?.path
    }

    // MARK: - Updates

    private func visibilityChanged() {
        let visible = state.isThreadDetailsVisible
        if visible {
            if refreshTimer == nil {
                installedEditors = EditorCatalog.installedOnThisMac()
                refreshStatus()
                let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshStatus() }
                }
                RunLoop.main.add(timer, forMode: .common)
                refreshTimer = timer
            }
        } else {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
        render()
    }

    private func selectionChanged() {
        gitStatus = nil
        if success?.threadID != state.selectedThreadID {
            success = nil
        }
        render()
        if state.isThreadDetailsVisible { refreshStatus() }
    }

    private func engineChanged(_ event: EngineEvent) {
        switch event {
        case let .threadChanged(threadID):
            guard let thread = engine.thread(threadID) else { return }
            let running = thread.isRunning
            let was = wasRunning[threadID] ?? running
            wasRunning[threadID] = running
            // A finished turn may have changed files: re-read the status.
            if threadID == state.selectedThreadID, was, !running, state.isThreadDetailsVisible {
                refreshStatus()
            }
            if threadID == state.selectedThreadID { render() }
        case .projectsChanged, .threadListChanged:
            render()
        default:
            break
        }
    }

    @objc private func applicationDidBecomeActive() {
        if state.isThreadDetailsVisible { refreshStatus() }
    }

    /// Re-reads git status of the selection's working directory (a read-only query, so it goes
    /// straight to `engine.environment.git`, like `AgentEngine.gitStatus`).
    func refreshStatus() {
        guard let cwd = workingDirectory else {
            gitStatus = nil
            render()
            return
        }
        statusGeneration += 1
        let generation = statusGeneration
        Task { [weak self] in
            guard let self else { return }
            let status = await loadStatus(cwd: cwd)
            guard generation == statusGeneration else { return }
            gitStatus = status
            render()
        }
    }

    private func loadStatus(cwd: String) async -> GitStatusSummary {
        let git = engine.environment.git
        guard await git.isRepository(cwd) else { return .notARepository }
        return (try? await git.status(cwd: cwd)) ?? .notARepository
    }

    // MARK: - Rendering

    private func render() {
        guard isViewLoaded else { return }
        let palette = PaletteCenter.shared.palette
        rule.layer?.backgroundColor = palette.border.fading(0.65).cgColor
        emptyLabel.textColor = palette.mutedForeground
        let cwd = workingDirectory

        // Workspace
        let hasProject = project != nil
        workspaceRow.isHidden = !hasProject
        if let thread, thread.worktreePath != nil {
            workspaceRow.title = "Worktree"
            workspaceRow.iconView.image = NSImage.symbol("folder.badge.gearshape", size: 13)
        } else {
            workspaceRow.title = "Local checkout"
            workspaceRow.iconView.image = NSImage.symbol("folder", size: 13)
        }
        workspaceRow.toolTip = cwd

        let editor = EditorCatalog.preferred(in: installedEditors, chosen: EditorChoice.chosenID, setting: SettingsCenter.shared.settings.editorApp)
        openInRow.isHidden = cwd == nil || editor == nil
        if let editor {
            openInRow.primary.title = "Open in \(editor.label)"
            let icon = NSWorkspace.shared.icon(forFile: editor.appURL.path)
            icon.size = NSSize(width: 16, height: 16)
            openInRow.primary.iconView.image = icon
        }

        let scripts = project?.scripts ?? []
        scriptsRow.isHidden = scripts.isEmpty
        if let script = primaryScript {
            scriptsRow.primary.title = script.name
            scriptsRow.primary.iconView.image = NSImage.symbol(Self.symbol(for: script.icon), size: 13)
            scriptsRow.primary.isEnabled = thread != nil
            scriptsRow.primary.toolTip = script.command
        }
        workspaceSection.isHidden = workspaceRow.isHidden && openInRow.isHidden && scriptsRow.isHidden

        // Version control
        let status = gitStatus
        let isRepository = status?.isRepository == true
        let branch = status?.branch ?? thread?.branch
        branchRow.isHidden = !isRepository || branch == nil
        branchRow.title = branch ?? ""
        if let pr = status?.pullRequest {
            prBadge.isHidden = false
            prBadge.configure(number: pr.number, state: pr.state)
            prBadge.toolTip = "\(pr.title) (\(pr.state.rawValue))"
        } else {
            prBadge.isHidden = true
        }
        branchChevron.contentTintColor = palette.mutedForeground

        let quick = GitQuickAction.resolve(status, isBusy: isGitActionRunning)
        let showsGit = isRepository && project != nil
        progressRow.isHidden = !(showsGit && progress != nil)
        successRow.isHidden = !(showsGit && progress == nil && success != nil && success?.threadID == state.selectedThreadID)
        gitRow.isHidden = !showsGit || !progressRow.isHidden || !successRow.isHidden
        gitRow.primary.title = quick.label
        gitRow.primary.iconView.image = NSImage.symbol(Self.symbol(for: quick), size: 13)
        gitRow.primary.isEnabled = !quick.isDisabled || quick.hint != nil
        gitRow.primary.toolTip = quick.hint
        gitRow.primary.label.alphaValue = quick.isDisabled ? 0.6 : 1
        gitRow.secondary.isEnabled = !isGitActionRunning
        if let progress {
            progressRow.title = progress.label
            progressElapsed.stringValue = gitActionElapsedText(Date().timeIntervalSince(progress.startedAt))
            progressElapsed.textColor = palette.mutedForeground
        }
        if let success {
            successRow.configure(title: success.title, detail: success.detail, showsViewPR: success.url != nil)
        }

        changesRow.isHidden = !isRepository
        changesStats.attributedStringValue = DiffStatText.make(
            additions: status?.insertions ?? 0, deletions: status?.deletions ?? 0,
            palette: palette, size: Typography.smallSize, muteZero: true
        )
        let showsVersion = !branchRow.isHidden || !gitRow.isHidden || !progressRow.isHidden || !successRow.isHidden || !changesRow.isHidden
        versionSection.isHidden = !showsVersion
        rule.isHidden = workspaceSection.isHidden || !showsVersion
        emptyLabel.isHidden = !(workspaceSection.isHidden && !showsVersion)
    }

    static func symbol(for icon: ProjectScript.Icon) -> String {
        switch icon {
        case .play: "play"
        case .test: "testtube.2"
        case .lint: "checklist"
        case .configure: "wrench.and.screwdriver"
        case .build: "hammer"
        case .debug: "ladybug"
        }
    }

    static func symbol(for quick: GitQuickAction) -> String {
        switch quick.kind {
        case .publish: "icloud.and.arrow.up"
        case .pull: "icloud.and.arrow.down"
        case let .run(action):
            switch action {
            case .commit: "checkmark.circle"
            case .push, .commitAndPush: "icloud.and.arrow.up"
            case .createPullRequest, .commitPushAndPullRequest: "arrow.triangle.pull"
            }
        case .hint:
            switch quick.label {
            case "Commit": "checkmark.circle"
            case "Push": "icloud.and.arrow.up"
            default: "info.circle"
            }
        }
    }

    // MARK: - Workspace actions

    private func revealWorkspace() {
        guard let cwd = workingDirectory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd, isDirectory: true)])
    }

    /// Opens the working directory in the preferred editor (`editor.openFavorite`).
    func openInEditor() {
        if installedEditors.isEmpty { installedEditors = EditorCatalog.installedOnThisMac() }
        guard let cwd = workingDirectory,
              let editor = EditorCatalog.preferred(in: installedEditors, chosen: EditorChoice.chosenID,
                                                   setting: SettingsCenter.shared.settings.editorApp) else { return }
        EditorCatalog.open(cwd, in: editor)
    }

    private func showEditorMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let header = NSMenuItem(title: "Choose editor", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let current = EditorCatalog.preferred(in: installedEditors, chosen: EditorChoice.chosenID, setting: SettingsCenter.shared.settings.editorApp)
        for editor in installedEditors {
            let item = NSMenuItem(title: editor.label, action: #selector(chooseEditor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = editor.id
            item.state = editor.id == current?.id ? .on : .off
            let icon = NSWorkspace.shared.icon(forFile: editor.appURL.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        menu.popUp(below: openInRow, marking: openInRow.secondary)
    }

    @objc private func chooseEditor(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        EditorChoice.chosenID = id
        render()
        openInEditor()
    }

    // MARK: - Scripts

    /// The script the row runs: the last one run in this project, else the first.
    private var primaryScript: ProjectScript? {
        guard let project else { return nil }
        if let last = ScriptMemory.lastRun[project.id], let script = project.scripts.first(where: { $0.id == last }) {
            return script
        }
        return project.scripts.first
    }

    private func runPrimaryScript() {
        guard let script = primaryScript else { return }
        run(script)
    }

    private func showScriptsMenu() {
        guard let project else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for script in project.scripts {
            let suffix = script.runOnWorktreeCreate ? " (setup)" : ""
            let item = NSMenuItem(title: script.name + suffix, action: #selector(runScriptItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = script.id
            item.image = NSImage.symbol(Self.symbol(for: script.icon), size: 13)
            item.toolTip = script.command
            item.isEnabled = thread != nil
            menu.addItem(item)
        }
        menu.popUp(below: scriptsRow, marking: scriptsRow.secondary)
    }

    @objc private func runScriptItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let script = project?.scripts.first(where: { $0.id == id }) else { return }
        run(script)
    }

    private func run(_ script: ProjectScript) {
        guard let thread, let project else { return }
        ScriptMemory.lastRun[project.id] = script.id
        terminalDrawer?.run(command: script.command, in: thread.id)
        render()
    }

    private var terminalDrawer: TerminalDrawerViewController? {
        (parent as? ChatViewController)?.terminal
    }

    // MARK: - Branch

    private func showBranchMenu() {
        guard let branch = gitStatus?.branch ?? thread?.branch else { return }
        let menu = NSMenu()
        let copy = NSMenuItem(title: "Copy branch name", action: #selector(copyBranch(_:)), keyEquivalent: "")
        copy.target = self
        copy.representedObject = branch
        copy.image = NSImage.symbol(Icon.copy, size: 13)
        menu.addItem(copy)
        if let pr = gitStatus?.pullRequest {
            let open = NSMenuItem(title: "View PR #\(pr.number)", action: #selector(openPullRequest(_:)), keyEquivalent: "")
            open.target = self
            open.representedObject = pr.url
            open.image = NSImage.symbol("arrow.up.right.square", size: 13)
            menu.addItem(open)
        }
        menu.popUp(below: branchRow, marking: branchRow)
    }

    @objc private func copyBranch(_ sender: NSMenuItem) {
        guard let branch = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(branch, forType: .string)
    }

    @objc private func openPullRequest(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Git actions

    private func showGitMenu() {
        // Re-read the status so the menu reflects the tree right now (T3 Code refreshes on open).
        refreshStatus()
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in GitQuickAction.menuItems(gitStatus, isBusy: isGitActionRunning) {
            let item = NSMenuItem(title: entry.title, action: #selector(gitMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.isEnabled = entry.isEnabled
            item.representedObject = GitMenuBox(entry.action)
            let symbol: String = switch entry.action {
            case .commitDialog: "checkmark.circle"
            case .push: "icloud.and.arrow.up"
            case .createPullRequest: "arrow.triangle.pull"
            }
            item.image = NSImage.symbol(symbol, size: 13)
            menu.addItem(item)
        }
        if let status = gitStatus, status.isRepository {
            if status.branch == nil {
                menu.addItem(.separator())
                menu.addItem(Self.warningItem("Detached HEAD: create and check out a branch to enable push and pull request actions."))
            } else if status.behind > 0 {
                menu.addItem(.separator())
                menu.addItem(Self.warningItem("Behind upstream. Pull/rebase first."))
            }
        }
        guard !menu.items.isEmpty else { return }
        menu.popUp(below: gitRow, marking: gitRow.secondary)
    }

    private static func warningItem(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func gitMenuItem(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? GitMenuBox else { return }
        switch box.action {
        case .commitDialog: openCommitDialog()
        case .push: run(.push)
        case .createPullRequest: run(.createPullRequest)
        }
    }

    private func runQuickAction() {
        let quick = GitQuickAction.resolve(gitStatus, isBusy: isGitActionRunning)
        switch quick.kind {
        case let .run(action):
            run(action)
        case .pull:
            guard let thread else { return }
            terminalDrawer?.run(command: "git pull", in: thread.id)
        case .publish:
            Task { @MainActor in
                await Dialogs.alert(
                    title: "Publish repository",
                    message: "This repository has no git remote yet. Create one with \"gh repo create --source . --push\", or add one with \"git remote add origin <url>\" and push.",
                    in: view.window
                )
            }
        case let .hint(text):
            gitRow.primary.toolTip = text
            Task { @MainActor in
                await Dialogs.alert(title: quick.label, message: text, in: view.window)
            }
        }
    }

    /// "Commit" from the git menu or `git.commit`: the "Commit changes" dialog.
    func openCommitDialog() {
        guard let window = view.window, thread != nil else { return }
        let show: (GitStatusSummary) -> Void = { [weak self] status in
            guard let self else { return }
            CommitDialog.present(status: status, in: window) { [weak self] result in
                guard let self, let result else { return }
                run(.commit, commitMessage: result.message, filePaths: result.filePaths, featureBranch: result.featureBranch)
            }
        }
        if let status = gitStatus {
            show(status)
        } else if let cwd = workingDirectory {
            Task { [weak self] in
                guard let self else { return }
                let status = await loadStatus(cwd: cwd)
                gitStatus = status
                render()
                show(status)
            }
        }
    }

    /// Runs a stacked action for the selected thread, asking first on the default branch. The
    /// status is read fresh: from the palette the card may be hidden with no (or stale) status.
    func run(_ action: GitStackedAction, commitMessage: String? = nil, filePaths: [String]? = nil, featureBranch: Bool = false) {
        guard let thread, !isGitActionRunning else { return }
        let threadID = thread.id
        Task { @MainActor [weak self] in
            guard let self else { return }
            var featureBranch = featureBranch
            var status = gitStatus
            if let cwd = workingDirectory {
                status = await loadStatus(cwd: cwd)
                gitStatus = status
            }
            if let status, let branch = status.branch, !featureBranch,
               GitQuickAction.requiresDefaultBranchConfirmation(action, isDefaultBranch: status.isDefaultBranch) {
                let includesCommit = GitQuickAction.includesCommit(action) && status.hasChanges
                let copy = GitQuickAction.defaultBranchCopy(action, branch: branch, includesCommit: includesCommit)
                var buttons = [DialogButton("Cancel")]
                if includesCommit { buttons.append(DialogButton("Check out feature branch & continue")) }
                buttons.append(DialogButton(copy.continueTitle, style: .primary))
                guard let choice = await Dialogs.choose(title: copy.title, message: copy.message, buttons: buttons, in: view.window),
                      choice > 0 else { return }
                featureBranch = includesCommit && choice == 1
            }
            await perform(action, threadID: threadID, commitMessage: commitMessage, filePaths: filePaths, featureBranch: featureBranch)
        }
    }

    private func perform(_ action: GitStackedAction, threadID: String, commitMessage: String?, filePaths: [String]?, featureBranch: Bool) async {
        success = nil
        progress = (label: Self.initialProgressLabel(action, hasMessage: commitMessage != nil), startedAt: Date())
        startProgressTimer()
        render()
        do {
            let result = try await engine.runGitAction(
                threadID, action: action, commitMessage: commitMessage, filePaths: filePaths, featureBranch: featureBranch
            ) { [weak self] update in
                Task { @MainActor in
                    guard let self, self.progress != nil else { return }
                    self.progress?.label = update.label
                    self.render()
                }
            }
            finishProgress()
            success = (title: result.title, detail: result.detail, url: result.pullRequestURL, threadID: threadID)
            scheduleSuccessDismiss()
            render()
            refreshStatus()
        } catch {
            finishProgress()
            render()
            refreshStatus()
            await Dialogs.alert(title: "Git action failed", message: error.localizedDescription, in: view.window)
        }
    }

    static func initialProgressLabel(_ action: GitStackedAction, hasMessage: Bool) -> String {
        switch action {
        case .commit, .commitAndPush, .commitPushAndPullRequest:
            hasMessage ? "Committing..." : "Generating commit message..."
        case .push: "Pushing..."
        case .createPullRequest: "Preparing PR..."
        }
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func finishProgress() {
        progress = nil
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func scheduleSuccessDismiss() {
        successDismiss?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.success = nil
            self?.render()
        }
        successDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.successDuration, execute: work)
    }

    private func openSuccessURL() {
        guard let raw = success?.url, let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }
}

private final class GitMenuBox: NSObject {
    let action: GitQuickAction.MenuItem.Action
    init(_ action: GitQuickAction.MenuItem.Action) { self.action = action }
}

/// Last project script run per project id (the scripts row's primary), for this session.
@MainActor
enum ScriptMemory {
    static var lastRun: [String: String] = [:]
}

/// The card surface: `dropdown-glass rounded-2xl` — popover at 80–92 %, a 1 pt contrast border,
/// the menu shadow.
final class ThreadDetailsCardView: PaletteView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = Radius.xxl
        layer?.borderWidth = 1
        layer?.masksToBounds = false
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 20
        layer?.shadowOffset = CGSize(width: 0, height: -10)
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.popover.withAlphaComponent(0.96).cgColor
        layer?.borderColor = palette.foreground.withAlphaComponent(0.1).cgColor
        layer?.shadowColor = NSColor.black.withAlphaComponent(palette.isDark ? 0.6 : 0.16).cgColor
    }

    override func mouseDown(with event: NSEvent) {}
}

/// The git row after an action: success title and description, "View PR" when a PR exists.
final class GitSuccessRow: PaletteView {
    var onViewPR: (() -> Void)?

    private let icon = NSImageView()
    private let title = NSTextField.label(size: Typography.rowSize, weight: .medium)
    private let detail = NSTextField.label(size: Typography.smallSize)
    private let viewPR = TextButton("View PR", variant: .ghost, size: .xs)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = Radius.lg
        icon.image = NSImage.symbol(Icon.circleCheck, size: 13)
        icon.imageScaling = .scaleNone
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [icon, text, viewPR])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
        ])
        viewPR.onClick = { [weak self] in self?.onViewPR?() }
        applyPalette(palette)
    }

    func configure(title: String, detail: String?, showsViewPR: Bool) {
        self.title.stringValue = title
        self.detail.stringValue = detail ?? ""
        self.detail.isHidden = detail?.isEmpty ?? true
        viewPR.isHidden = !showsViewPR
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = DetailsSurface.hover(palette).cgColor
        icon.contentTintColor = palette.successForeground
        title.textColor = DetailsSurface.text(palette)
        detail.textColor = palette.mutedForeground
    }
}
