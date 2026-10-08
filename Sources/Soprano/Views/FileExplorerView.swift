import AppKit

/// The right sidebar's Explorer tab, after Orca's: the focused pane's project
/// as a lazily loaded tree with git decorations, a name filter, inline create
/// and rename, Trash-backed delete, drag and drop, and undo.
///
/// The root follows the active pane: the git working tree containing its
/// directory, or the directory itself outside a repository. Browser and
/// Markdown tabs keep the previous root. Nothing is read, watched, or run
/// while the explorer is inactive (sidebar closed or detached from a window).
final class FileExplorerView: NSView {
    static let toolbarHeight: CGFloat = 32
    /// Name-filter results are capped so a one-letter query in a huge
    /// repository cannot build an unbounded tree.
    static let filterResultLimit = 5_000

    private static let showIgnoredKey = "soprano-explorer-show-ignored"
    private static let hiddenDotfileRootsKey = "soprano-explorer-hidden-dotfile-roots"

    private let agentManager: AgentManager
    private let themeManager: ThemeManager
    private let defaults: UserDefaults
    private let observerId = "FileExplorerView-\(UUID().uuidString)"

    /// Escape in the tree hands the keyboard back to the active pane.
    var onReturnFocus: (() -> Void)?

    // MARK: Views

    private let titleLabel = NSTextField(labelWithString: "")
    private var collapseAllButton: RetroIconButton!
    private var refreshButton: RetroIconButton!
    private var moreButton: RetroIconButton!
    private let toolbarRule = RetroRuleView(axis: .horizontal, style: .single)
    private let filterContainer = NSView()
    private let filterIcon = NSImageView()
    private let filterField = NSTextField(string: "")
    private var clearFilterButton: RetroIconButton!
    private let filterRule = RetroRuleView(axis: .horizontal, style: .single)
    private let scrollView = NSScrollView()
    let outlineView = FileExplorerOutlineView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let statusSpinner = NSProgressIndicator()
    private var retryButton: RetroButton!
    private let toastLabel = NSTextField(wrappingLabelWithString: "")
    private var toastTask: Task<Void, Never>?

    // MARK: State

    private(set) var isActive = false
    private(set) var rootURL: URL?
    private(set) var isGitRepository = false
    private var desiredRoot: (path: String, isGitRepository: Bool)?
    private var realRootPath: String?
    private var rootNode: FileExplorerNode?
    /// Bumped whenever the root changes so late results for the old one are dropped.
    private var rootGeneration = 0
    private var expandedPathsByRoot: [String: Set<String>] = [:]
    private(set) var gitStatus = GitStatusSnapshot.empty
    private var gitRefreshInFlight = false
    private var gitRefreshPending = false
    private var gitRefreshTask: Task<Void, Never>?
    private var lastGitRefresh = Date.distantPast
    private var watcher: FileSystemWatcher?
    /// A linked worktree's or submodule's git directory, which lives outside
    /// the root but holds the index and HEAD that `git status` reads.
    private var externalGitDirectory: String?
    private var pendingReloadPaths: Set<String> = []
    private var visibilityGeneration = 0
    private var pendingSelectionPaths: [String] = []
    /// A folder to load and expand step by step, then act on (a new item).
    private var pendingReveal: (path: String, action: (FileExplorerNode) -> Void)?
    private var editingNode: FileExplorerNode?
    /// Tree changes that arrived while a name was being typed inline.
    private var displayRefreshDeferred = false
    private var isDragging = false
    private var dragHover: (node: FileExplorerNode, since: Date)?
    private var inFlightLoads = 0
    private var isManualRefreshing = false
    private var showsIgnoredFiles: Bool
    private var dotfileHiddenRoots: Set<String>
    let operations = FileExplorerOperations()

    private var filterTokens: [String] = []
    private var filterFiles: [String]?
    private var filterGeneration = 0
    private var filterRoot: FileExplorerNode?
    private var filterReloadTask: Task<Void, Never>?

    private var isFiltering: Bool { !filterTokens.isEmpty }
    private var displayedRoot: FileExplorerNode? { isFiltering ? filterRoot : rootNode }
    private var colors: ThemeColors { themeManager.currentTheme.colors }

    private var expandedPaths: Set<String> {
        get { rootURL.flatMap { expandedPathsByRoot[$0.path] } ?? [] }
        set {
            guard let rootURL else { return }
            expandedPathsByRoot[rootURL.path] = newValue
        }
    }

    private var showsDotfiles: Bool {
        guard let rootURL else { return true }
        return !dotfileHiddenRoots.contains(rootURL.path)
    }

    init(agentManager: AgentManager, themeManager: ThemeManager, defaults: UserDefaults = .standard) {
        self.agentManager = agentManager
        self.themeManager = themeManager
        self.defaults = defaults
        showsIgnoredFiles = defaults.object(forKey: Self.showIgnoredKey) as? Bool ?? true
        dotfileHiddenRoots = Set(defaults.stringArray(forKey: Self.hiddenDotfileRootsKey) ?? [])
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setupViews()
        setupOperations()

        agentManager.addObserver(id: observerId) { [weak self] change in
            switch change {
            case .model, .tabWorkingDirectory:
                self?.syncRootWithActivePane()
            case .tabTitle, .browserURL, .markdownDocument:
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
        updateStatus()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        agentManager.removeObserver(id: observerId)
    }

    // MARK: - Activation

    /// Starts or stops reading, watching and git polling for the current root.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            if let desiredRoot, desiredRoot.path != rootURL?.path {
                setRoot(desiredRoot.path, isGitRepository: desiredRoot.isGitRepository)
            } else if rootNode != nil {
                startWatching()
                refreshAll()
            }
        } else {
            if editingNode != nil {
                finishEditing(commit: true)
            }
            watcher = nil
            gitRefreshTask?.cancel()
            gitRefreshTask = nil
        }
    }

    /// Whether the keyboard is in the explorer: the tree, the filter, or an
    /// inline name field.
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

    /// Moves the keyboard into the tree, onto the first row if nothing is
    /// selected. Only keyboard paths call this: a click selects its own row.
    func focusTree() {
        window?.makeFirstResponder(outlineView)
        if outlineView.selectedRowIndexes.isEmpty, outlineView.numberOfRows > 0 {
            outlineView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    @objc private func applicationDidBecomeActive() {
        // Catches git changes nothing under the watched paths reflects, such
        // as a commit made in another clone of a submodule.
        if isActive {
            scheduleGitRefresh()
        }
    }

    // MARK: - Root

    /// The directory the explorer shows for a pane working in `cwd`.
    static func explorerRoot(forWorkingDirectory cwd: String) -> (path: String, isGitRepository: Bool) {
        let expanded = (cwd as NSString).expandingTildeInPath
        if let repository = GitBranchMonitor.repositoryRoot(startingAt: expanded) {
            return (repository, true)
        }
        return (URL(fileURLWithPath: expanded).standardizedFileURL.path, false)
    }

    private func syncRootWithActivePane() {
        guard let tab = agentManager.panes[agentManager.activePaneId]?.activeTab,
              let cwd = tab.effectiveWorkingDirectory
        else {
            if desiredRoot == nil {
                updateStatus()
            }
            return
        }
        let root = Self.explorerRoot(forWorkingDirectory: cwd)
        desiredRoot = root
        guard isActive, root.path != rootURL?.path || root.isGitRepository != isGitRepository else { return }
        setRoot(root.path, isGitRepository: root.isGitRepository)
    }

    private func setRoot(_ path: String, isGitRepository: Bool) {
        if editingNode != nil {
            finishEditing(commit: true)
        }
        rootGeneration += 1
        let url = URL(fileURLWithPath: path, isDirectory: true)
        rootURL = url
        // FSEvents reports fully resolved paths (`/private/var/…` for
        // `/var/…`); URL's own symlink resolution strips `/private` again.
        realRootPath = realpath(path, nil).map { resolved in
            defer { free(resolved) }
            return String(cString: resolved)
        }
        self.isGitRepository = isGitRepository
        externalGitDirectory = isGitRepository ? Self.externalGitDirectory(forRoot: path) : nil
        gitStatus = .empty
        pendingReloadPaths.removeAll()
        pendingSelectionPaths.removeAll()
        pendingReveal = nil
        displayRefreshDeferred = false
        inFlightLoads = 0
        finishManualRefresh()
        operations.undoManager.removeAllActions()
        clearFilter()
        filterFiles = nil
        rootNode = FileExplorerNode(url: url, relativePath: "", isDirectory: true)
        visibilityGeneration += 1
        outlineView.reloadData()
        updateToolbar()
        updateStatus()
        if let rootNode {
            loadChildren(of: rootNode)
        }
        startWatching()
        scheduleGitRefresh(immediately: true)
    }

    // MARK: - Loading

    private func loadChildren(of node: FileExplorerNode) {
        if node.isLoading {
            node.reloadRequested = true
            return
        }
        node.isLoading = true
        inFlightLoads += 1
        if node.children == nil {
            reconfigureRow(for: node)
        }
        let url = node.url
        let generation = rootGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try FileExplorerListing.entries(in: url) }
            Task { @MainActor [weak self] in
                self?.finishLoading(node, result: result, generation: generation)
            }
        }
    }

    private func finishLoading(
        _ node: FileExplorerNode,
        result: Result<[FileExplorerEntry], Error>,
        generation: Int
    ) {
        guard generation == rootGeneration else { return }
        node.isLoading = false
        inFlightLoads = max(0, inFlightLoads - 1)

        switch result {
        case .success(let entries):
            node.loadError = nil
            let existing = Dictionary(
                (node.children ?? []).filter { $0.placeholder == nil }.map { ($0.name, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let children = entries.map { entry -> FileExplorerNode in
                if let reused = existing[entry.name],
                   reused.isDirectory == entry.isDirectory,
                   reused.isSymlink == entry.isSymlink {
                    return reused
                }
                return FileExplorerNode(
                    url: node.url.appendingPathComponent(entry.name, isDirectory: entry.isDirectory),
                    relativePath: node.childRelativePath(entry.name),
                    isDirectory: entry.isDirectory,
                    isSymlink: entry.isSymlink,
                    parent: node
                )
            }
            let remaining = Set(children.map(\.name))
            let removedFolders = existing.values.filter { $0.isDirectory && !remaining.contains($0.name) }
            if !removedFolders.isEmpty {
                expandedPaths = expandedPaths.filter { path in
                    !removedFolders.contains { path == $0.relativePath || path.hasPrefix($0.relativePath + "/") }
                }
            }
            // An inline new-item row is not on disk yet; keep it in place.
            node.children = children + (node.children ?? []).filter { $0.placeholder != nil }
        case .failure(let error):
            node.loadError = error.localizedDescription
            if node !== rootNode, node.children == nil {
                node.children = []
            }
        }

        refreshDisplay(of: node)
        if !isFiltering {
            applyPendingSelection()
        }
        continueReveal()
        updateStatus()
        updateToolbar()
        finishManualRefreshIfIdle()

        if node.reloadRequested {
            node.reloadRequested = false
            loadChildren(of: node)
        }
    }

    /// Shows `node`'s current children. NSOutlineView caches child counts, so
    /// the arrays it reads may only change right before it is told to reload.
    /// While a name is typed inline, that reload (and with it the new arrays)
    /// waits until editing ends, so the edited row cannot vanish under the caret.
    private func refreshDisplay(of node: FileExplorerNode) {
        if isFiltering {
            // The real tree is off screen while the filter shows results.
            node.visibleChildrenCache = nil
            return
        }
        guard editingNode == nil else {
            displayRefreshDeferred = true
            return
        }
        node.visibleChildrenCache = nil
        reloadOutline(node)
        restoreExpansion(under: node)
    }

    /// Reloads `node`'s rows, keeping the selected paths selected.
    private func reloadOutline(_ node: FileExplorerNode) {
        let selectedPaths = selectedNodes().map(\.relativePath)
        if node === displayedRoot {
            outlineView.reloadData()
        } else if outlineView.row(forItem: node) >= 0 {
            outlineView.reloadItem(node, reloadChildren: true)
        } else {
            return
        }
        select(relativePaths: selectedPaths, scroll: false)
    }

    private func restoreExpansion(under node: FileExplorerNode) {
        let expanded = expandedPaths
        guard !expanded.isEmpty else { return }
        for child in visibleChildren(of: node) where child.isDirectory && expanded.contains(child.relativePath) {
            if !outlineView.isItemExpanded(child) {
                outlineView.expandItem(child)
            } else if child.children != nil {
                restoreExpansion(under: child)
            }
        }
    }

    private func visibleChildren(of node: FileExplorerNode) -> [FileExplorerNode] {
        guard let children = node.children else { return [] }
        if node.visibleChildrenGeneration == visibilityGeneration, let cached = node.visibleChildrenCache {
            return cached
        }
        let hidesDotfiles = !showsDotfiles
        let hidesIgnored = !showsIgnoredFiles && isGitRepository
        let visible = children.filter { child in
            guard child.placeholder == nil else { return true }
            if hidesDotfiles, child.name.count > 1, child.name.hasPrefix(".") {
                return false
            }
            if hidesIgnored, gitStatus.isIgnored(relativePath: child.relativePath) {
                return false
            }
            return true
        }
        node.visibleChildrenCache = visible
        node.visibleChildrenGeneration = visibilityGeneration
        return visible
    }

    private func node(atRelativePath path: String) -> FileExplorerNode? {
        guard var node = rootNode else { return nil }
        guard !path.isEmpty else { return node }
        for segment in path.split(separator: "/") {
            guard let child = node.children?.first(where: { $0.name == segment }) else { return nil }
            node = child
        }
        return node
    }

    private func relativePath(of url: URL) -> String? {
        relativePath(ofPath: url.standardizedFileURL.path)
    }

    /// Root-relative form of an absolute path, matching either the root as
    /// configured or its symlink-resolved form (FSEvents reports the latter).
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

    private static func parentPath(of relativePath: String) -> String {
        guard let slash = relativePath.lastIndex(of: "/") else { return "" }
        return String(relativePath[..<slash])
    }

    /// The resolved git directory of a working tree whose `.git` is a
    /// `gitdir:` file (linked worktree, submodule), or nil when it is the
    /// root's own `.git` folder.
    static func externalGitDirectory(forRoot root: String) -> String? {
        guard let headPath = GitBranchMonitor.resolveHeadPath(startingAt: root),
              let gitDirectory = realpath((headPath as NSString).deletingLastPathComponent, nil)
        else { return nil }
        defer { free(gitDirectory) }
        let path = String(cString: gitDirectory)
        let rootPrefix = realpath(root, nil).map { resolved in
            defer { free(resolved) }
            return String(cString: resolved) + "/"
        } ?? root + "/"
        return path.hasPrefix(rootPrefix) ? nil : path
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
        guard isActive, rootNode != nil else { return }
        if needsRescan {
            refreshAll()
            return
        }
        var changedWorkingTree = false
        var changedGitDirectory = false
        for path in paths {
            if let gitDirectory = externalGitDirectory,
               path == gitDirectory || path.hasPrefix(gitDirectory + "/") {
                changedGitDirectory = true
                continue
            }
            guard let relative = relativePath(ofPath: path) else { continue }
            if relative == ".git" || relative.hasPrefix(".git/") {
                changedGitDirectory = true
                continue
            }
            pendingReloadPaths.insert(Self.parentPath(of: relative))
            // A loaded folder that changed itself (renamed, replaced).
            pendingReloadPaths.insert(relative)
            // Build output in ignored folders cannot change `git status`;
            // skipping it keeps a running build from re-reading git nonstop.
            if !gitStatus.isIgnored(relativePath: relative) {
                changedWorkingTree = true
            }
        }
        flushPendingReloads()
        if changedWorkingTree || changedGitDirectory {
            scheduleGitRefresh()
        }
        if changedWorkingTree, isFiltering {
            scheduleFilterReload()
        }
    }

    /// Reloads folders queued by the watcher or by operations. Held back while
    /// a name is being typed or a drag is in flight, like Orca, so the rows
    /// under the pointer and the caret stay put.
    private func flushPendingReloads() {
        guard editingNode == nil, !isDragging else { return }
        let paths = pendingReloadPaths
        pendingReloadPaths.removeAll()
        for path in paths {
            guard let node = node(atRelativePath: path), node.isDirectory, node.children != nil else { continue }
            loadChildren(of: node)
        }
    }

    /// Reloads the root and every folder loaded so far, and re-reads git.
    private func refreshAll() {
        guard let rootNode else { return }
        var stack = [rootNode]
        while let node = stack.popLast() {
            guard node === rootNode || node.children != nil else { continue }
            loadChildren(of: node)
            stack.append(contentsOf: (node.children ?? []).filter(\.isDirectory))
        }
        scheduleGitRefresh(immediately: true)
        if isFiltering {
            scheduleFilterReload(immediately: true)
        }
    }

    // MARK: - Git

    private func scheduleGitRefresh(immediately: Bool = false) {
        guard isActive, isGitRepository, GitStatusReader.executableURL != nil else { return }
        if gitRefreshInFlight {
            gitRefreshPending = true
            return
        }
        // Bursts (a build, a checkout) coalesce into one read at most every
        // two seconds instead of re-running `git status` per event batch.
        guard gitRefreshTask == nil || immediately else { return }
        gitRefreshTask?.cancel()
        let sinceLast = Date().timeIntervalSince(lastGitRefresh)
        let delay = immediately ? 0 : max(0.4, 2 - sinceLast)
        gitRefreshTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            self?.gitRefreshTask = nil
            self?.runGitRefresh()
        }
    }

    private func runGitRefresh() {
        guard isActive, isGitRepository, let root = rootURL?.path else { return }
        gitRefreshInFlight = true
        lastGitRefresh = Date()
        let generation = rootGeneration
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snapshot = GitStatusReader.snapshot(root: root)
            Task { @MainActor [weak self] in
                self?.finishGitRefresh(snapshot, generation: generation)
            }
        }
    }

    private func finishGitRefresh(_ snapshot: GitStatusSnapshot, generation: Int) {
        gitRefreshInFlight = false
        guard generation == rootGeneration else {
            scheduleGitRefresh(immediately: true)
            finishManualRefreshIfIdle()
            return
        }
        let ignoredChanged = snapshot.ignoredPaths != gitStatus.ignoredPaths
        if snapshot != gitStatus {
            gitStatus = snapshot
            if ignoredChanged, !showsIgnoredFiles {
                reloadVisibility()
            } else {
                reconfigureVisibleRows()
            }
        }
        finishManualRefreshIfIdle()
        if gitRefreshPending {
            gitRefreshPending = false
            scheduleGitRefresh()
        }
    }

    // MARK: - Filter

    private func setFilterQuery(_ query: String) {
        let tokens = FileNameFilter.tokens(query)
        guard tokens != filterTokens else { return }
        let wasFiltering = isFiltering
        filterTokens = tokens
        clearFilterButton.isHidden = query.isEmpty
        if tokens.isEmpty {
            filterRoot = nil
            filterGeneration += 1
            if wasFiltering {
                outlineView.reloadData()
                if let rootNode {
                    restoreExpansion(under: rootNode)
                }
            }
        } else if !wasFiltering {
            // Show the last listing at once, but re-read it: files may have
            // come and gone since the previous search.
            if filterFiles != nil {
                rebuildFilterTree()
            }
            scheduleFilterReload(immediately: true)
        } else if filterFiles != nil {
            rebuildFilterTree()
        }
        updateStatus()
        updateToolbar()
    }

    private func clearFilter() {
        filterField.stringValue = ""
        setFilterQuery("")
    }

    private func scheduleFilterReload(immediately: Bool = false) {
        filterReloadTask?.cancel()
        filterReloadTask = Task { @MainActor [weak self] in
            if !immediately {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            guard !Task.isCancelled else { return }
            self?.loadFilterFiles()
        }
    }

    private func loadFilterFiles() {
        guard let root = rootURL?.path else { return }
        filterGeneration += 1
        let generation = filterGeneration
        let isGitRepository = isGitRepository
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let files = (isGitRepository ? GitStatusReader.listFiles(root: root) : nil)
                ?? Self.enumerateFiles(root: root)
            Task { @MainActor [weak self] in
                guard let self, generation == self.filterGeneration, self.isFiltering else { return }
                self.filterFiles = files
                self.rebuildFilterTree()
                self.updateStatus()
            }
        }
    }

    /// Every file under `root` outside git, skipping the always-hidden folders.
    nonisolated private static func enumerateFiles(root: String, limit: Int = 50_000) -> [String] {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else { return [] }
        let prefixLength = rootURL.standardizedFileURL.path.count + 1
        var files: [String] = []
        while let url = enumerator.nextObject() as? URL, files.count < limit {
            if FileExplorerListing.alwaysHiddenNames.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true else { continue }
            let path = url.standardizedFileURL.path
            guard path.count > prefixLength else { continue }
            files.append(String(path.dropFirst(prefixLength)))
        }
        return files
    }

    private func rebuildFilterTree() {
        guard editingNode == nil else {
            displayRefreshDeferred = true
            return
        }
        guard let rootURL, let files = filterFiles else { return }
        let root = FileExplorerNode(url: rootURL, relativePath: "", isDirectory: true)
        root.children = []
        var folders: [String: FileExplorerNode] = ["": root]
        var matches = 0
        for path in files where matches < Self.filterResultLimit {
            guard FileNameFilter.matches(path, tokens: filterTokens),
                  gitStatus.fileStatuses[path] != .deleted,
                  showsDotfiles || !FileExplorerListing.isDotfile(relativePath: path),
                  showsIgnoredFiles || !gitStatus.isIgnored(relativePath: path)
            else { continue }
            matches += 1
            var parent = root
            var parentPath = ""
            let segments = path.split(separator: "/").map(String.init)
            for segment in segments.dropLast() {
                let folderPath = parentPath.isEmpty ? segment : "\(parentPath)/\(segment)"
                if let folder = folders[folderPath] {
                    parent = folder
                } else {
                    let folder = FileExplorerNode(
                        url: parent.url.appendingPathComponent(segment, isDirectory: true),
                        relativePath: folderPath,
                        isDirectory: true,
                        parent: parent
                    )
                    folder.children = []
                    parent.children?.append(folder)
                    folders[folderPath] = folder
                    parent = folder
                }
                parentPath = folderPath
            }
            guard let name = segments.last else { continue }
            parent.children?.append(FileExplorerNode(
                url: parent.url.appendingPathComponent(name),
                relativePath: path,
                isDirectory: false,
                parent: parent
            ))
        }
        for folder in folders.values {
            folder.children = Self.sortedNodes(folder.children ?? [])
        }
        filterRoot = root
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
    }

    private static func sortedNodes(_ nodes: [FileExplorerNode]) -> [FileExplorerNode] {
        let order = FileExplorerListing.sorted(nodes.map {
            FileExplorerEntry(name: $0.name, isDirectory: $0.isDirectory, isSymlink: $0.isSymlink)
        })
        let byName = Dictionary(nodes.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        return order.compactMap { byName[$0.name] }
    }

    // MARK: - Display

    /// Re-reads every visible folder's rows after the visibility rules or the
    /// ignored set changed.
    private func reloadVisibility() {
        guard editingNode == nil else {
            displayRefreshDeferred = true
            return
        }
        visibilityGeneration += 1
        if isFiltering {
            rebuildFilterTree()
        } else if let rootNode {
            reloadOutline(rootNode)
            restoreExpansion(under: rootNode)
        }
        updateStatus()
    }

    private func reconfigureVisibleRows() {
        outlineView.enumerateAvailableRowViews { [weak self] rowView, row in
            guard let self else { return }
            (rowView as? FileExplorerRowView)?.colors = self.colors
            self.configureCell(atRow: row)
        }
    }

    private func reconfigureRow(for node: FileExplorerNode) {
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        configureCell(atRow: row)
    }

    private func configureCell(atRow row: Int) {
        guard let node = outlineView.item(atRow: row) as? FileExplorerNode,
              node !== editingNode,
              let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileExplorerCellView
        else { return }
        configure(cell, for: node)
    }

    private func configure(_ cell: FileExplorerCellView, for node: FileExplorerNode) {
        cell.configure(
            node: node,
            isExpanded: node.isDirectory && outlineView.isItemExpanded(node),
            status: node.placeholder == nil
                ? gitStatus.status(forRelativePath: node.relativePath, isDirectory: node.isDirectory)
                : nil,
            isIgnored: node.placeholder == nil && gitStatus.isIgnored(relativePath: node.relativePath),
            colors: colors
        )
    }

    private func updateToolbar() {
        let title = rootURL.map { $0.path == "/" ? "/" : $0.lastPathComponent } ?? "Explorer"
        titleLabel.setRetroText(title, color: colors.textPrimary)
        titleLabel.toolTip = rootURL.map { ($0.path as NSString).abbreviatingWithTildeInPath }
        // Like Orca, Collapse All does nothing while the filter shows results.
        collapseAllButton.isEnabled = !isFiltering && !expandedPaths.isEmpty
        refreshButton.isEnabled = rootNode != nil
        moreButton.isEnabled = rootNode != nil
    }

    private func updateStatus() {
        var message: String?
        var showsSpinner = false
        var showsRetry = false
        if rootURL == nil {
            message = "Focus a terminal pane to browse its files"
        } else if isFiltering {
            if filterFiles == nil {
                showsSpinner = true
            } else if filterRoot?.children?.isEmpty != false {
                message = "No files match this filter"
            }
        } else if let rootNode {
            if let error = rootNode.loadError, rootNode.children == nil {
                message = "Could not load files for this workspace: \(error)"
                showsRetry = true
            } else if rootNode.children == nil {
                showsSpinner = true
            } else if visibleChildren(of: rootNode).isEmpty {
                message = "No files in this workspace"
            }
        }
        statusLabel.isHidden = message == nil
        statusLabel.setRetroText(message ?? "", color: colors.textMuted)
        retryButton.isHidden = !showsRetry
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

    private func showError(_ error: Error) {
        showToast((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }

    // MARK: - Selection

    private func selectedNodes() -> [FileExplorerNode] {
        outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? FileExplorerNode }
            .filter { $0.placeholder == nil }
    }

    /// The selection with descendants of other selected folders dropped, so
    /// acting on a folder and its contents does not act twice.
    private func selectedTopLevelNodes() -> [FileExplorerNode] {
        let nodes = selectedNodes()
        let folders = Set(nodes.filter(\.isDirectory).map(\.relativePath))
        return nodes.filter { node in
            var parent = Self.parentPath(of: node.relativePath)
            while !parent.isEmpty {
                if folders.contains(parent) {
                    return false
                }
                parent = Self.parentPath(of: parent)
            }
            return true
        }
    }

    /// The row keyboard commands act on: the last row the selection moved to.
    private var leadNode: FileExplorerNode? {
        let row = outlineView.selectedRow
        guard row >= 0 else { return nil }
        return outlineView.item(atRow: row) as? FileExplorerNode
    }

    private func select(relativePaths: [String], scroll: Bool) {
        guard !relativePaths.isEmpty else { return }
        var rows = IndexSet()
        for path in relativePaths {
            guard let node = displayedNode(atRelativePath: path) else { continue }
            let row = outlineView.row(forItem: node)
            if row >= 0 {
                rows.insert(row)
            }
        }
        guard !rows.isEmpty else { return }
        outlineView.selectRowIndexes(rows, byExtendingSelection: false)
        if scroll, let first = rows.first {
            outlineView.scrollRowToVisible(first)
        }
    }

    /// Like `node(atRelativePath:)`, but in whichever tree is on screen.
    private func displayedNode(atRelativePath path: String) -> FileExplorerNode? {
        guard isFiltering else { return node(atRelativePath: path) }
        guard var node = filterRoot else { return nil }
        for segment in path.split(separator: "/") {
            guard let child = node.children?.first(where: { $0.name == segment }) else { return nil }
            node = child
        }
        return node
    }

    private func applyPendingSelection() {
        guard !pendingSelectionPaths.isEmpty else { return }
        let paths = pendingSelectionPaths
        let present = paths.filter { node(atRelativePath: $0) != nil }
        guard present.count == paths.count else { return }
        pendingSelectionPaths.removeAll()
        // Reveal: expand the folders above each new item first.
        for path in present {
            var ancestors: [FileExplorerNode] = []
            var current = node(atRelativePath: path)?.parent
            while let folder = current, folder !== rootNode {
                ancestors.insert(folder, at: 0)
                current = folder.parent
            }
            for folder in ancestors where !outlineView.isItemExpanded(folder) {
                outlineView.expandItem(folder)
            }
        }
        select(relativePaths: present, scroll: true)
    }

    // MARK: - Actions

    private func toggle(_ node: FileExplorerNode) {
        guard node.isDirectory, node.placeholder == nil else { return }
        if outlineView.isItemExpanded(node) {
            outlineView.collapseItem(node)
        } else {
            outlineView.expandItem(node)
        }
    }

    private func activate(_ node: FileExplorerNode) {
        if node.isDirectory {
            toggle(node)
        } else {
            open(node.url)
        }
    }

    private static func isMarkdown(_ url: URL) -> Bool {
        ["md", "markdown"].contains(url.pathExtension.lowercased())
    }

    /// Markdown opens in Soprano's reader, like `soprano README.md` in the
    /// focused pane; everything else in its default app.
    private func open(_ url: URL) {
        if Self.isMarkdown(url) {
            openMarkdownPreview(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func openMarkdownPreview(_ url: URL) {
        let paneId = agentManager.activePaneId
        if agentManager.panes[paneId] != nil,
           agentManager.previewMarkdown(fileURL: url, in: paneId) != nil {
            return
        }
        _ = agentManager.spawnMarkdown(fileURL: url)
    }

    private func trash(_ nodes: [FileExplorerNode]) {
        let targets = nodes.filter { $0 !== rootNode && $0.placeholder == nil }
        guard !targets.isEmpty else { return }
        do {
            try operations.trash(targets.map(\.url))
        } catch {
            showError(error)
        }
    }

    private func copyPaths(_ nodes: [FileExplorerNode], relative: Bool) {
        guard !nodes.isEmpty else { return }
        let paths = nodes.map { relative ? $0.relativePath : $0.url.path }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    private func copyFiles(_ nodes: [FileExplorerNode]) {
        guard !nodes.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(nodes.map { $0.url as NSURL })
    }

    private func collapseAll() {
        guard !isFiltering else { return }
        outlineView.collapseItem(nil, collapseChildren: true)
        expandedPaths = []
        updateToolbar()
    }

    private func collapseSubtree(_ node: FileExplorerNode) {
        outlineView.collapseItem(node, collapseChildren: true)
        expandedPaths = expandedPaths.filter {
            $0 != node.relativePath && !$0.hasPrefix(node.relativePath + "/")
        }
        updateToolbar()
    }

    private func moveExpandedPaths(from oldPath: String, to newPath: String) {
        expandedPaths = Set(expandedPaths.map { path in
            if path == oldPath {
                return newPath
            }
            if path.hasPrefix(oldPath + "/") {
                return newPath + path.dropFirst(oldPath.count)
            }
            return path
        })
    }

    private func setupOperations() {
        operations.onDirectoriesChanged = { [weak self] directories in
            guard let self else { return }
            for directory in directories {
                if let path = self.relativePath(of: directory) {
                    self.pendingReloadPaths.insert(path)
                }
            }
            self.flushPendingReloads()
            self.scheduleGitRefresh()
            if self.isFiltering {
                self.scheduleFilterReload(immediately: true)
            }
        }
        operations.onUndoFailure = { [weak self] error in
            self?.showError(error)
        }
    }

    // MARK: - Inline Create & Rename

    private func beginCreate(_ kind: FileExplorerNode.Placeholder, in folder: FileExplorerNode) {
        guard editingNode == nil, rootNode != nil, folder.isDirectory else { return }
        let path = folder.relativePath
        // A folder picked from filter results may never have been loaded in
        // the real tree; the filter clears and the path opens down to it.
        if isFiltering {
            clearFilter()
        }
        pendingReveal = (path, { [weak self] target in
            self?.insertPlaceholder(kind, in: target)
        })
        continueReveal()
    }

    /// Walks `pendingReveal` down the real tree, expanding each folder and
    /// waiting for listings that are not loaded yet (each finished load calls
    /// back here), then hands the target folder to its action.
    private func continueReveal() {
        guard let reveal = pendingReveal, var folder = rootNode else { return }
        guard folder.children != nil else {
            if folder.loadError != nil {
                pendingReveal = nil
            } else if !folder.isLoading {
                loadChildren(of: folder)
            }
            return
        }
        for segment in reveal.path.split(separator: "/") {
            guard let child = folder.children?.first(where: { $0.isDirectory && $0.name == segment }) else {
                pendingReveal = nil
                return
            }
            if !outlineView.isItemExpanded(child) {
                outlineView.expandItem(child)
            }
            guard child.children != nil else {
                if !child.isLoading {
                    loadChildren(of: child)
                }
                return
            }
            folder = child
        }
        pendingReveal = nil
        reveal.action(folder)
    }

    private func insertPlaceholder(_ kind: FileExplorerNode.Placeholder, in folder: FileExplorerNode) {
        guard editingNode == nil else { return }
        if folder !== rootNode, !outlineView.isItemExpanded(folder) {
            outlineView.expandItem(folder)
        }
        let placeholder = FileExplorerNode(
            url: folder.url,
            relativePath: folder.childRelativePath("\u{1}new-item"),
            isDirectory: kind == .folder,
            placeholder: kind,
            parent: folder
        )
        folder.children = (folder.children ?? []) + [placeholder]
        refreshDisplay(of: folder)
        beginEditing(placeholder)
        if editingNode !== placeholder {
            // The folder is not on screen after all; drop the empty row.
            folder.children?.removeAll { $0 === placeholder }
            refreshDisplay(of: folder)
        }
    }

    private func beginRename(_ node: FileExplorerNode) {
        guard node.placeholder == nil, node !== displayedRoot else { return }
        beginEditing(node)
    }

    private func beginEditing(_ node: FileExplorerNode) {
        guard editingNode == nil else { return }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        outlineView.scrollRowToVisible(row)
        guard let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? FileExplorerCellView
        else { return }
        editingNode = node
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        cell.beginEditing(colors: colors, delegate: self)
        cell.nameField.stringValue = node.placeholder == nil ? node.name : ""
        window?.makeFirstResponder(cell.nameField)
        if node.placeholder == nil {
            cell.nameField.currentEditor()?.selectedRange = FileExplorerNaming.stemRange(of: node.name)
        }
    }

    private func finishEditing(commit: Bool) {
        guard let node = editingNode else { return }
        editingNode = nil
        let row = outlineView.row(forItem: node)
        let cell = row >= 0
            ? outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileExplorerCellView
            : nil
        let name = (cell?.nameField.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let editorHadFocus = cell.map { cell in
            (window?.firstResponder as? NSText)?.delegate === cell.nameField
        } ?? false
        cell?.endEditing()
        if editorHadFocus {
            window?.makeFirstResponder(outlineView)
        }

        if let kind = node.placeholder, let folder = node.parent {
            folder.children?.removeAll { $0 === node }
            if !displayRefreshDeferred {
                refreshDisplay(of: folder)
            }
            if commit, !name.isEmpty {
                do {
                    let url = kind == .file
                        ? try operations.createFile(named: name, in: folder.url)
                        : try operations.createFolder(named: name, in: folder.url)
                    pendingSelectionPaths = [folder.childRelativePath(url.lastPathComponent)]
                } catch {
                    showError(error)
                }
            }
        } else {
            if let cell {
                configure(cell, for: node)
            }
            if commit, !name.isEmpty, name != node.name {
                do {
                    let url = try operations.rename(node.url, to: name)
                    let newPath = (node.parent ?? node).childRelativePath(url.lastPathComponent)
                    if node.isDirectory {
                        moveExpandedPaths(from: node.relativePath, to: newPath)
                    }
                    pendingSelectionPaths = [newPath]
                } catch {
                    showError(error)
                }
            }
        }
        if displayRefreshDeferred {
            displayRefreshDeferred = false
            reloadVisibility()
        }
        flushPendingReloads()
        applyPendingSelection()
    }

    // MARK: - Setup

    private func setupViews() {
        wantsLayer = true

        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        collapseAllButton = RetroIconButton(
            symbolName: "rectangle.compress.vertical",
            accessibilityLabel: "Collapse All",
            pointSize: 12,
            size: 24,
            target: self,
            action: #selector(collapseAllClicked)
        )
        refreshButton = RetroIconButton(
            symbolName: "arrow.clockwise",
            accessibilityLabel: "Refresh Explorer",
            pointSize: 12,
            size: 24,
            target: self,
            action: #selector(refreshClicked)
        )
        moreButton = RetroIconButton(
            symbolName: "ellipsis",
            accessibilityLabel: "More Explorer Actions",
            pointSize: 12,
            size: 24,
            target: self,
            action: #selector(moreClicked)
        )
        for button in [collapseAllButton, refreshButton, moreButton] {
            if let button {
                addSubview(button)
            }
        }
        addSubview(toolbarRule)

        filterContainer.wantsLayer = true
        filterContainer.layer?.borderWidth = Retro.hairline
        filterContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(filterContainer)

        filterIcon.image = FileExplorerCellView.symbol("line.3.horizontal.decrease", size: 11, weight: .regular)
        filterIcon.translatesAutoresizingMaskIntoConstraints = false
        filterContainer.addSubview(filterIcon)

        filterField.placeholderString = "Find files"
        filterField.isBordered = false
        filterField.drawsBackground = false
        filterField.focusRingType = .none
        filterField.font = RetroFont.body(11)
        filterField.cell?.isScrollable = true
        filterField.cell?.wraps = false
        filterField.delegate = self
        filterField.setAccessibilityLabel("Find files")
        filterField.translatesAutoresizingMaskIntoConstraints = false
        filterContainer.addSubview(filterField)

        clearFilterButton = RetroIconButton(
            symbolName: "xmark",
            accessibilityLabel: "Clear Filter",
            pointSize: 9,
            size: 18,
            target: self,
            action: #selector(clearFilterClicked)
        )
        clearFilterButton.isHidden = true
        filterContainer.addSubview(clearFilterButton)
        addSubview(filterRule)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowHeight = FileExplorerOutlineView.rowHeight
        outlineView.rowSizeStyle = .custom
        outlineView.indentationPerLevel = FileExplorerOutlineView.indentation
        outlineView.intercellSpacing = .zero
        outlineView.backgroundColor = .clear
        outlineView.style = .plain
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outlineView.allowsMultipleSelection = true
        outlineView.allowsEmptySelection = true
        outlineView.autoresizesOutlineColumn = false
        outlineView.focusRingType = .none
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.commands = self
        outlineView.target = self
        outlineView.action = #selector(rowClicked)
        outlineView.doubleAction = #selector(rowDoubleClicked)
        outlineView.registerForDraggedTypes([.fileURL])
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)
        outlineView.setDraggingSourceOperationMask([.move, .copy, .generic], forLocal: true)
        outlineView.draggingDestinationFeedbackStyle = .regular
        outlineView.setAccessibilityLabel("Files")
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

        retryButton = RetroButton(
            title: "Retry",
            theme: themeManager.currentTheme,
            target: self,
            action: #selector(retryClicked)
        )
        retryButton.isHidden = true
        addSubview(retryButton)

        toastLabel.font = RetroFont.body(11)
        toastLabel.isHidden = true
        toastLabel.wantsLayer = true
        toastLabel.drawsBackground = true
        toastLabel.isBordered = false
        toastLabel.layer?.borderWidth = Retro.hairline
        toastLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toastLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.toolbarHeight / 2),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: collapseAllButton.leadingAnchor, constant: -6),

            moreButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            moreButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            refreshButton.trailingAnchor.constraint(equalTo: moreButton.leadingAnchor, constant: -2),
            refreshButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            collapseAllButton.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -2),
            collapseAllButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            toolbarRule.topAnchor.constraint(equalTo: topAnchor, constant: Self.toolbarHeight),
            toolbarRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbarRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbarRule.heightAnchor.constraint(equalToConstant: Retro.hairline),

            filterContainer.topAnchor.constraint(equalTo: toolbarRule.bottomAnchor, constant: 6),
            filterContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            filterContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            filterContainer.heightAnchor.constraint(equalToConstant: Retro.controlHeight + 2),

            filterIcon.leadingAnchor.constraint(equalTo: filterContainer.leadingAnchor, constant: 8),
            filterIcon.centerYAnchor.constraint(equalTo: filterContainer.centerYAnchor),
            filterIcon.widthAnchor.constraint(equalToConstant: 12),
            filterField.leadingAnchor.constraint(equalTo: filterIcon.trailingAnchor, constant: 6),
            filterField.trailingAnchor.constraint(equalTo: clearFilterButton.leadingAnchor, constant: -2),
            filterField.centerYAnchor.constraint(equalTo: filterContainer.centerYAnchor),
            clearFilterButton.trailingAnchor.constraint(equalTo: filterContainer.trailingAnchor, constant: -4),
            clearFilterButton.centerYAnchor.constraint(equalTo: filterContainer.centerYAnchor),

            filterRule.topAnchor.constraint(equalTo: filterContainer.bottomAnchor, constant: 6),
            filterRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            filterRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            filterRule.heightAnchor.constraint(equalToConstant: Retro.hairline),

            scrollView.topAnchor.constraint(equalTo: filterRule.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            statusLabel.topAnchor.constraint(equalTo: filterRule.bottomAnchor, constant: 24),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            statusSpinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusSpinner.topAnchor.constraint(equalTo: filterRule.bottomAnchor, constant: 24),
            retryButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            retryButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),

            toastLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            toastLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            toastLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    func applyTheme() {
        let colors = colors
        layer?.backgroundColor = colors.bgPanel.cgColor
        for button in [collapseAllButton, refreshButton, moreButton, clearFilterButton] {
            button?.setTints(normal: colors.textMuted, hover: colors.accent)
        }
        toolbarRule.color = colors.borderStrong
        filterRule.color = colors.borderStrong
        filterContainer.layer?.backgroundColor = colors.bgRaised.cgColor
        filterContainer.layer?.borderColor = colors.borderStrong.cgColor
        filterIcon.contentTintColor = colors.textMuted
        filterField.textColor = colors.textPrimary
        filterField.placeholderAttributedString = NSAttributedString(
            string: "Find files",
            attributes: [.foregroundColor: colors.textMuted, .font: RetroFont.body(11)]
        )
        retryButton.apply(theme: themeManager.currentTheme)
        toastLabel.backgroundColor = colors.bgRaised
        toastLabel.textColor = colors.textPrimary
        toastLabel.layer?.borderColor = colors.danger.cgColor
        updateToolbar()
        updateStatus()
        reconfigureVisibleRows()
    }

    // MARK: - Toolbar Actions

    @objc private func collapseAllClicked() {
        collapseAll()
    }

    @objc private func refreshClicked() {
        isManualRefreshing = true
        refreshAll()
        // Only swap in the spinner for refreshes long enough to notice.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self, self.isManualRefreshing else { return }
            self.refreshButton.setSymbol("hourglass", accessibilityLabel: "Refreshing Explorer", pointSize: 12)
        }
    }

    private func finishManualRefreshIfIdle() {
        guard isManualRefreshing, inFlightLoads == 0, !gitRefreshInFlight else { return }
        finishManualRefresh()
    }

    private func finishManualRefresh() {
        isManualRefreshing = false
        refreshButton.setSymbol("arrow.clockwise", accessibilityLabel: "Refresh Explorer", pointSize: 12)
    }

    @objc private func retryClicked() {
        guard let rootNode else { return }
        loadChildren(of: rootNode)
        updateStatus()
    }

    @objc private func clearFilterClicked() {
        clearFilter()
        window?.makeFirstResponder(filterField)
    }

    @objc private func moreClicked() {
        let menu = NSMenu()
        let dotfiles = menuItem("Show Dotfiles", action: #selector(toggleDotfiles))
        dotfiles.state = showsDotfiles ? .on : .off
        menu.addItem(dotfiles)
        if isGitRepository {
            let ignored = menuItem("Show Git Ignored Files", action: #selector(toggleIgnoredFiles))
            ignored.state = showsIgnoredFiles ? .on : .off
            menu.addItem(ignored)
        }
        if let rootURL {
            menu.addItem(.separator())
            menu.addItem(NSMenuItem.sectionHeader(title: "Open in"))
            for application in Self.openInApplications() {
                let item = menuItem(application.name, action: #selector(openRootInApplication(_:)))
                item.representedObject = OpenInRequest(folder: rootURL, application: application.url)
                item.image = application.icon
                menu.addItem(item)
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.height + 2), in: moreButton)
    }

    @objc private func toggleDotfiles() {
        guard let rootURL else { return }
        if showsDotfiles {
            dotfileHiddenRoots.insert(rootURL.path)
        } else {
            dotfileHiddenRoots.remove(rootURL.path)
        }
        defaults.set(dotfileHiddenRoots.sorted(), forKey: Self.hiddenDotfileRootsKey)
        reloadVisibility()
    }

    @objc private func toggleIgnoredFiles() {
        showsIgnoredFiles.toggle()
        defaults.set(showsIgnoredFiles, forKey: Self.showIgnoredKey)
        reloadVisibility()
    }

    private struct OpenInRequest {
        let folder: URL
        let application: URL
    }

    private struct OpenInApplication {
        let name: String
        let url: URL
        let icon: NSImage
    }

    /// Finder plus the editors, git clients and terminals that are installed.
    private static func openInApplications() -> [OpenInApplication] {
        let bundleIdentifiers = [
            "com.apple.finder",
            "com.microsoft.VSCode",
            "com.microsoft.VSCodeInsiders",
            "com.todesktop.230313mzl4w4u92",
            "com.exafunction.windsurf",
            "dev.zed.Zed",
            "com.apple.dt.Xcode",
            "com.sublimetext.4",
            "com.panic.Nova",
            "com.jetbrains.intellij",
            "com.jetbrains.intellij.ce",
            "com.jetbrains.WebStorm",
            "com.jetbrains.pycharm",
            "com.jetbrains.goland",
            "com.jetbrains.rustrover",
            "com.DanPristupov.Fork",
            "com.fournova.Tower3",
            "com.github.GitHubClient",
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "com.mitchellh.ghostty",
            "dev.warp.Warp-Stable",
        ]
        let workspace = NSWorkspace.shared
        return bundleIdentifiers.compactMap { identifier in
            guard let url = workspace.urlForApplication(withBundleIdentifier: identifier) else { return nil }
            let icon = workspace.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            return OpenInApplication(
                name: FileManager.default.displayName(atPath: url.path)
                    .replacingOccurrences(of: ".app", with: ""),
                url: url,
                icon: icon
            )
        }
    }

    @objc private func openRootInApplication(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? OpenInRequest else { return }
        NSWorkspace.shared.open(
            [request.folder],
            withApplicationAt: request.application,
            configuration: NSWorkspace.OpenConfiguration()
        ) { [weak self] _, error in
            guard error != nil else { return }
            Task { @MainActor [weak self] in
                self?.showToast("Could not open workspace folder.")
            }
        }
    }

    // MARK: - Row Clicks

    @objc private func rowClicked() {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileExplorerNode else { return }
        let modifiers = NSEvent.modifierFlags.intersection([.command, .shift])
        guard modifiers.isEmpty, node.isDirectory else { return }
        toggle(node)
    }

    @objc private func rowDoubleClicked() {
        let row = outlineView.clickedRow
        guard row >= 0 else {
            if let rootNode {
                beginCreate(.file, in: displayedRoot ?? rootNode)
            }
            return
        }
        guard let node = outlineView.item(atRow: row) as? FileExplorerNode,
              node.placeholder == nil,
              !node.isDirectory
        else { return }
        open(node.url)
    }

    private func menuItem(_ title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }
}

// MARK: - Data Source & Delegate

extension FileExplorerView: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = (item as? FileExplorerNode) ?? displayedRoot else { return 0 }
        return visibleChildren(of: node).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = (item as? FileExplorerNode) ?? displayedRoot else { return NSNull() }
        return visibleChildren(of: node)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? FileExplorerNode else { return false }
        return node.isDirectory && node.placeholder == nil
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileExplorerNode else { return nil }
        let cell = outlineView.makeView(withIdentifier: FileExplorerCellView.identifier, owner: self)
            as? FileExplorerCellView ?? FileExplorerCellView()
        if node !== editingNode {
            cell.endEditing()
        }
        configure(cell, for: node)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let rowView = FileExplorerRowView()
        rowView.colors = colors
        return rowView
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard !isFiltering,
              let node = notification.userInfo?["NSObject"] as? FileExplorerNode,
              node.children == nil
        else { return }
        loadChildren(of: node)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? FileExplorerNode else { return }
        reconfigureRow(for: node)
        guard !isFiltering else { return }
        expandedPaths.insert(node.relativePath)
        if node.children != nil {
            restoreExpansion(under: node)
        }
        updateToolbar()
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? FileExplorerNode else { return }
        reconfigureRow(for: node)
        guard !isFiltering else { return }
        expandedPaths.remove(node.relativePath)
        updateToolbar()
    }

    // MARK: Drag and Drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard editingNode == nil,
              let node = item as? FileExplorerNode,
              node.placeholder == nil
        else { return nil }
        return node.url as NSURL
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint,
        forItems draggedItems: [Any]
    ) {
        isDragging = true
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        isDragging = false
        dragHover = nil
        flushPendingReloads()
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard editingNode == nil, let root = displayedRoot else { return [] }
        let proposed = item as? FileExplorerNode
        let folder = proposed.map { $0.isDirectory ? $0 : ($0.parent ?? root) } ?? root
        outlineView.setDropItem(folder === root ? nil : folder, dropChildIndex: NSOutlineViewDropOnItemIndex)
        expandAfterHovering(folder === root ? nil : folder)

        let urls = Self.fileURLs(from: info.draggingPasteboard)
        guard !urls.isEmpty else { return [] }
        guard (info.draggingSource as? NSOutlineView) === outlineView else { return .copy }
        if NSEvent.modifierFlags.contains(.option) {
            return .copy
        }
        let folderPath = folder.url.standardizedFileURL.path
        let movesIntoItself = urls.contains { url in
            let source = url.standardizedFileURL.path
            return folderPath == source || folderPath.hasPrefix(source + "/")
        }
        let movesAnything = urls.contains { url in
            url.deletingLastPathComponent().standardizedFileURL.path != folderPath
        }
        return !movesIntoItself && movesAnything ? .move : []
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        guard let root = displayedRoot else { return false }
        let folder = (item as? FileExplorerNode) ?? root
        let urls = Self.fileURLs(from: info.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        let isInternalMove = (info.draggingSource as? NSOutlineView) === outlineView
            && !NSEvent.modifierFlags.contains(.option)
        do {
            let results: [(source: URL, target: URL)] = isInternalMove
                ? try operations.move(urls, into: folder.url)
                : try operations.copy(urls, into: folder.url).map { (source: $0, target: $0) }
            if isInternalMove {
                for (source, target) in results {
                    if let oldPath = relativePath(of: source), let newPath = relativePath(of: target) {
                        moveExpandedPaths(from: oldPath, to: newPath)
                    }
                }
            }
            pendingSelectionPaths = results.compactMap { relativePath(of: $0.target) }
            if folder !== root, !outlineView.isItemExpanded(folder) {
                outlineView.expandItem(folder)
            }
            return !results.isEmpty
        } catch {
            showError(error)
            return false
        }
    }

    /// Hovering a drag over a collapsed folder for half a second opens it.
    private func expandAfterHovering(_ folder: FileExplorerNode?) {
        guard let folder, !outlineView.isItemExpanded(folder) else {
            dragHover = nil
            return
        }
        if let dragHover, dragHover.node === folder {
            if Date().timeIntervalSince(dragHover.since) >= 0.5 {
                outlineView.expandItem(folder)
                self.dragHover = nil
            }
        } else {
            dragHover = (folder, Date())
        }
    }

    private static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
    }
}

// MARK: - Context Menu

extension FileExplorerView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let root = displayedRoot else { return }
        let row = outlineView.clickedRow
        guard row >= 0, let clicked = outlineView.item(atRow: row) as? FileExplorerNode,
              clicked.placeholder == nil
        else {
            addCreateItems(to: menu, folder: root)
            return
        }
        // Right-clicking outside the selection acts on just that row.
        if !outlineView.selectedRowIndexes.contains(row) {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        let nodes = selectedNodes()
        let single = nodes.count == 1 ? nodes.first : nil

        addCreateItems(to: menu, folder: clicked.containingFolder)
        menu.addItem(.separator())
        if nodes.count == 1 {
            menu.addItem(menuItem("Copy", action: #selector(copyFilesMenuItem), keyEquivalent: "c"))
        }
        let plural = nodes.count > 1
        let copyPath = menuItem(plural ? "Copy Paths" : "Copy Path", action: #selector(copyPathsMenuItem), keyEquivalent: "c")
        copyPath.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(copyPath)
        let copyRelative = menuItem(
            plural ? "Copy Relative Paths" : "Copy Relative Path",
            action: #selector(copyRelativePathsMenuItem),
            keyEquivalent: "c"
        )
        copyRelative.keyEquivalentModifierMask = [.command, .option, .shift]
        menu.addItem(copyRelative)

        if let single, !single.isDirectory {
            menu.addItem(menuItem("Duplicate", action: #selector(duplicateMenuItem)))
        }
        if let single, single.isDirectory {
            let item = menuItem("Open in Terminal", action: #selector(openInTerminalMenuItem))
            item.representedObject = single
            menu.addItem(item)
        }
        if let single, !single.isDirectory {
            let open = menuItem("Open", action: #selector(openMenuItem))
            open.representedObject = single
            menu.addItem(open)
            if Self.isMarkdown(single.url) {
                let preview = menuItem("Open Markdown Preview", action: #selector(openMarkdownPreviewMenuItem))
                preview.representedObject = single
                menu.addItem(preview)
            }
        }
        if let single, single.isDirectory, !isFiltering, outlineView.isItemExpanded(single) {
            let collapse = menuItem("Collapse Folder", action: #selector(collapseFolderMenuItem))
            collapse.representedObject = single
            menu.addItem(collapse)
        }
        menu.addItem(menuItem("Reveal in Finder", action: #selector(revealInFinderMenuItem)))
        menu.addItem(.separator())
        if let single {
            let rename = menuItem("Rename", action: #selector(renameMenuItem), keyEquivalent: "\r")
            rename.keyEquivalentModifierMask = []
            rename.representedObject = single
            menu.addItem(rename)
        }
        let delete = menuItem("Delete", action: #selector(deleteMenuItem), keyEquivalent: "\u{8}")
        delete.keyEquivalentModifierMask = [.command]
        menu.addItem(delete)
    }

    private func addCreateItems(to menu: NSMenu, folder: FileExplorerNode) {
        let newFile = menuItem("New File", action: #selector(newFileMenuItem(_:)))
        newFile.representedObject = folder
        newFile.image = FileExplorerCellView.symbol("doc.badge.plus", size: 12, weight: .regular)
        menu.addItem(newFile)
        let newFolder = menuItem("New Folder", action: #selector(newFolderMenuItem(_:)))
        newFolder.representedObject = folder
        newFolder.image = FileExplorerCellView.symbol("folder.badge.plus", size: 12, weight: .regular)
        menu.addItem(newFolder)
    }

    @objc private func newFileMenuItem(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? FileExplorerNode else { return }
        beginCreate(.file, in: folder)
    }

    @objc private func newFolderMenuItem(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? FileExplorerNode else { return }
        beginCreate(.folder, in: folder)
    }

    @objc private func copyFilesMenuItem() {
        copyFiles(selectedNodes())
    }

    @objc private func copyPathsMenuItem() {
        copyPaths(selectedNodes(), relative: false)
    }

    @objc private func copyRelativePathsMenuItem() {
        copyPaths(selectedNodes(), relative: true)
    }

    @objc private func duplicateMenuItem() {
        guard let node = selectedNodes().first, !node.isDirectory else { return }
        do {
            let url = try operations.duplicate(node.url)
            pendingSelectionPaths = [relativePath(of: url)].compactMap { $0 }
        } catch {
            showError(error)
        }
    }

    @objc private func openInTerminalMenuItem(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileExplorerNode else { return }
        _ = agentManager.spawnTerminal(cwd: node.url.path)
    }

    @objc private func openMenuItem(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileExplorerNode else { return }
        NSWorkspace.shared.open(node.url)
    }

    @objc private func openMarkdownPreviewMenuItem(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileExplorerNode else { return }
        openMarkdownPreview(node.url)
    }

    @objc private func collapseFolderMenuItem(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileExplorerNode else { return }
        collapseSubtree(node)
    }

    @objc private func revealInFinderMenuItem() {
        let urls = selectedNodes().map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc private func renameMenuItem(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileExplorerNode else { return }
        beginRename(node)
    }

    @objc private func deleteMenuItem() {
        trash(selectedTopLevelNodes())
    }
}

// MARK: - Keyboard Commands

extension FileExplorerView: FileExplorerOutlineCommands {
    var outlineUndoManager: UndoManager { operations.undoManager }

    func outlineRenameSelection() {
        guard selectedNodes().count == 1, let node = selectedNodes().first else { return }
        beginRename(node)
    }

    func outlineActivateSelection() {
        guard let node = leadNode, node.placeholder == nil else { return }
        activate(node)
    }

    func outlineTrashSelection() {
        trash(selectedTopLevelNodes())
    }

    func outlineCopyPaths(relative: Bool) {
        copyPaths(selectedNodes(), relative: relative)
    }

    func outlineCopyFiles() {
        copyFiles(selectedNodes())
    }

    func outlineReturnFocus() {
        onReturnFocus?()
    }

    func outlineCollapseOrSelectParent() {
        guard let node = leadNode else { return }
        if node.isDirectory, outlineView.isItemExpanded(node) {
            outlineView.collapseItem(node)
            return
        }
        guard let parent = node.parent, parent !== displayedRoot else { return }
        let row = outlineView.row(forItem: parent)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
    }

    func outlineExpandOrSelectFirstChild() {
        guard let node = leadNode, node.isDirectory, node.placeholder == nil else { return }
        if !outlineView.isItemExpanded(node) {
            outlineView.expandItem(node)
            return
        }
        guard let first = visibleChildren(of: node).first else { return }
        let row = outlineView.row(forItem: first)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
    }
}

// MARK: - Text Fields

extension FileExplorerView: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextField) === filterField else { return }
        setFilterQuery(filterField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if control === filterField {
            switch commandSelector {
            case #selector(NSResponder.cancelOperation(_:)):
                if filterField.stringValue.isEmpty {
                    onReturnFocus?()
                } else {
                    clearFilter()
                }
                return true
            case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertNewline(_:)):
                window?.makeFirstResponder(outlineView)
                if outlineView.selectedRowIndexes.isEmpty, outlineView.numberOfRows > 0 {
                    outlineView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                }
                return true
            default:
                return false
            }
        }
        guard editingNode != nil else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            finishEditing(commit: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            finishEditing(commit: false)
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard (notification.object as? NSTextField) !== filterField, editingNode != nil else { return }
        // Clicking elsewhere commits the name, as in Orca.
        finishEditing(commit: true)
    }
}
