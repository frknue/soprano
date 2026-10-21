import AppKit

/// The right sidebar's Source Control tab, after Orca's without staging or
/// committing: the focused pane's repository as changed files grouped by
/// area, each opening a diff tab.
///
/// The repository follows the active pane like the explorer's root; tabs
/// without a working directory keep the current one. Nothing is read,
/// watched, or run while the view is inactive.
final class SourceControlView: NSView {
    static let toolbarHeight: CGFloat = 32

    private static let noRoomMessage = "No room for another tab or pane in this window."

    /// What the active pane asks the view to show.
    private enum Target: Equatable {
        case repository(String)
        case notRepository
    }

    private let agentManager: AgentManager
    private let themeManager: ThemeManager
    private let observerId = "SourceControlView-\(UUID().uuidString)"

    /// Hands the keyboard to the active pane: Escape in the list, and after
    /// opening a diff.
    var onReturnFocus: (() -> Void)?

    // MARK: Views

    private let titleLabel = NSTextField(labelWithString: "")
    private let branchLabel = NSTextField(labelWithString: "")
    private var refreshButton: ChromeIconButton!
    private let toolbarRule = ChromeRuleView(axis: .horizontal)
    private let scrollView = NSScrollView()
    private let outlineView = SourceControlOutlineView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let statusSpinner = NSProgressIndicator()
    private let toastLabel = NSTextField(wrappingLabelWithString: "")
    private var toastTask: Task<Void, Never>?

    // MARK: State

    private(set) var isActive = false
    private(set) var rootURL: URL?
    private(set) var changeList = GitChangeList.empty
    private var target: Target?
    private var realRootPath: String?
    /// A linked worktree's or submodule's git directory, outside the root.
    private var externalGitDirectory: String?
    /// Only used to skip watcher events in ignored folders such as build output.
    private var ignoredPaths = GitStatusSnapshot.empty
    /// Nil until the first read for the current root finishes; false when git failed.
    private var lastReadSucceeded: Bool?
    /// Bumped whenever the root changes so late results for the old one are dropped.
    private var rootGeneration = 0
    private var refreshInFlight = false
    private var refreshPending = false
    private var refreshTask: Task<Void, Never>?
    private var lastRefresh = Date.distantPast
    private var watcher: FileSystemWatcher?
    private var collapsedAreas: Set<GitChangeArea> = []
    private var sections: [SourceControlSection] = []

    private var colors: ThemeColors { themeManager.currentTheme.colors }

    init(agentManager: AgentManager, themeManager: ThemeManager) {
        self.agentManager = agentManager
        self.themeManager = themeManager
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setupViews()

        agentManager.addObserver(id: observerId) { [weak self] change in
            switch change {
            case .model, .tabWorkingDirectory:
                self?.syncRootWithActivePane()
            case .tabTitle, .browserURL, .document:
                break
            }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        syncRootWithActivePane()
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        agentManager.removeObserver(id: observerId)
    }

    // MARK: - Activation

    /// Starts or stops git reads and watching (sidebar open + this tab
    /// selected + in a window).
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            if let target, target != shownTarget {
                apply(target)
            } else if rootURL != nil {
                startWatching()
                scheduleRefresh(immediately: true)
            }
        } else {
            watcher = nil
            refreshTask?.cancel()
            refreshTask = nil
        }
    }

    /// Whether the keyboard is in the list.
    var containsKeyboardFocus: Bool {
        guard let responder = window?.firstResponder else { return false }
        if let view = responder as? NSView, view.isDescendant(of: self) {
            return true
        }
        if let editor = responder as? NSText, let delegate = editor.delegate as? NSView {
            return delegate.isDescendant(of: self)
        }
        return false
    }

    /// Moves the keyboard into the list, onto the first change if nothing is
    /// selected. Only keyboard paths call this: a click selects its own row.
    func focusList() {
        window?.makeFirstResponder(outlineView)
        guard outlineView.selectedRowIndexes.isEmpty, outlineView.numberOfRows > 0 else { return }
        let firstChange = (0..<outlineView.numberOfRows).first { outlineView.item(atRow: $0) is SourceControlItem }
        outlineView.selectRowIndexes(IndexSet(integer: firstChange ?? 0), byExtendingSelection: false)
    }

    @objc private func applicationDidBecomeActive() {
        // Catches changes nothing under the watched paths reflects.
        if isActive {
            scheduleRefresh()
        }
    }

    // MARK: - Root

    /// The target the view last switched to; `target` may move ahead of it while inactive.
    private var shownTarget: Target?

    private func syncRootWithActivePane() {
        guard let tab = agentManager.panes[agentManager.activePaneId]?.activeTab,
              let cwd = tab.effectiveWorkingDirectory
        else { return }
        let expanded = (cwd as NSString).expandingTildeInPath
        let newTarget: Target = GitBranchMonitor.repositoryRoot(startingAt: expanded).map { .repository($0) }
            ?? .notRepository
        target = newTarget
        guard isActive, newTarget != shownTarget else { return }
        apply(newTarget)
    }

    private func apply(_ target: Target) {
        shownTarget = target
        switch target {
        case let .repository(path):
            setRoot(path)
        case .notRepository:
            setRoot(nil)
        }
    }

    private func setRoot(_ path: String?) {
        rootGeneration += 1
        rootURL = path.map { URL(fileURLWithPath: $0, isDirectory: true) }
        // FSEvents reports fully resolved paths (`/private/var/…` for `/var/…`).
        realRootPath = path.flatMap { path in
            realpath(path, nil).map { resolved in
                defer { free(resolved) }
                return String(cString: resolved)
            }
        }
        externalGitDirectory = path.flatMap { FileExplorerView.externalGitDirectory(forRoot: $0) }
        ignoredPaths = .empty
        lastReadSucceeded = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshPending = false
        watcher = nil
        show(.empty, keepingState: false)
        updateToolbar()
        updateStatus()
        guard path != nil else { return }
        startWatching()
        scheduleRefresh(immediately: true)
    }

    // MARK: - Watching

    private func startWatching() {
        guard let rootURL else { return }
        let paths = [rootURL.path] + [externalGitDirectory].compactMap { $0 }
        watcher = FileSystemWatcher(paths: paths) { [weak self] paths, needsRescan in
            self?.handleFileSystemEvents(paths, needsRescan: needsRescan)
        }
    }

    private func handleFileSystemEvents(_ paths: [String], needsRescan: Bool) {
        guard isActive, rootURL != nil else { return }
        if needsRescan {
            scheduleRefresh()
            return
        }
        for path in paths {
            if let gitDirectory = externalGitDirectory,
               path == gitDirectory || path.hasPrefix(gitDirectory + "/") {
                scheduleRefresh()
                return
            }
            guard let relative = relativePath(ofPath: path) else { continue }
            // Build output in ignored folders cannot change `git status`.
            if relative == ".git" || relative.hasPrefix(".git/") || !ignoredPaths.isIgnored(relativePath: relative) {
                scheduleRefresh()
                return
            }
        }
    }

    /// `path` relative to the root, matching the root as configured or its
    /// symlink-resolved form (FSEvents reports the latter).
    private func relativePath(ofPath path: String) -> String? {
        for base in [rootURL?.path, realRootPath].compactMap({ $0 }) {
            if path == base {
                return ""
            }
            let prefix = base.hasSuffix("/") ? base : base + "/"
            if path.hasPrefix(prefix) {
                return String(path.dropFirst(prefix.count))
            }
        }
        return nil
    }

    // MARK: - Git

    private func scheduleRefresh(immediately: Bool = false) {
        guard isActive, rootURL != nil, GitStatusReader.executableURL != nil else { return }
        if refreshInFlight {
            refreshPending = true
            return
        }
        // Bursts (a build, a checkout) coalesce into one read at most every
        // two seconds instead of re-running `git status` per event batch.
        guard refreshTask == nil || immediately else { return }
        refreshTask?.cancel()
        let sinceLast = Date().timeIntervalSince(lastRefresh)
        let delay = immediately ? 0 : max(0.4, 2 - sinceLast)
        refreshTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            self?.refreshTask = nil
            self?.runRefresh()
        }
    }

    private func runRefresh() {
        guard isActive, let root = rootURL?.path else { return }
        refreshInFlight = true
        lastRefresh = Date()
        let generation = rootGeneration
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let list = GitStatusReader.changes(root: root)
            let ignored = GitStatusReader.ignoredPaths(root: root)
            Task { @MainActor [weak self] in
                self?.finishRefresh(list, ignored: ignored, generation: generation)
            }
        }
    }

    private func finishRefresh(_ list: GitChangeList?, ignored: Set<String>, generation: Int) {
        refreshInFlight = false
        guard generation == rootGeneration else {
            scheduleRefresh(immediately: true)
            return
        }
        ignoredPaths = GitStatusSnapshot(entries: [], ignoredPaths: ignored)
        lastReadSucceeded = list != nil
        show(list ?? .empty, keepingState: true)
        updateToolbar()
        updateStatus()
        if refreshPending {
            refreshPending = false
            scheduleRefresh()
        }
    }

    // MARK: - Display

    /// Replaces the list, keeping the selected change and scroll position.
    private func show(_ list: GitChangeList, keepingState: Bool) {
        let selected = keepingState ? selectedEntry() : nil
        let origin = scrollView.contentView.bounds.origin
        let changed = list != changeList || !keepingState
        changeList = list
        guard changed else { return }
        sections = GitChangeArea.allCases.compactMap { area in
            let changes = list.changes(in: area)
            guard !changes.isEmpty else { return nil }
            return SourceControlSection(area: area, items: changes.map(SourceControlItem.init))
        }
        outlineView.reloadData()
        for section in sections where !collapsedAreas.contains(section.area) {
            outlineView.expandItem(section)
        }
        if let selected {
            select(selected)
        }
        if keepingState {
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        } else {
            outlineView.scrollRowToVisible(0)
        }
    }

    private enum Entry: Equatable {
        case section(GitChangeArea)
        case change(GitChangeArea, String)
    }

    private func selectedEntry() -> Entry? {
        let row = outlineView.selectedRow
        guard row >= 0 else { return nil }
        switch outlineView.item(atRow: row) {
        case let section as SourceControlSection: return .section(section.area)
        case let item as SourceControlItem: return .change(item.change.area, item.change.path)
        default: return nil
        }
    }

    private func select(_ entry: Entry) {
        for section in sections {
            let item: Any? = switch entry {
            case let .section(area) where area == section.area:
                section
            case let .change(area, path) where area == section.area:
                section.items.first { $0.change.path == path }
            default:
                nil
            }
            guard let item else { continue }
            let row = outlineView.row(forItem: item)
            if row >= 0 {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            return
        }
    }

    private func updateToolbar() {
        titleLabel.setChromeText(rootURL.map { $0.path == "/" ? "/" : $0.lastPathComponent } ?? "Source Control", color: colors.textPrimary)
        titleLabel.toolTip = rootURL.map { ($0.path as NSString).abbreviatingWithTildeInPath }
        branchLabel.stringValue = rootURL == nil ? "" : changeList.branch ?? ""
        branchLabel.font = ChromeFont.monospaced(size: 11)
        branchLabel.textColor = colors.textMuted
        refreshButton.isEnabled = rootURL != nil
    }

    private func updateStatus() {
        var message: String?
        var showsSpinner = false
        if GitStatusReader.executableURL == nil {
            message = "Source Control needs Git, which is not installed."
        } else if rootURL == nil {
            message = shownTarget == .notRepository
                ? "Source Control is only available for Git repositories"
                : "Focus a terminal inside a Git repository to see its changes."
        } else if let lastReadSucceeded {
            if !lastReadSucceeded {
                message = "Could not read this repository's status."
            } else if changeList.changes.isEmpty {
                message = "No changes\nThe working tree is clean."
            }
        } else {
            showsSpinner = true
        }
        statusLabel.isHidden = message == nil
        statusLabel.stringValue = message ?? ""
        statusLabel.font = ChromeFont.sans(size: 11)
        statusLabel.textColor = colors.textMuted
        scrollView.isHidden = message != nil || showsSpinner
        if showsSpinner {
            statusSpinner.startAnimation(nil)
        } else {
            statusSpinner.stopAnimation(nil)
        }
    }

    private func showToast(_ message: String) {
        toastLabel.stringValue = message
        toastLabel.isHidden = false
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.toastLabel.isHidden = true
        }
    }

    // MARK: - Actions

    private func toggle(_ section: SourceControlSection) {
        if outlineView.isItemExpanded(section) {
            collapsedAreas.insert(section.area)
            outlineView.collapseItem(section)
        } else {
            collapsedAreas.remove(section.area)
            outlineView.expandItem(section)
        }
    }

    private func fileURL(of change: GitChange) -> URL? {
        rootURL?.appendingPathComponent(change.path)
    }

    /// Opens a change's diff, or the file itself for a conflict, whose
    /// markers are resolved in the editor. The keyboard follows unless
    /// `focus` is false.
    private func open(_ change: GitChange, preview: Bool, focus: Bool = true) {
        guard let url = fileURL(of: change) else { return }
        let opened = if change.area == .conflicts {
            agentManager.openEditor(fileURL: url, preview: preview)
        } else {
            agentManager.openDiff(fileURL: url, staged: change.area == .staged, preview: preview)
        }
        guard opened != nil else {
            showToast(Self.noRoomMessage)
            return
        }
        if focus {
            onReturnFocus?()
        }
    }

    @objc private func refreshClicked() {
        startWatching()
        scheduleRefresh(immediately: true)
    }

    @objc private func rowClicked() {
        let row = outlineView.clickedRow
        guard row >= 0 else { return }
        let modifiers = NSEvent.modifierFlags.intersection([.command, .shift, .option, .control])
        guard modifiers.isEmpty else { return }
        switch outlineView.item(atRow: row) {
        case let section as SourceControlSection:
            toggle(section)
        case let item as SourceControlItem:
            open(item.change, preview: true)
        default:
            break
        }
    }

    @objc private func rowDoubleClicked() {
        let row = outlineView.clickedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? SourceControlItem else { return }
        // A second click keeps the preview opened by the first, like Orca.
        open(item.change, preview: false)
    }

    private func handleKey(_ key: SourceControlOutlineView.Key) -> Bool {
        let row = outlineView.selectedRow
        let item = row >= 0 ? outlineView.item(atRow: row) : nil
        switch key {
        case .escape:
            onReturnFocus?()
        case .space, .return:
            if let section = item as? SourceControlSection {
                toggle(section)
            } else if let change = (item as? SourceControlItem)?.change {
                open(change, preview: key == .space, focus: key == .return)
            }
        case .left, .right:
            guard let section = item as? SourceControlSection else { return false }
            if (key == .right) != outlineView.isItemExpanded(section) {
                toggle(section)
            }
        }
        return true
    }

    // MARK: Context Menu

    @objc private func openDiffFromMenu(_ sender: NSMenuItem) {
        guard let change = sender.representedObject as? GitChange else { return }
        open(change, preview: false)
    }

    @objc private func openFileFromMenu(_ sender: NSMenuItem) {
        guard let change = sender.representedObject as? GitChange, let url = fileURL(of: change) else { return }
        guard agentManager.openEditor(fileURL: url, preview: false) != nil else {
            showToast(Self.noRoomMessage)
            return
        }
        onReturnFocus?()
    }

    @objc private func copyPathFromMenu(_ sender: NSMenuItem) {
        guard let change = sender.representedObject as? GitChange, let url = fileURL(of: change) else { return }
        copyToPasteboard(url.path)
    }

    @objc private func copyRelativePathFromMenu(_ sender: NSMenuItem) {
        guard let change = sender.representedObject as? GitChange else { return }
        copyToPasteboard(change.path)
    }

    @objc private func revealFromMenu(_ sender: NSMenuItem) {
        guard let change = sender.representedObject as? GitChange, let url = fileURL(of: change) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private func menuItem(_ title: String, action: Selector, change: GitChange, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = change
        item.isEnabled = enabled
        return item
    }

    // MARK: - Setup

    private func setupViews() {
        wantsLayer = true

        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        branchLabel.lineBreakMode = .byTruncatingTail
        branchLabel.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        branchLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(branchLabel)

        refreshButton = ChromeIconButton(
            symbolName: "arrow.clockwise",
            accessibilityLabel: "Refresh Source Control",
            pointSize: 12,
            size: 24,
            target: self,
            action: #selector(refreshClicked)
        )
        addSubview(refreshButton)
        addSubview(toolbarRule)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("change"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowHeight = SourceControlOutlineView.rowHeight
        outlineView.rowSizeStyle = .custom
        outlineView.indentationPerLevel = 0
        outlineView.intercellSpacing = .zero
        outlineView.backgroundColor = .clear
        outlineView.style = .plain
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outlineView.allowsMultipleSelection = false
        outlineView.allowsEmptySelection = true
        outlineView.autoresizesOutlineColumn = false
        outlineView.focusRingType = .none
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(rowClicked)
        outlineView.doubleAction = #selector(rowDoubleClicked)
        outlineView.onKey = { [weak self] key in self?.handleKey(key) ?? false }
        outlineView.setAccessibilityLabel("Changes")
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        scrollView.documentView = outlineView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        statusSpinner.style = .spinning
        statusSpinner.controlSize = .small
        statusSpinner.isDisplayedWhenStopped = false
        statusSpinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusSpinner)

        toastLabel.font = ChromeFont.sans(size: 11)
        toastLabel.isHidden = true
        toastLabel.wantsLayer = true
        toastLabel.drawsBackground = true
        toastLabel.isBordered = false
        toastLabel.layer?.borderWidth = Chrome.hairline
        toastLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toastLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.toolbarHeight / 2),
            branchLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            branchLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            branchLabel.trailingAnchor.constraint(lessThanOrEqualTo: refreshButton.leadingAnchor, constant: -6),

            refreshButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            refreshButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            toolbarRule.topAnchor.constraint(equalTo: topAnchor, constant: Self.toolbarHeight),
            toolbarRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbarRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbarRule.heightAnchor.constraint(equalToConstant: Chrome.hairline),

            scrollView.topAnchor.constraint(equalTo: toolbarRule.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            statusLabel.topAnchor.constraint(equalTo: toolbarRule.bottomAnchor, constant: 24),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            statusSpinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusSpinner.topAnchor.constraint(equalTo: toolbarRule.bottomAnchor, constant: 24),

            toastLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            toastLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            toastLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    func applyTheme() {
        let colors = colors
        layer?.backgroundColor = colors.bgPanel.cgColor
        refreshButton.apply(theme: themeManager.currentTheme)
        toolbarRule.color = colors.borderSubtle
        toastLabel.backgroundColor = colors.bgRaised
        toastLabel.textColor = colors.textPrimary
        toastLabel.layer?.borderColor = colors.danger.cgColor
        updateToolbar()
        updateStatus()
        reconfigureVisibleRows()
    }

    private func reconfigureVisibleRows() {
        let visible = outlineView.rows(in: outlineView.visibleRect)
        for row in visible.lowerBound..<visible.upperBound {
            (outlineView.rowView(atRow: row, makeIfNecessary: false) as? FileExplorerRowView)?.colors = colors
            guard let view = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) else { continue }
            configure(view, item: outlineView.item(atRow: row))
        }
    }

    private func configure(_ view: NSView, item: Any?) {
        switch (view, item) {
        case let (cell as SourceControlHeaderCell, section as SourceControlSection):
            cell.configure(section: section, isExpanded: outlineView.isItemExpanded(section), colors: colors)
        case let (cell as SourceControlChangeCell, item as SourceControlItem):
            cell.configure(change: item.change, colors: colors)
        default:
            break
        }
    }
}

// MARK: - Data Source & Delegate

extension SourceControlView: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return sections.count }
        return (item as? SourceControlSection)?.items.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item else { return sections[index] }
        return (item as? SourceControlSection)?.items[index] ?? NSNull()
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is SourceControlSection
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let view: NSView
        if item is SourceControlSection {
            view = outlineView.makeView(withIdentifier: SourceControlHeaderCell.identifier, owner: self)
                ?? SourceControlHeaderCell()
        } else {
            view = outlineView.makeView(withIdentifier: SourceControlChangeCell.identifier, owner: self)
                ?? SourceControlChangeCell()
        }
        configure(view, item: item)
        return view
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let rowView = FileExplorerRowView()
        rowView.colors = colors
        return rowView
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        // A click on a header only toggles it; the keyboard may land on it.
        guard item is SourceControlSection else { return true }
        let type = NSApp.currentEvent?.type
        return type != .leftMouseDown && type != .leftMouseUp && type != .rightMouseDown
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        refreshHeader(notification)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        refreshHeader(notification)
    }

    private func refreshHeader(_ notification: Notification) {
        guard let section = notification.userInfo?["NSObject"] as? SourceControlSection else { return }
        let row = outlineView.row(forItem: section)
        guard row >= 0, let view = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) else { return }
        configure(view, item: section)
    }
}

// MARK: - Context Menu

extension SourceControlView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outlineView.clickedRow
        guard row >= 0,
              let change = (outlineView.item(atRow: row) as? SourceControlItem)?.change,
              let url = fileURL(of: change)
        else { return }
        let exists = FileManager.default.fileExists(atPath: url.path)
        if change.area != .conflicts {
            menu.addItem(menuItem("Open Diff", action: #selector(openDiffFromMenu), change: change))
        }
        menu.addItem(menuItem("Open File", action: #selector(openFileFromMenu), change: change, enabled: exists))
        menu.addItem(.separator())
        menu.addItem(menuItem("Copy Path", action: #selector(copyPathFromMenu), change: change))
        menu.addItem(menuItem("Copy Relative Path", action: #selector(copyRelativePathFromMenu), change: change))
        menu.addItem(.separator())
        menu.addItem(menuItem("Reveal in Finder", action: #selector(revealFromMenu), change: change, enabled: exists))
    }
}

// MARK: - Items

/// A non-empty area of the list; a class so the outline can track it.
private final class SourceControlSection {
    let area: GitChangeArea
    let items: [SourceControlItem]

    init(area: GitChangeArea, items: [SourceControlItem]) {
        self.area = area
        self.items = items
    }
}

private final class SourceControlItem {
    let change: GitChange

    init(change: GitChange) {
        self.change = change
    }
}

// MARK: - Outline View

/// The change list: no native disclosure triangle (headers draw their own
/// chevron), a hover tint, and the list's keys routed to `onKey`.
private final class SourceControlOutlineView: NSOutlineView {
    static let rowHeight: CGFloat = 24

    enum Key {
        case space
        case `return`
        case escape
        case left
        case right
    }

    /// Returns whether the key was handled.
    var onKey: ((Key) -> Bool)?

    private var hoveredRow = -1 {
        didSet {
            guard hoveredRow != oldValue else { return }
            for row in [oldValue, hoveredRow] where row >= 0 && row < numberOfRows {
                (rowView(atRow: row, makeIfNecessary: false) as? FileExplorerRowView)?
                    .isHovered = row == hoveredRow
            }
        }
    }
    private var hoverArea: NSTrackingArea?

    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea {
            removeTrackingArea(hoverArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        hoveredRow = row(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredRow = -1
    }

    override func reloadData() {
        hoveredRow = -1
        super.reloadData()
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .numericPad, .capsLock])
        let key: Key? = switch event.keyCode {
        case 49 where modifiers.isEmpty: .space
        case 36 where modifiers.isEmpty, 76 where modifiers.isEmpty: .return
        case 53: .escape
        case 123 where modifiers.isEmpty: .left
        case 124 where modifiers.isEmpty: .right
        default: nil
        }
        if let key, onKey?(key) == true {
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Cells

/// Chevron, area title, and change count.
private final class SourceControlHeaderCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("source-control-header")

    private let chevronView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let countField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        chevronView.imageScaling = .scaleProportionallyDown
        titleField.lineBreakMode = .byTruncatingTail
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        countField.font = ChromeFont.meta
        countField.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [chevronView, titleField, countField] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            chevronView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            chevronView.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevronView.widthAnchor.constraint(equalToConstant: 12),
            chevronView.heightAnchor.constraint(equalToConstant: 12),
            titleField.leadingAnchor.constraint(equalTo: chevronView.trailingAnchor, constant: 4),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            countField.leadingAnchor.constraint(equalTo: titleField.trailingAnchor, constant: 6),
            countField.firstBaselineAnchor.constraint(equalTo: titleField.firstBaselineAnchor),
            countField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(section: SourceControlSection, isExpanded: Bool, colors: ThemeColors) {
        chevronView.image = FileExplorerCellView.symbol(
            isExpanded ? "chevron.down" : "chevron.right",
            size: 9,
            weight: .bold
        )
        chevronView.contentTintColor = colors.textMuted
        titleField.attributedStringValue = ChromeText.attributed(section.area.title, font: ChromeFont.label, color: colors.textMuted)
        countField.stringValue = "\(section.items.count)"
        countField.textColor = colors.textMuted
    }
}

/// Type icon, name, dimmed folder, line counts, and the status letter.
private final class SourceControlChangeCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("source-control-change")

    private let iconView = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private let directoryField = NSTextField(labelWithString: "")
    private let addedField = NSTextField(labelWithString: "")
    private let deletedField = NSTextField(labelWithString: "")
    private let letterField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        iconView.imageScaling = .scaleProportionallyDown
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        directoryField.font = ChromeFont.monoSmall
        directoryField.lineBreakMode = .byTruncatingHead
        // The folder gives way before the name does.
        directoryField.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        directoryField.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        for field in [addedField, deletedField, letterField] {
            field.font = ChromeFont.monoSmall
            field.alignment = .right
            field.setContentCompressionResistancePriority(.required, for: .horizontal)
            field.setContentHuggingPriority(.required, for: .horizontal)
        }
        let trailing = NSStackView(views: [addedField, deletedField, letterField])
        trailing.orientation = .horizontal
        trailing.spacing = 6
        trailing.detachesHiddenViews = true
        trailing.setHuggingPriority(.required, for: .horizontal)
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [iconView, nameField, directoryField, trailing] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),
            nameField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
            directoryField.leadingAnchor.constraint(equalTo: nameField.trailingAnchor, constant: 6),
            directoryField.firstBaselineAnchor.constraint(equalTo: nameField.firstBaselineAnchor),
            directoryField.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -6),
            nameField.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -6),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(change: GitChange, colors: ThemeColors) {
        let statusColor = change.area == .conflicts
            ? colors.danger
            : FileExplorerCellView.color(for: change.status, colors: colors)
        iconView.image = FileExplorerCellView.symbol(
            FileTypeIcon.symbolName(forFileNamed: change.name),
            size: 11,
            weight: .regular
        )
        iconView.contentTintColor = statusColor

        let isDeleted = change.status == .deleted
        var nameAttributes: [NSAttributedString.Key: Any] = [
            .font: ChromeFont.sans(size: 11),
            .foregroundColor: isDeleted ? colors.textMuted : colors.textPrimary,
        ]
        if isDeleted {
            nameAttributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        nameField.attributedStringValue = NSAttributedString(string: change.name, attributes: nameAttributes)

        directoryField.stringValue = change.directory
        directoryField.textColor = colors.textMuted
        directoryField.isHidden = change.directory.isEmpty

        addedField.stringValue = "+\(change.linesAdded ?? 0)"
        addedField.textColor = colors.success
        addedField.isHidden = (change.linesAdded ?? 0) == 0
        deletedField.stringValue = "\u{2212}\(change.linesDeleted ?? 0)"
        deletedField.textColor = colors.danger
        deletedField.isHidden = (change.linesDeleted ?? 0) == 0

        letterField.attributedStringValue = ChromeText.attributed(
            change.letter,
            font: ChromeFont.label,
            color: statusColor,
            alignment: .right
        )

        toolTip = change.originalPath.map { "\(change.path)\nRenamed from \($0)" } ?? change.path
    }
}
