import AppKit

/// One file's git diff, read-only, drawn as Soprano Agents' diff surface: a
/// subheader with the scope, `+N -N`, change navigation, the stacked | split
/// toggle and line wrapping; the file's sticky header with its path, Copy path
/// and counts; the changes with three lines of context, longer unmodified runs
/// folded behind a "N unmodified lines" strip that shows them on a click;
/// tinted rows with change bars, line numbers and word highlights. Kept
/// current while the tab is shown.
final class DiffPaneView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    static let subheaderHeight: CGFloat = 28
    /// The layout new diff views start in; the toggle updates it.
    static let sideBySideDefaultsKey = "soprano-diff-side-by-side"
    /// Line wrapping, app-wide for the session (Agents' `DiffViewOptions.wrap`, on by default).
    @MainActor static var wrapsLines = true

    let target: TerminalTarget
    let fileURL: URL
    let staged: Bool
    private let themeManager: ThemeManager
    private let defaults: UserDefaults

    var onFocusRequested: (() -> Void)?
    /// Opens the working-tree file in the editor (toolbar button).
    var onOpenFileRequested: ((URL) -> Void)?

    private let subheader = NSView()
    private let scopeLabel = SurfaceDiffScopeLabel()
    private let statsLabel = NSTextField.label(size: Typography.tinySize)
    private var previousButton: ShellGhostButton!
    private var nextButton: ShellGhostButton!
    private let layoutToggle = SurfaceDiffLayoutToggle()
    private var wrapButton: ShellGhostButton!
    private var openFileButton: ShellGhostButton!
    private let scrollView = NSScrollView()
    let tableView = SurfaceDiffTableView()
    private let message = SurfaceMessageView()

    private(set) var document: SurfaceDiffDocument?
    private(set) var list = SurfaceDiffList.empty
    private(set) var layoutMode: SurfaceDiffLayout
    private var wrap = DiffPaneView.wrapsLines
    private var isCollapsed = false
    /// Folds the reader opened (`SurfaceDiffFold.id`).
    private var expandedFolds: Set<Int> = []
    private var style = DiffStyle(palette: PaletteCenter.shared.palette)
    private var numberWidth: CGFloat = 40
    private var heights: [CGFloat] = []
    private var heightsWidth: CGFloat = -1
    private var textOffset: CGFloat = 0
    /// The selected lines; cleared whenever the list is rebuilt.
    private(set) var selection: SurfaceDiffSelection?
    private var fileExists: Bool

    private var location: DiffLocation?
    private var externalGitDirectory: String?
    private var watcher: FileSystemWatcher?
    private var wasDetached = false
    private var hasLoaded = false
    private var loadGeneration = 0
    private var loadInFlight = false
    private var reloadPending = false
    private var reloadTask: Task<Void, Never>?

    init(
        target: TerminalTarget,
        fileURL: URL,
        staged: Bool,
        themeManager: ThemeManager,
        defaults: UserDefaults = .standard
    ) {
        self.target = target
        self.fileURL = fileURL
        self.staged = staged
        self.themeManager = themeManager
        self.defaults = defaults
        layoutMode = defaults.bool(forKey: Self.sideBySideDefaultsKey) ? .split : .unified
        fileExists = FileManager.default.fileExists(atPath: fileURL.path)
        super.init(frame: .zero)
        wantsLayer = true
        setupViews()
        applyTheme()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        load()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    func focusPreferredControl() {
        onFocusRequested?()
        window?.makeFirstResponder(document != nil ? tableView : self)
    }

    // MARK: - Setup

    private func setupViews() {
        scopeLabel.title = staged ? "Staged changes" : "Changes"
        statsLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        previousButton = SurfaceToolbar.button("chevron.up", "Previous Change (⇧F7)", target: self, action: #selector(previousChangeClicked))
        nextButton = SurfaceToolbar.button("chevron.down", "Next Change (F7)", target: self, action: #selector(nextChangeClicked))
        wrapButton = SurfaceToolbar.button("text.word.spacing", "Disable line wrapping", target: self, action: #selector(wrapClicked))
        openFileButton = SurfaceToolbar.button(Icon.fileText, "Open File", target: self, action: #selector(openFileClicked))
        layoutToggle.onChange = { [weak self] layout in self?.setLayout(layout) }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [
            scopeLabel, spacer, statsLabel, previousButton, nextButton, layoutToggle, wrapButton, openFileButton,
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.setCustomSpacing(8, after: statsLabel)
        stack.setCustomSpacing(6, after: nextButton)
        stack.setCustomSpacing(6, after: layoutToggle)
        stack.translatesAutoresizingMaskIntoConstraints = false
        subheader.addSubview(stack)

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
        tableView.focusRingType = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.scrollText = { [weak self] delta in self?.scrollText(by: delta) ?? false }
        tableView.onFocus = { [weak self] in self?.onFocusRequested?() }
        tableView.onNavigate = { [weak self] forward in self?.navigate(forward: forward) }
        tableView.isLineRow = { [weak self] row in self?.isLineRow(row) ?? false }
        tableView.onSelectionBegin = { [weak self] row, x, extend in self?.beginSelection(at: row, x: x, extending: extend) }
        tableView.onSelectionExtend = { [weak self] row in self?.extendSelection(to: row) }
        tableView.onSelectAll = { [weak self] in self?.selectAllLines() }
        tableView.onClearSelection = { [weak self] in self?.setSelection(nil) }
        tableView.onCopy = { [weak self] in self?.copySelection() ?? false }
        tableView.hasSelection = { [weak self] in self?.selectedText()?.isEmpty == false }
        tableView.contextMenu = { [weak self] row, x in self?.contextMenu(row: row, x: x) }
        tableView.setAccessibilityLabel(fileURL.lastPathComponent)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(listWidthChanged),
            name: NSView.frameDidChangeNotification,
            object: scrollView.contentView
        )

        for subview in [subheader, scrollView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        addSubview(message)
        message.pin(centeredIn: scrollView.centerYAnchor, of: self)
        NSLayoutConstraint.activate([
            subheader.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            subheader.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            subheader.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            subheader.heightAnchor.constraint(equalToConstant: Self.subheaderHeight),
            stack.leadingAnchor.constraint(equalTo: subheader.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: subheader.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: subheader.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: subheader.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        updateContentVisibility()
    }

    private func updateContentVisibility() {
        let showsDiff = document != nil
        scrollView.isHidden = !showsDiff
        message.isHidden = showsDiff || message.text.isEmpty
    }

    // MARK: - Theme

    func applyTheme() {
        let palette = PaletteCenter.shared.palette
        style = DiffStyle(palette: palette)
        numberWidth = style.numberWidth(maxLine: document?.maxLine ?? 1)
        layer?.backgroundColor = palette.background.cgColor
        tableView.backgroundColor = palette.background
        heights = []
        heightsWidth = -1
        tableView.reloadData()
        updateChrome()
    }

    private func updateChrome() {
        if let document {
            statsLabel.isHidden = false
            statsLabel.attributedStringValue = DiffStatText.make(
                additions: document.additions,
                deletions: document.deletions,
                palette: style.palette,
                size: Typography.tinySize
            )
        } else {
            statsLabel.isHidden = true
        }
        let hasChanges = !list.changeRows.isEmpty
        previousButton.isEnabled = hasChanges
        nextButton.isEnabled = hasChanges
        layoutToggle.layout = layoutMode
        wrapButton.isOn = wrap
        let wrapLabel = wrap ? "Disable line wrapping" : "Enable line wrapping"
        wrapButton.toolTip = wrapLabel
        wrapButton.setAccessibilityLabel(wrapLabel)
        openFileButton.isEnabled = fileExists
    }

    // MARK: - Loading

    /// Reloads after a quiet spell, never with two reads in flight.
    private func scheduleReload(immediately: Bool = false) {
        if loadInFlight {
            reloadPending = true
            return
        }
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in
            if !immediately {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            guard !Task.isCancelled else { return }
            self?.reloadTask = nil
            self?.load()
        }
    }

    private func load() {
        guard !loadInFlight else {
            reloadPending = true
            return
        }
        loadInFlight = true
        loadGeneration += 1
        let generation = loadGeneration
        let filePath = fileURL.standardizedFileURL.path
        let staged = staged
        if !hasLoaded {
            showLoadingMessageIfSlow()
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = DiffLoader.load(filePath: filePath, staged: staged)
            Task { @MainActor [weak self] in
                self?.finishLoad(result, generation: generation)
            }
        }
    }

    /// A quick first read shows the diff straight away; a slow one says so.
    private func showLoadingMessageIfSlow() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, !self.hasLoaded, self.loadInFlight else { return }
            self.message.text = "Loading diff…"
            self.updateContentVisibility()
        }
    }

    private func finishLoad(_ result: DiffLoadResult, generation: Int) {
        loadInFlight = false
        guard generation == loadGeneration else { return }
        hasLoaded = true
        fileExists = result.fileExists
        updateLocation(result.location)

        switch result.content {
        case .message(let text):
            document = nil
            list = .empty
            message.text = text
            tableView.reloadData()
            updateContentVisibility()
        case .text(let newDocument):
            if newDocument.lines != document?.lines || newDocument.path != document?.path {
                let origin = document != nil ? scrollView.contentView.bounds.origin : nil
                document = newDocument
                numberWidth = style.numberWidth(maxLine: newDocument.maxLine)
                updateContentVisibility()
                rebuildList()
                if let origin {
                    scrollTo(y: origin.y)
                }
            }
        }
        updateChrome()

        if reloadPending {
            reloadPending = false
            scheduleReload()
        }
    }

    private func rebuildList() {
        list = document.map {
            SurfaceDiffList.build($0, layout: layoutMode, collapsed: isCollapsed, expanded: expandedFolds)
        } ?? .empty
        selection = nil
        heights = []
        heightsWidth = -1
        tableView.reloadData()
    }

    // MARK: - Selection

    private func isLineRow(_ row: Int) -> Bool {
        guard list.rows.indices.contains(row) else { return false }
        switch list.rows[row] {
        case .line, .pair: return true
        case .header, .fold, .end: return false
        }
    }

    /// Whether an x in the list falls on the old (left) side of a split row.
    private func isOldSide(x: CGFloat) -> Bool {
        layoutMode == .split && x < SurfaceDiffSplitLineView.dividerX(rowWidth: tableView.bounds.width)
    }

    /// A press on a line: selects it, or with ⇧ extends the selection to it.
    func beginSelection(at row: Int, x: CGFloat, extending: Bool) {
        if extending, var current = selection {
            current.head = row
            setSelection(current)
        } else {
            setSelection(SurfaceDiffSelection(anchor: row, head: row, oldSide: isOldSide(x: x)))
        }
    }

    func extendSelection(to row: Int) {
        guard var current = selection, list.rows.indices.contains(row) else { return }
        current.head = row
        setSelection(current)
    }

    private func selectAllLines() {
        guard let first = list.rows.indices.first(where: isLineRow),
              let last = list.rows.indices.last(where: isLineRow) else { return }
        setSelection(SurfaceDiffSelection(anchor: first, head: last, oldSide: selection?.oldSide ?? false))
    }

    private func setSelection(_ newSelection: SurfaceDiffSelection?) {
        guard newSelection != selection else { return }
        selection = newSelection
        tableView.enumerateAvailableRowViews { rowView, row in
            self.applySelection(to: rowView.view(atColumn: 0), row: row)
        }
    }

    private func applySelection(to view: Any?, row: Int) {
        let selected = selection?.rows.contains(row) == true
        if let cell = view as? SurfaceDiffUnifiedLineView { cell.isLineSelected = selected }
        if let cell = view as? SurfaceDiffSplitLineView { cell.selectedSide = selected ? selection?.oldSide : nil }
    }

    /// The selected lines as the file has them, one per line.
    func selectedText() -> String? {
        guard let selection, let document else { return nil }
        return list.text(of: selection, in: document)
    }

    /// ⌘C: the selected lines on the pasteboard.
    @discardableResult
    func copySelection() -> Bool {
        guard let text = selectedText(), !text.isEmpty else { return false }
        Self.copyToPasteboard(text)
        return true
    }

    private static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Right click: Copy (with a selection), Copy Line (the clicked line, on the clicked side),
    /// Copy File Path.
    private func contextMenu(row: Int, x: CGFloat) -> NSMenu? {
        guard let document else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, enabled: Bool = true, _ action: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(SurfaceDiffMenuAction.run), keyEquivalent: "")
            let target = SurfaceDiffMenuAction(action)
            item.target = target
            item.representedObject = target
            item.isEnabled = enabled
            menu.addItem(item)
        }
        if let text = selectedText(), !text.isEmpty {
            add("Copy") { Self.copyToPasteboard(text) }
        }
        let line = list.line(atRow: row, oldSide: isOldSide(x: x), in: document)
        add("Copy Line", enabled: line != nil) {
            if let line { Self.copyToPasteboard(line.text) }
        }
        let path = fileURL.path
        add("Copy File Path") { Self.copyToPasteboard(path) }
        return menu
    }

    // MARK: - Watching

    private func updateLocation(_ newLocation: DiffLocation?) {
        guard newLocation != location else { return }
        location = newLocation
        externalGitDirectory = newLocation.flatMap { FileExplorerView.externalGitDirectory(forRoot: $0.root) }
        stopWatching()
        if window != nil {
            startWatching()
        }
    }

    private func startWatching() {
        guard watcher == nil, let location else { return }
        let paths = [location.root] + [externalGitDirectory].compactMap { $0 }
        watcher = FileSystemWatcher(paths: paths) { [weak self] paths, needsRescan in
            self?.handleFileSystemEvents(paths, needsRescan: needsRescan)
        }
    }

    private func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    /// Only the file itself and git's own state can change its diff.
    private func handleFileSystemEvents(_ paths: [String], needsRescan: Bool) {
        guard let location else { return }
        let gitDirectory = location.realRoot + "/.git"
        let externalGitDirectory = externalGitDirectory
        let relevant = needsRescan || paths.contains { path in
            if path == location.realFilePath || path == gitDirectory || path.hasPrefix(gitDirectory + "/") {
                return true
            }
            guard let externalGitDirectory else { return false }
            return path == externalGitDirectory || path.hasPrefix(externalGitDirectory + "/")
        }
        if relevant {
            scheduleReload()
        }
    }

    /// Inactive tabs leave the window; they stop watching meanwhile and
    /// catch up when shown again.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            stopWatching()
            wasDetached = true
            return
        }
        startWatching()
        if wasDetached {
            wasDetached = false
            scheduleReload(immediately: true)
        }
    }

    @objc private func applicationDidBecomeActive() {
        guard window != nil, hasLoaded else { return }
        scheduleReload(immediately: true)
    }

    // MARK: - Navigation

    /// The list row a third of the way down the visible area, where change
    /// navigation reads from and puts its target.
    private func anchorRow() -> Int {
        let bounds = scrollView.contentView.bounds
        let row = tableView.row(at: NSPoint(x: 1, y: bounds.minY + bounds.height / 3))
        return row >= 0 ? row : (bounds.minY > 0 ? list.rows.count : 0)
    }

    /// Moves to the next or previous change relative to the row a third of
    /// the way down.
    private func navigate(forward: Bool) {
        guard document != nil, !list.changeRows.isEmpty else { return }
        let anchor = anchorRow()
        let target = forward
            ? list.changeRows.first(where: { $0 > anchor })
            : list.changeRows.last(where: { $0 < anchor })
        guard let target else { return }
        tableView.layoutSubtreeIfNeeded()
        scrollTo(y: tableView.rect(ofRow: target).minY - scrollView.contentView.bounds.height / 3)
    }

    private func scrollTo(y: CGFloat) {
        let maxY = max(0, tableView.frame.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, y), maxY)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// The file line a list row stands for (a split row, the earlier of its two lines).
    private func anchorLine(of row: Int) -> Int? {
        guard let document, list.rows.indices.contains(row) else { return nil }
        switch list.rows[row] {
        case .line(let index):
            return document.unified.rows[index].lineIndex
        case .pair(let index):
            let lines = [document.old.rows[index].lineIndex, document.new.rows[index].lineIndex].compactMap { $0 }
            return lines.min()
        case .fold(let fold):
            return fold.rows.isEmpty ? nil : fold.rows.lowerBound
        case .header, .end:
            return nil
        }
    }

    /// Runs `change` and scrolls back to the file line that was at the top.
    private func preservingTopLine(_ change: () -> Void) {
        let top = tableView.row(at: NSPoint(x: 1, y: scrollView.contentView.bounds.minY + SurfaceDiffDrawing.headerHeight + 1))
        let line = top >= 0 ? anchorLine(of: top) : nil
        change()
        tableView.layoutSubtreeIfNeeded()
        guard let line,
              let row = list.rows.indices.first(where: { (anchorLine(of: $0) ?? -1) >= line })
        else { return }
        scrollTo(y: tableView.rect(ofRow: row).minY - SurfaceDiffDrawing.headerHeight)
    }

    // MARK: - Actions

    @objc private func previousChangeClicked() {
        navigate(forward: false)
    }

    @objc private func nextChangeClicked() {
        navigate(forward: true)
    }

    private func setLayout(_ layout: SurfaceDiffLayout) {
        guard layout != layoutMode else { return }
        layoutMode = layout
        defaults.set(layout == .split, forKey: Self.sideBySideDefaultsKey)
        textOffset = 0
        preservingTopLine { rebuildList() }
        updateChrome()
    }

    /// Stacked ↔ split (also the toggle's two buttons).
    func toggleLayout() {
        setLayout(layoutMode == .unified ? .split : .unified)
    }

    @objc private func wrapClicked() {
        wrap.toggle()
        Self.wrapsLines = wrap
        textOffset = 0
        preservingTopLine {
            heights = []
            heightsWidth = -1
            tableView.reloadData()
        }
        updateChrome()
    }

    private func toggleCollapsed() {
        isCollapsed.toggle()
        rebuildList()
        scrollTo(y: 0)
        updateChrome()
    }

    private func expand(_ fold: SurfaceDiffFold) {
        let row = list.rows.firstIndex(of: .fold(fold))
        let anchorY = row.map { tableView.rect(ofRow: $0).minY - scrollView.contentView.bounds.minY }
        expandedFolds.insert(fold.id)
        rebuildList()
        tableView.layoutSubtreeIfNeeded()
        // The first shown line takes the strip's place on screen.
        if let row, let anchorY, list.rows.indices.contains(row) {
            scrollTo(y: tableView.rect(ofRow: row).minY - anchorY)
        }
        updateChrome()
    }

    @objc private func openFileClicked() {
        onOpenFileRequested?(fileURL)
    }

    override func mouseDown(with event: NSEvent) {
        onFocusRequested?()
        super.mouseDown(with: event)
    }

    // MARK: - Horizontal text scroll (no wrap)

    private func scrollText(by delta: CGFloat) -> Bool {
        guard !wrap, let document else { return false }
        let limit = max(0, ceil(CGFloat(document.maxColumns + 1) * style.columnWidth - codeWidth(rowWidth: listWidth)))
        guard limit > 0 else { return false }
        let next = min(max(0, textOffset + delta), limit)
        guard next != textOffset else { return true }
        textOffset = next
        tableView.enumerateAvailableRowViews { rowView, _ in
            if let cell = rowView.view(atColumn: 0) as? SurfaceDiffUnifiedLineView { cell.textOffset = next }
            if let cell = rowView.view(atColumn: 0) as? SurfaceDiffSplitLineView { cell.textOffset = next }
        }
        return true
    }

    /// Width the code text gets in a row `rowWidth` wide (per side when split).
    private func codeWidth(rowWidth: CGFloat) -> CGFloat {
        let side = layoutMode == .split ? SurfaceDiffSplitLineView.dividerX(rowWidth: rowWidth) : rowWidth
        return max(20, side - numberWidth - DiffStyle.codeInset - DiffStyle.codeTrailing)
    }

    // MARK: - Heights

    /// Width the list lays rows out in (the clip view's; the table column follows it).
    private var listWidth: CGFloat { max(100, scrollView.contentView.bounds.width) }

    /// Wrapped rows change height with the list's width.
    @objc private func listWidthChanged() {
        guard wrap, !list.rows.isEmpty, heightsWidth >= 0, abs(listWidth - heightsWidth) > 0.5 else { return }
        heights = []
        heightsWidth = -1
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<list.rows.count))
    }

    private func height(of row: SurfaceDiffListRow, rowWidth: CGFloat) -> CGFloat {
        switch row {
        case .header: return SurfaceDiffDrawing.headerHeight
        case .fold: return SurfaceDiffDrawing.foldHeight
        case .end: return SurfaceDiffDrawing.endHeight
        case .line(let index):
            guard wrap, let document, let line = document.unified.rows[index].lineIndex else { return DiffStyle.lineHeight }
            return CGFloat(wrappedLines(document.lines[line], width: codeWidth(rowWidth: rowWidth))) * DiffStyle.lineHeight
        case .pair(let index):
            guard wrap, let document else { return DiffStyle.lineHeight }
            let width = codeWidth(rowWidth: rowWidth)
            let count = [document.old.rows[index].lineIndex, document.new.rows[index].lineIndex]
                .compactMap { $0 }
                .map { wrappedLines(document.lines[$0], width: width) }
                .max() ?? 1
            return CGFloat(count) * DiffStyle.lineHeight
        }
    }

    private func wrappedLines(_ line: GitDiffLine, width: CGFloat) -> Int {
        style.wrappedLines(of: DiffLine(kind: .context, text: line.text, oldNumber: nil, newNumber: nil), width: width)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { list.rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard list.rows.indices.contains(row) else { return DiffStyle.lineHeight }
        guard wrap else { return height(of: list.rows[row], rowWidth: 0) }
        if heights.count != list.rows.count || heightsWidth < 0 {
            let width = listWidth
            heightsWidth = width
            heights = list.rows.map { height(of: $0, rowWidth: width) }
        }
        return heights[row]
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        list.rows.indices.contains(row) && list.rows[row] == .header
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("SurfaceDiffRow")
        let rowView = tableView.makeView(withIdentifier: identifier, owner: self) as? SurfaceDiffTableRowView
            ?? SurfaceDiffTableRowView()
        rowView.identifier = identifier
        rowView.palette = style.palette
        return rowView
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let document, list.rows.indices.contains(row) else { return nil }
        switch list.rows[row] {
        case .header:
            let cell = reuse(SurfaceDiffFileHeaderView.identifier) { SurfaceDiffFileHeaderView() }
            cell.configure(document, staged: staged, collapsed: isCollapsed, palette: style.palette)
            cell.onToggle = { [weak self] in self?.toggleCollapsed() }
            return cell
        case .fold(let fold):
            let cell = reuse(SurfaceDiffFoldView.identifier) { SurfaceDiffFoldView() }
            cell.configure(fold, numberWidth: numberWidth, style: style)
            cell.onExpand = { [weak self] in self?.expand(fold) }
            return cell
        case .line(let index):
            let cell = reuse(SurfaceDiffUnifiedLineView.identifier) { SurfaceDiffUnifiedLineView() }
            let layoutRow = document.unified.rows[index]
            guard let side = side(of: layoutRow, in: document, oldSide: layoutRow.kind == .removed) else { return cell }
            cell.configure(side: side, numberWidth: numberWidth, wrap: wrap, textOffset: textOffset, style: style)
            applySelection(to: cell, row: row)
            return cell
        case .pair(let index):
            let cell = reuse(SurfaceDiffSplitLineView.identifier) { SurfaceDiffSplitLineView() }
            cell.configure(
                old: side(of: document.old.rows[index], in: document, oldSide: true),
                new: side(of: document.new.rows[index], in: document, oldSide: false),
                numberWidth: numberWidth,
                wrap: wrap,
                textOffset: textOffset,
                style: style
            )
            applySelection(to: cell, row: row)
            return cell
        case .end:
            return reuse(SurfaceDiffEndView.identifier) { SurfaceDiffEndView() }
        }
    }

    /// What a layout row draws on its side: the old side's number for removed lines (and
    /// the old column of a split row), the new one otherwise; nil for a filler.
    private func side(of row: GitDiffRow, in document: SurfaceDiffDocument, oldSide: Bool) -> SurfaceDiffSide? {
        guard let index = row.lineIndex, row.kind != .filler else { return nil }
        let line = document.lines[index]
        let kind = SurfaceDiffDrawing.kind(row.kind)
        let text = SurfaceDiffDrawing.text(
            line,
            kind: kind,
            tokens: document.tokens(of: row, oldSide: oldSide),
            emphasis: document.emphasis(of: row),
            wrap: wrap,
            style: style
        )
        return SurfaceDiffSide(kind: kind, number: oldSide ? line.oldNumber : line.newNumber, text: text)
    }

    private func reuse<View: NSView>(_ identifier: NSUserInterfaceItemIdentifier, make: () -> View) -> View {
        (tableView.makeView(withIdentifier: identifier, owner: self) as? View) ?? make()
    }
}

// MARK: - Loading

/// Where a diff's file lives, as the watcher reports paths.
private struct DiffLocation: Equatable, Sendable {
    let root: String
    let realRoot: String
    let realFilePath: String
}

private struct DiffLoadResult: Sendable {
    enum Content: Sendable {
        case text(SurfaceDiffDocument)
        case message(String)
    }

    let location: DiffLocation?
    let fileExists: Bool
    let content: Content
}

/// Reads and lays out a diff; blocks on git, so it runs off the main thread.
private enum DiffLoader {
    static func load(filePath: String, staged: Bool) -> DiffLoadResult {
        let fileExists = FileManager.default.fileExists(atPath: filePath)
        func message(_ text: String, _ location: DiffLocation? = nil) -> DiffLoadResult {
            DiffLoadResult(location: location, fileExists: fileExists, content: .message(text))
        }

        guard GitStatusReader.executableURL != nil else { return message("Git is not installed.") }
        // Walks up from the folder, so a deleted file still finds its repository.
        guard let root = GitBranchMonitor.repositoryRoot(startingAt: (filePath as NSString).deletingLastPathComponent)
        else { return message("This file is not in a Git repository.") }
        let realRoot = resolvedPath(root)
        let realFilePath = resolvedPath(filePath)
        guard let relativePath = relativePath(of: filePath, in: root) ?? relativePath(of: realFilePath, in: realRoot)
        else { return message("This file is not in a Git repository.") }
        let location = DiffLocation(root: root, realRoot: realRoot, realFilePath: realFilePath)

        switch GitStatusReader.diff(root: root, relativePath: relativePath, staged: staged) {
        case .text(let lines):
            let language = CodeLanguage.forFile(named: (filePath as NSString).lastPathComponent)
            return DiffLoadResult(
                location: location,
                fileExists: fileExists,
                content: .text(SurfaceDiffDocument(path: relativePath, lines: lines, language: language))
            )
        case .binary:
            return message("Binary file changed\nText diff is unavailable for this file.", location)
        case .tooLarge:
            return message("This diff is too large to show.", location)
        case .noChanges:
            return message(staged ? "No staged changes" : "No changes", location)
        case .emptyFile(let isNew):
            return message(isNew ? "Empty file added" : "Empty file deleted", location)
        case .unavailable:
            return message("Could not read this diff.", location)
        }
    }

    private static func relativePath(of path: String, in root: String) -> String? {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix), path.count > prefix.count else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    /// The symlink-free path, resolving the nearest existing ancestor for a
    /// deleted file.
    private static func resolvedPath(_ path: String) -> String {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != path else { return path }
        return (resolvedPath(parent) as NSString).appendingPathComponent((path as NSString).lastPathComponent)
    }
}
