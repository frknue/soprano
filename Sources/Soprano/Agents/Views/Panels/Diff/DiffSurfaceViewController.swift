import AppKit
import SopranoAgentsCore

/// What the diff surface shows instead of the list.
enum DiffSurfaceMessage: Equatable {
    case loading(String)
    case empty(String)
    case error(String)

    var text: String {
        switch self {
        case let .loading(text), let .empty(text), let .error(text): text
        }
    }
}

/// View options of the diff surface (defaults: stacked, wrapped, whitespace ignored,
/// file tree closed). App-wide for the session.
@MainActor
struct DiffViewOptions {
    var layout: DiffLayout = .unified
    var wrap = true
    var ignoreWhitespace = true
    var showsFileTree = false

    static var current = DiffViewOptions()
}

/// The Diff surface of the right panel: scope menu and toolbar on top, the
/// files as collapsible sections with sticky headers in a virtualized list, the file tree on
/// the right.
@MainActor
final class DiffSurfaceViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let engine: AgentEngine
    let state: WorkspaceState

    /// Files collapse by default past these sizes (huge diffs open as a list of headers).
    static let collapseFilesOver = 40
    static let collapseLinesOver = 6_000

    private(set) var options = DiffViewOptions.current {
        didSet { DiffViewOptions.current = options }
    }
    private(set) var entries: [DiffFileEntry] = []
    private(set) var list = DiffList.empty
    private(set) var collapsed: Set<Int> = []
    private(set) var message: DiffSurfaceMessage?
    private var style = DiffStyle(palette: PaletteCenter.shared.palette)
    private var numberWidths: [CGFloat] = []
    private var heights: [CGFloat] = []
    private var heightsWidth: CGFloat = -1
    private var textOffset: CGFloat = 0
    private var selectedTreeFile: Int?

    private var loadedKey: DiffRequestKey?
    private var generation = 0
    private var needsReload = true

    // Views
    private let subheader = NSView()
    private let scopeButton = DiffScopeButton()
    private let statsLabel = NSTextField.label(size: Typography.tinySize)
    private let refreshButton = GhostIconButton(symbol: "arrow.clockwise", size: 28, symbolSize: 12, toolTip: "Refresh diff")
    private let collapseButton = GhostIconButton(symbol: "rectangle.compress.vertical", size: 28, symbolSize: 12, toolTip: "Collapse all files")
    private let layoutToggle = DiffLayoutToggle()
    private let wrapButton = GhostIconButton(symbol: "text.word.spacing", size: 28, symbolSize: 12, toolTip: "Disable line wrapping")
    private let whitespaceButton = GhostIconButton(symbol: "paragraphsign", size: 28, symbolSize: 12, toolTip: "Show whitespace changes")
    private let treeButton = GhostIconButton(symbol: "list.bullet.indent", size: 28, symbolSize: 12, toolTip: "Show file tree")
    private let scrollView = NSScrollView()
    private let tableView = DiffTableView()
    private let treeView = DiffFileTreeView()
    private var treeWidth: NSLayoutConstraint?
    private let messageLabel = NSTextField.label(size: Typography.smallSize)

    init(engine: AgentEngine, state: WorkspaceState) {
        self.engine = engine
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = DiffSurfaceRootView(frame: NSRect(x: 0, y: 0, width: 540, height: 600))
        view = root
        root.onWidthChange = { [weak self] in self?.rootWidthChanged() }

        buildSubheader()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("diff"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .none
        tableView.floatsGroupRows = true
        tableView.usesAutomaticRowHeights = false
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.gridStyleMask = []
        tableView.dataSource = self
        tableView.delegate = self
        tableView.scrollText = { [weak self] delta in self?.scrollText(by: delta) ?? false }
        tableView.setAccessibilityLabel("Diff")

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(listWidthChanged), name: NSView.frameDidChangeNotification, object: scrollView.contentView
        )

        treeView.onSelectFile = { [weak self] index in self?.reveal(file: index) }

        messageLabel.alignment = .center
        messageLabel.maximumNumberOfLines = 3
        messageLabel.lineBreakMode = .byWordWrapping

        for subview in [subheader, scrollView, treeView, messageLabel] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        let treeWidth = treeView.widthAnchor.constraint(equalToConstant: 0)
        self.treeWidth = treeWidth
        NSLayoutConstraint.activate([
            subheader.topAnchor.constraint(equalTo: root.topAnchor),
            subheader.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            subheader.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            subheader.heightAnchor.constraint(equalToConstant: 28),

            scrollView.topAnchor.constraint(equalTo: subheader.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scrollView.trailingAnchor.constraint(equalTo: treeView.leadingAnchor),

            treeView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            treeView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            treeView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            treeWidth,

            messageLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor, constant: -20),
            messageLabel.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor, constant: -48),
        ])

        PaletteCenter.shared.addObserver(self) { [weak self] palette in self?.applyPalette(palette) }
        state.addObserver(self) { [weak self] change in
            switch change {
            case .panels, .selection: self?.stateChanged()
            case .filter, .composerRestore: break
            }
        }
        engine.addObserver(self) { [weak self] event in
            guard let self else { return }
            switch event {
            case let .threadChanged(threadID) where threadID == state.selectedThreadID:
                refreshIfStale()
            case .threadListChanged:
                refreshIfStale()
            default: break
            }
        }
        applyPalette(PaletteCenter.shared.palette)
        updateToolbar()
        stateChanged()
    }

    // MARK: - Subheader

    private func buildSubheader() {
        scopeButton.onClick = { [weak self] in self?.showScopeMenu() }
        scopeButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        refreshButton.onClick = { [weak self] in self?.reload(force: true) }
        collapseButton.onClick = { [weak self] in self?.toggleCollapseAll() }
        layoutToggle.onChange = { [weak self] layout in self?.setLayout(layout) }
        wrapButton.onClick = { [weak self] in self?.toggleWrap() }
        whitespaceButton.onClick = { [weak self] in self?.toggleWhitespace() }
        treeButton.onClick = { [weak self] in self?.toggleFileTree() }
        statsLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [scopeButton, spacer, statsLabel, refreshButton, collapseButton, layoutToggle, wrapButton, whitespaceButton, treeButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.setCustomSpacing(8, after: statsLabel)
        stack.setCustomSpacing(6, after: collapseButton)
        stack.setCustomSpacing(6, after: layoutToggle)
        stack.translatesAutoresizingMaskIntoConstraints = false
        subheader.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: subheader.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: subheader.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: subheader.centerYAnchor),
        ])
    }

    private func updateToolbar() {
        layoutToggle.layout = options.layout
        wrapButton.isOn = options.wrap
        wrapButton.toolTip = options.wrap ? "Disable line wrapping" : "Enable line wrapping"
        wrapButton.setAccessibilityLabel(options.wrap ? "Disable diff line wrapping" : "Enable diff line wrapping")
        whitespaceButton.isOn = options.ignoreWhitespace
        whitespaceButton.toolTip = options.ignoreWhitespace ? "Show whitespace changes" : "Hide whitespace changes"
        whitespaceButton.setAccessibilityLabel(whitespaceButton.toolTip)
        treeButton.isOn = options.showsFileTree
        treeButton.toolTip = options.showsFileTree ? "Hide file tree" : "Show file tree"
        treeButton.setAccessibilityLabel(treeButton.toolTip)
        let allCollapsed = !entries.isEmpty && collapsed.count == entries.count
        collapseButton.setSymbol(allCollapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical", size: 12)
        collapseButton.toolTip = allCollapsed ? "Expand all files" : "Collapse all files"
        collapseButton.setAccessibilityLabel(collapseButton.toolTip)
        let hasFiles = !entries.isEmpty && message == nil
        collapseButton.isHidden = !hasFiles
        treeButton.isHidden = !hasFiles
        statsLabel.isHidden = !hasFiles
        if hasFiles {
            statsLabel.attributedStringValue = DiffStatText.make(
                additions: entries.reduce(0) { $0 + $1.additions },
                deletions: entries.reduce(0) { $0 + $1.deletions },
                palette: style.palette, size: Typography.tinySize
            )
        }
        scopeButton.title = scopeLabel()
        treeWidth?.constant = options.showsFileTree && hasFiles ? treeWidthValue() : 0
        treeView.isHidden = !(options.showsFileTree && hasFiles)
    }

    private func treeWidthValue() -> CGFloat {
        max(160, min(256, view.bounds.width * 0.4))
    }

    // MARK: - Scope

    private var selectedThread: AgentThread? { engine.thread(state.selectedThreadID) }

    /// Turns that have a checkpoint, oldest first.
    private func checkpointTurns(_ thread: AgentThread?) -> [Turn] {
        (thread?.turns ?? []).filter { $0.checkpoint != nil }
    }

    func scopeLabel() -> String {
        switch state.diffScope {
        case .thread: return "Changes"
        case .uncommitted: return "Uncommitted"
        case let .turn(ordinal):
            if ordinal == checkpointTurns(selectedThread).last?.ordinal { return "Latest turn" }
            return "Turn \(ordinal)"
        }
    }

    private func showScopeMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let thread = selectedThread
        let turns = checkpointTurns(thread)
        func add(_ title: String, _ scope: WorkspaceState.DiffScope, checked: Bool, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.state = checked ? .on : .off
            item.isEnabled = enabled
            item.representedObject = DiffScopeBox(scope)
            item.target = self
            item.action = #selector(selectScope(_:))
            menu.addItem(item)
        }
        let latest = turns.last?.ordinal
        add("Changes", .thread, checked: state.diffScope == .thread, enabled: thread != nil)
        add("Uncommitted", .uncommitted, checked: state.diffScope == .uncommitted)
        add("Latest turn", .turn(latest ?? 0), checked: latest != nil && state.diffScope == .turn(latest ?? 0), enabled: latest != nil)
        let turnItem = NSMenuItem(title: "Turn", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        for turn in turns.reversed() {
            let item = NSMenuItem(title: "Turn \(turn.ordinal)", action: #selector(selectScope(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = DiffScopeBox(.turn(turn.ordinal))
            item.state = state.diffScope == .turn(turn.ordinal) ? .on : .off
            let time = formatter.string(from: turn.completedAt ?? turn.startedAt)
            let title = NSMutableAttributedString(string: "Turn \(turn.ordinal)\t", attributes: [.font: NSFont.menuFont(ofSize: 0)])
            title.append(NSAttributedString(string: time, attributes: [
                .font: Typography.tabular(Typography.smallSize), .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            let paragraph = NSMutableParagraphStyle()
            paragraph.tabStops = [NSTextTab(textAlignment: .right, location: 150)]
            title.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: title.length))
            item.attributedTitle = title
            submenu.addItem(item)
        }
        turnItem.submenu = submenu
        turnItem.isEnabled = !turns.isEmpty
        menu.addItem(turnItem)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: scopeButton.bounds.height + 4), in: scopeButton)
    }

    @objc private func selectScope(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? DiffScopeBox else { return }
        state.showDiff(box.scope)
    }

    // MARK: - Loading

    private var isShowing: Bool {
        state.isRightPanelVisible && state.rightPanelSurface == .diff
    }

    private func stateChanged() {
        guard isViewLoaded else { return }
        updateToolbar()
        guard isShowing else { return }
        let key = requestKey()
        if needsReload || key != loadedKey {
            reload(force: false)
        } else if let path = state.diffFocusPath {
            focus(path: path)
        }
    }

    /// Reloads when a turn finished or a checkpoint landed since the last load.
    private func refreshIfStale() {
        guard isViewLoaded else { return }
        if requestKey() != loadedKey {
            if isShowing { reload(force: false) } else { needsReload = true }
        }
        scopeButton.title = scopeLabel()
    }

    private func requestKey() -> DiffRequestKey {
        let thread = selectedThread
        let turns = checkpointTurns(thread)
        let signature = "\(turns.count)|\(turns.last?.checkpoint?.ref ?? "")|\(turns.last?.checkpoint?.status.rawValue ?? "")|\(thread?.isRunning == true)"
        return DiffRequestKey(threadID: state.selectedThreadID, draftProjectID: state.draftProjectID, scope: state.diffScope,
                              ignoreWhitespace: options.ignoreWhitespace, signature: signature)
    }

    /// The working directory the selection diffs in, nil when there is none.
    private func workingDirectory() -> String? {
        if let thread = selectedThread { return engine.workingDirectory(for: thread) }
        if let projectID = state.draftProjectID { return engine.project(projectID)?.path }
        return nil
    }

    func reload(force: Bool) {
        guard isViewLoaded else { return }
        needsReload = false
        generation += 1
        let generation = generation
        let key = requestKey()
        loadedKey = key
        let scope = state.diffScope
        let thread = selectedThread
        let ignoreWhitespace = options.ignoreWhitespace
        guard let cwd = workingDirectory() else {
            show(message: .empty("No patch available for this selection."))
            return
        }
        if scope != .uncommitted {
            guard let thread else {
                show(message: .empty("No patch available for this selection."))
                return
            }
            if thread.turns.last?.checkpoint?.status == .missing {
                show(message: .empty("Not a git repository."))
                return
            }
            if case let .turn(ordinal) = scope, !thread.turns.contains(where: { $0.ordinal == ordinal && $0.checkpoint != nil }) {
                show(message: .empty("No patch available for this selection."))
                return
            }
            if checkpointTurns(thread).isEmpty {
                show(message: .empty("No net changes in this selection."))
                return
            }
        }
        if !force || entries.isEmpty {
            show(message: .loading(scope == .uncommitted ? "Loading uncommitted changes..." : "Loading checkpoint diff..."))
        }
        let git = engine.environment.git
        let engine = engine
        Task { [weak self] in
            do {
                guard await git.isRepository(cwd) else {
                    self?.finishLoad(generation: generation, result: .failure(.notRepository))
                    return
                }
                let patch: String = switch scope {
                case .uncommitted:
                    try await git.workingTreeDiff(cwd: cwd, ignoreWhitespace: ignoreWhitespace)
                case .thread:
                    try await engine.turnDiff(thread?.id ?? "", turnOrdinal: nil, ignoreWhitespace: ignoreWhitespace)
                case let .turn(ordinal):
                    try await engine.turnDiff(thread?.id ?? "", turnOrdinal: ordinal, ignoreWhitespace: ignoreWhitespace)
                }
                let entries = await Task.detached(priority: .userInitiated) { DiffFileEntry.prepare(patch: patch) }.value
                self?.finishLoad(generation: generation, result: .success(entries))
            } catch {
                self?.finishLoad(generation: generation, result: .failure(.failed(error.localizedDescription)))
            }
        }
    }

    private enum LoadFailure: Error {
        case notRepository
        case failed(String)
    }

    private func finishLoad(generation: Int, result: Result<[DiffFileEntry], LoadFailure>) {
        guard generation == self.generation else { return }
        switch result {
        case .failure(.notRepository):
            show(message: .empty("Not a git repository."))
        case let .failure(.failed(text)):
            show(message: .error(text))
        case let .success(entries):
            if entries.isEmpty {
                if case .turn = state.diffScope {
                    show(message: .empty("No changes in this turn."))
                } else {
                    show(message: .empty("No net changes in this selection."))
                }
                return
            }
            apply(entries)
        }
    }

    private func show(message: DiffSurfaceMessage) {
        self.message = message
        entries = []
        collapsed = []
        rebuildList()
        messageLabel.stringValue = message.text
        messageLabel.isHidden = false
        scrollView.isHidden = true
        updateToolbar()
    }

    private func apply(_ newEntries: [DiffFileEntry]) {
        let previousPaths = entries.map(\.path)
        let previouslyCollapsed = Set(collapsed.compactMap { previousPaths.indices.contains($0) ? previousPaths[$0] : nil })
        let keepsCollapse = !previousPaths.isEmpty && message == nil
        message = nil
        entries = newEntries
        let totalLines = newEntries.reduce(0) { $0 + $1.document.totalLines }
        if keepsCollapse {
            collapsed = Set(newEntries.indices.filter { previouslyCollapsed.contains(newEntries[$0].path) })
        } else if newEntries.count > Self.collapseFilesOver || totalLines > Self.collapseLinesOver {
            collapsed = Set(newEntries.indices)
        } else {
            collapsed = []
        }
        numberWidths = newEntries.map { entry in
            let maxLine = entry.file.hunks.map { max($0.oldStart + $0.oldCount, $0.newStart + $0.newCount) }.max() ?? 1
            return style.numberWidth(maxLine: maxLine)
        }
        textOffset = 0
        messageLabel.isHidden = true
        scrollView.isHidden = false
        treeView.update(items: DiffTreeItem.build(paths: newEntries.map(\.path)), entries: newEntries, palette: style.palette)
        rebuildList()
        updateToolbar()
        if let path = state.diffFocusPath {
            focus(path: path)
        } else if !keepsCollapse {
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func rebuildList() {
        list = DiffList.build(entries: entries, collapsed: collapsed, layout: options.layout)
        heights = []
        heightsWidth = -1
        tableView.reloadData()
    }

    // MARK: - Actions

    func setLayout(_ layout: DiffLayout) {
        guard layout != options.layout else { return }
        options.layout = layout
        textOffset = 0
        preservingTopFile { rebuildList() }
        updateToolbar()
    }

    func toggleLayout() {
        setLayout(options.layout.toggled)
    }

    func toggleWrap() {
        options.wrap.toggle()
        textOffset = 0
        preservingTopFile {
            heights = []
            heightsWidth = -1
            tableView.reloadData()
        }
        updateToolbar()
    }

    func toggleWhitespace() {
        options.ignoreWhitespace.toggle()
        updateToolbar()
        reload(force: true)
    }

    func toggleFileTree() {
        options.showsFileTree.toggle()
        updateToolbar()
    }

    func toggleCollapseAll() {
        let allCollapsed = collapsed.count == entries.count
        collapsed = allCollapsed ? [] : Set(entries.indices)
        rebuildList()
        updateToolbar()
    }

    private func toggle(file: Int) {
        if collapsed.contains(file) { collapsed.remove(file) } else { collapsed.insert(file) }
        let anchorRow = list.fileRows.indices.contains(file) ? list.fileRows[file] : 0
        let anchorY = tableView.rect(ofRow: anchorRow).minY - scrollView.contentView.bounds.minY
        rebuildList()
        // Keep the toggled header where it was on screen.
        if list.fileRows.indices.contains(file) {
            let y = tableView.rect(ofRow: list.fileRows[file]).minY - anchorY
            scrollTo(y: y)
        }
        updateToolbar()
    }

    /// Expands `file` and scrolls its header to the top.
    func reveal(file: Int) {
        guard entries.indices.contains(file) else { return }
        selectedTreeFile = file
        treeView.selectedFile = file
        if collapsed.contains(file) {
            collapsed.remove(file)
            rebuildList()
            updateToolbar()
        }
        tableView.layoutSubtreeIfNeeded()
        scrollTo(y: tableView.rect(ofRow: list.fileRows[file]).minY)
    }

    private func focus(path: String) {
        guard let index = entries.firstIndex(where: { $0.path == path || $0.file.oldPath == path })
            ?? entries.firstIndex(where: { path.hasSuffix("/" + $0.path) || $0.path.hasSuffix("/" + path) }) else { return }
        reveal(file: index)
    }

    private func scrollTo(y: CGFloat) {
        let maxY = max(0, tableView.frame.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, y), maxY)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Runs `change` and scrolls back to the file that was at the top.
    private func preservingTopFile(_ change: () -> Void) {
        let topRow = tableView.row(at: NSPoint(x: 1, y: scrollView.contentView.bounds.minY + 1))
        let file = list.rows.indices.contains(topRow) ? list.rows[topRow].file : nil
        change()
        if let file, list.fileRows.indices.contains(file) {
            scrollTo(y: tableView.rect(ofRow: list.fileRows[file]).minY)
        }
    }

    // MARK: - Horizontal text scroll (no wrap)

    private func scrollText(by delta: CGFloat) -> Bool {
        guard !options.wrap, message == nil else { return false }
        let limit = textScrollLimit()
        guard limit > 0 else { return false }
        let next = min(max(0, textOffset + delta), limit)
        guard next != textOffset else { return true }
        textOffset = next
        tableView.enumerateAvailableRowViews { rowView, _ in
            if let cell = rowView.view(atColumn: 0) as? DiffUnifiedLineView { cell.textOffset = next }
            if let cell = rowView.view(atColumn: 0) as? DiffSplitLineView { cell.textOffset = next }
        }
        return true
    }

    private func textScrollLimit() -> CGFloat {
        var limit: CGFloat = 0
        let width = listWidth
        for (index, entry) in entries.enumerated() where !collapsed.contains(index) {
            let columns = max(entry.document.oldColumns, entry.document.newColumns)
            let textWidth = codeWidth(file: index, rowWidth: width)
            limit = max(limit, CGFloat(columns + 1) * style.columnWidth - textWidth)
        }
        return max(0, ceil(limit))
    }

    /// Width the code text of `file` gets in a row `rowWidth` wide (per side when split).
    private func codeWidth(file: Int, rowWidth: CGFloat) -> CGFloat {
        let gutter = numberWidths.indices.contains(file) ? numberWidths[file] : 40
        let side = options.layout == .split ? DiffSplitLineView.dividerX(rowWidth: rowWidth) : rowWidth
        return max(20, side - gutter - DiffStyle.codeInset - DiffStyle.codeTrailing)
    }

    // MARK: - Heights

    private func rootWidthChanged() {
        if options.showsFileTree, !treeView.isHidden { treeWidth?.constant = treeWidthValue() }
    }

    /// Width the list lays rows out in (the clip view's; the table column follows it).
    private var listWidth: CGFloat { max(100, scrollView.contentView.bounds.width) }

    /// Wrapped rows change height with the list's width.
    @objc private func listWidthChanged() {
        guard options.wrap, !list.rows.isEmpty, heightsWidth >= 0, abs(listWidth - heightsWidth) > 0.5 else { return }
        heights = []
        heightsWidth = -1
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<list.rows.count))
    }

    private func computeHeights() {
        let width = listWidth
        heightsWidth = width
        heights = list.rows.map { row in height(of: row, rowWidth: width) }
    }

    private func height(of row: DiffListRow, rowWidth: CGFloat) -> CGFloat {
        switch row {
        case .fileHeader: return DiffStyle.headerHeight
        case .hunk: return DiffStyle.hunkHeight
        case .notice: return DiffStyle.noticeHeight
        case .fileEnd: return DiffStyle.fileEndHeight
        case let .line(file, hunk, line):
            guard options.wrap else { return DiffStyle.lineHeight }
            let diffLine = entries[file].file.hunks[hunk].lines[line]
            return CGFloat(style.wrappedLines(of: diffLine, width: codeWidth(file: file, rowWidth: rowWidth))) * DiffStyle.lineHeight
        case let .pair(file, hunk, old, new):
            guard options.wrap else { return DiffStyle.lineHeight }
            let lines = entries[file].file.hunks[hunk].lines
            let width = codeWidth(file: file, rowWidth: rowWidth)
            let count = [old, new].compactMap { $0 }.map { style.wrappedLines(of: lines[$0], width: width) }.max() ?? 1
            return CGFloat(count) * DiffStyle.lineHeight
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { list.rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard list.rows.indices.contains(row) else { return DiffStyle.lineHeight }
        if !options.wrap {
            return height(of: list.rows[row], rowWidth: 0)
        }
        if heights.count != list.rows.count || heightsWidth < 0 {
            computeHeights()
        }
        return heights[row]
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard list.rows.indices.contains(row) else { return false }
        if case .fileHeader = list.rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("DiffRow"), owner: self) as? DiffTableRowView
            ?? DiffTableRowView()
        rowView.identifier = NSUserInterfaceItemIdentifier("DiffRow")
        rowView.palette = style.palette
        rowView.isFirstFile = row == 0
        return rowView
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard list.rows.indices.contains(row) else { return nil }
        let palette = style.palette
        switch list.rows[row] {
        case let .fileHeader(file):
            let cell = reuse(DiffFileHeaderView.identifier) { DiffFileHeaderView() }
            cell.configure(entry: entries[file], collapsed: collapsed.contains(file), palette: palette)
            cell.onToggle = { [weak self] in self?.toggle(file: file) }
            return cell
        case let .hunk(file, hunk):
            let cell = reuse(DiffHunkView.identifier) { DiffHunkView() }
            let diff = entries[file].file
            cell.configure(hunk: diff.hunks[hunk], hiddenLines: DiffList.hiddenLines(before: hunk, in: diff),
                           numberWidth: numberWidths[file], style: style)
            return cell
        case let .line(file, hunk, line):
            let cell = reuse(DiffUnifiedLineView.identifier) { DiffUnifiedLineView() }
            let entry = entries[file]
            let diffLine = entry.file.hunks[hunk].lines[line]
            let number = diffLine.kind == .removed ? diffLine.oldNumber : (diffLine.newNumber ?? diffLine.oldNumber)
            let tokens = diffLine.kind == .removed
                ? diffLine.oldNumber.flatMap { entry.highlights.old[$0] }
                : diffLine.newNumber.flatMap { entry.highlights.new[$0] }
            let text = style.text(of: diffLine, tokens: tokens, emphasis: Self.emphasis(in: entry, hunk: hunk, line: line), wrap: options.wrap)
            cell.configure(side: DiffLineSide(kind: diffLine.kind, number: diffLine.kind == .noNewlineMarker ? nil : number, text: text),
                           numberWidth: numberWidths[file], wrap: options.wrap, textOffset: textOffset, style: style)
            return cell
        case let .pair(file, hunk, old, new):
            let cell = reuse(DiffSplitLineView.identifier) { DiffSplitLineView() }
            let entry = entries[file]
            let lines = entry.file.hunks[hunk].lines
            func side(_ index: Int?, isOld: Bool) -> DiffLineSide? {
                guard let index else { return nil }
                let line = lines[index]
                let number = isOld ? line.oldNumber : line.newNumber
                let tokens = number.flatMap { isOld ? entry.highlights.old[$0] : entry.highlights.new[$0] }
                let text = style.text(of: line, tokens: tokens, emphasis: Self.emphasis(in: entry, hunk: hunk, line: index), wrap: options.wrap)
                return DiffLineSide(kind: line.kind, number: line.kind == .noNewlineMarker ? nil : number, text: text)
            }
            cell.configure(old: side(old, isOld: true), new: side(new, isOld: false), numberWidth: numberWidths[file],
                           wrap: options.wrap, textOffset: textOffset, style: style)
            return cell
        case let .notice(_, text):
            let cell = reuse(DiffNoticeView.identifier) { DiffNoticeView() }
            cell.configure(text: text, palette: palette)
            return cell
        case .fileEnd:
            return reuse(DiffFileEndView.identifier) { DiffFileEndView() }
        }
    }

    /// The word emphasis of a line, kept only when the line shares real content with its pair:
    /// at least 3 non-blank characters and a quarter of the line. Two unrelated lines that
    /// merely share indentation or a closing ")" would otherwise light up whole.
    static func emphasis(in entry: DiffFileEntry, hunk: Int, line: Int) -> NSRange? {
        guard let range = entry.document.changedRange(hunk: hunk, line: line) else { return nil }
        let text = entry.file.hunks[hunk].lines[line].text as NSString
        let outside = text.substring(to: min(range.location, text.length))
            + text.substring(from: min(NSMaxRange(range), text.length))
        let shared = outside.filter { !$0.isWhitespace }.count
        let total = (text as String).filter { !$0.isWhitespace }.count
        return shared >= 3 && shared * 4 >= total ? range : nil
    }

    private func reuse<View: NSView>(_ identifier: NSUserInterfaceItemIdentifier, make: () -> View) -> View {
        (tableView.makeView(withIdentifier: identifier, owner: self) as? View) ?? make()
    }

    // MARK: - Palette

    private func applyPalette(_ palette: Palette) {
        style = DiffStyle(palette: palette)
        if !entries.isEmpty {
            numberWidths = entries.map { entry in
                let maxLine = entry.file.hunks.map { max($0.oldStart + $0.oldCount, $0.newStart + $0.newCount) }.max() ?? 1
                return style.numberWidth(maxLine: maxLine)
            }
        }
        view.layer?.backgroundColor = palette.background.cgColor
        tableView.backgroundColor = palette.background
        messageLabel.textColor = palette.mutedForeground
        treeView.palette = palette
        tableView.reloadData()
        updateToolbar()
    }

    /// Makes the list the first responder (right panel focus).
    func focusList() {
        view.window?.makeFirstResponder(tableView)
    }

    var listView: NSView { tableView }
}

/// Identity of a load: reload when any part changes.
struct DiffRequestKey: Equatable {
    var threadID: String?
    var draftProjectID: String?
    var scope: WorkspaceState.DiffScope
    var ignoreWhitespace: Bool
    var signature: String
}

private final class DiffScopeBox: NSObject {
    let scope: WorkspaceState.DiffScope
    init(_ scope: WorkspaceState.DiffScope) { self.scope = scope }
}

/// Background of the surface; reports width changes so wrapped row heights follow.
final class DiffSurfaceRootView: NSView {
    var onWidthChange: (() -> Void)?
    private var lastWidth: CGFloat = -1

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        if abs(bounds.width - lastWidth) > 0.5 {
            lastWidth = bounds.width
            onWidthChange?()
        }
    }
}

/// The diff list. Horizontal gestures (trackpad, ⇧ + wheel) scroll the code text instead of
/// the list when lines do not wrap; a gesture keeps the axis it started on.
final class DiffTableView: NSTableView {
    var scrollText: ((CGFloat) -> Bool)?
    private var gestureIsHorizontal: Bool?

    override func scrollWheel(with event: NSEvent) {
        if !event.phase.isDisjoint(with: [.began, .mayBegin]) {
            gestureIsHorizontal = nil
        }
        let inGesture = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        let isHorizontal: Bool
        if inGesture, let locked = gestureIsHorizontal {
            isHorizontal = locked
        } else if dx == 0, dy == 0 {
            super.scrollWheel(with: event)
            return
        } else {
            isHorizontal = abs(dx) > abs(dy)
            if inGesture { gestureIsHorizontal = isHorizontal }
        }
        let delta = -dx * (event.hasPreciseScrollingDeltas ? 1 : 24)
        if isHorizontal, let scrollText, scrollText(delta) { return }
        super.scrollWheel(with: event)
    }
}

/// The small secondary scope trigger: label and a chevron.
final class DiffScopeButton: InteractiveView {
    private let label = NSTextField.label(size: Typography.smallSize, weight: .medium)
    private let chevron = NSImageView()

    var title: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            setAccessibilityLabel("Diff scope: \(newValue)")
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = Radius.lg
        chevron.image = NSImage.symbol(Icon.chevronDown, size: 10, weight: .medium)
        chevron.imageScaling = .scaleNone
        let stack = NSStackView(views: [label, chevron])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 24),
        ])
        setAccessibilityRole(.popUpButton)
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = (isHovered ? palette.accent : palette.secondary).cgColor
        layer?.borderWidth = palette.isDark ? 0 : 1
        layer?.borderColor = palette.border.fading(0.7).cgColor
        label.textColor = palette.foreground
        chevron.contentTintColor = palette.foreground.withAlphaComponent(0.7)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        // Menus open on press, like dropdown triggers.
        onClick?()
    }

    override func mouseUp(with event: NSEvent) {}
}

/// The segmented "Diff layout" toggle group: Stacked | Split.
final class DiffLayoutToggle: PaletteView {
    var onChange: ((DiffLayout) -> Void)?
    var layout: DiffLayout = .unified {
        didSet { applyPalette(palette) }
    }

    private let stacked = GhostIconButton(symbol: "rectangle.grid.1x2", size: 24, symbolSize: 11, toolTip: "Stacked diff view")
    private let split = GhostIconButton(symbol: "rectangle.split.2x1", size: 24, symbolSize: 11, toolTip: "Split diff view")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = Radius.lg
        let stack = NSStackView(views: [stacked, split])
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        stacked.onClick = { [weak self] in self?.onChange?(.unified) }
        split.onClick = { [weak self] in self?.onChange?(.split) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Diff layout")
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.foreground.withAlphaComponent(palette.isDark ? 0.06 : 0.05).cgColor
        stacked.isOn = layout == .unified
        split.isOn = layout == .split
        for button in [stacked, split] {
            button.layer?.backgroundColor = (button.isOn ? palette.popover : .clear).cgColor
            button.layer?.cornerRadius = Radius.md
        }
    }
}
