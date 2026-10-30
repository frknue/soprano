import AppKit
import SopranoAgentsCore

/// The Files surface of the right panel: a search field and Refresh over the selected thread's
/// working directory as a folder tree (folders first, alphabetical). Clicking a file opens it as
/// a file tab; typing in search shows the matching files as a flat list. Listings and folder
/// expansion are kept per thread for the session.
@MainActor
final class FilesSurfaceViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    let engine: AgentEngine
    let state: WorkspaceState
    /// Called after a file opened in its tab, so the panel moves the keyboard there.
    var onOpenFile: (() -> Void)?

    static let headerHeight: CGFloat = 40
    static let rowHeight: CGFloat = 24

    private enum Listing {
        case loading
        case loaded(WorkspaceFileTree)
        case failed(String)
    }

    /// Listing per thread id.
    private var listings: [String: Listing] = [:]
    /// Successful loads per thread, so the outline rebuilds only for a new listing.
    private var versions: [String: Int] = [:]
    /// Generation of the newest load per thread; older results are dropped.
    private var pendingLoads: [String: Int] = [:]
    private var generation = 0
    /// Threads whose listing is out of date (a turn ended while the surface was hidden).
    private var staleThreads: Set<String> = []
    /// Threads seen running, to notice when their turn ends.
    private var runningThreads: Set<String> = []
    /// Expanded folder paths per thread.
    private var expanded: [String: Set<String>] = [:]

    /// The rows on screen: the tree's roots, or the search matches (flat).
    private var rows: [WorkspaceFileNode] = []
    private var isSearching = false
    /// Identity of what `rows` was built from, so unrelated state changes keep the outline.
    private var shownKey: String?
    private var lastThreadID: String?
    private var isRestoringExpansion = false

    // Views
    private let header = NSView()
    private let headerRule = HairlineView()
    private let searchField = FilesSearchField()
    private let refreshButton = GhostIconButton(symbol: "arrow.clockwise", size: 28, symbolSize: 12, toolTip: "Refresh files")
    private let scrollView = NSScrollView()
    private let outlineView = FilesOutlineView()
    private let messageLabel = NSTextField.label(size: Typography.smallSize)
    private let contextMenu = NSMenu()

    init(engine: AgentEngine, state: WorkspaceState) {
        self.engine = engine
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = FilesSurfaceRootView(frame: NSRect(x: 0, y: 0, width: 540, height: 600))
        view = root

        searchField.onChange = { [weak self] _ in self?.render() }
        searchField.onSubmit = { [weak self] in self?.openFirstMatch() }
        searchField.onMoveDown = { [weak self] in self?.focusTree() }
        searchField.onEscape = { [weak self] in self?.focusTree() }
        refreshButton.onClick = { [weak self] in self?.refresh() }
        let stack = NSStackView(views: [searchField, refreshButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        searchField.setContentHuggingPriority(.init(1), for: .horizontal)
        header.addSubview(stack)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .plain
        outlineView.indentationPerLevel = 0
        outlineView.intercellSpacing = NSSize(width: 0, height: 2)
        outlineView.rowHeight = Self.rowHeight
        outlineView.backgroundColor = .clear
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outlineView.allowsMultipleSelection = false
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(rowClicked)
        outlineView.onActivate = { [weak self] row in self?.activate(row: row) }
        outlineView.onEscape = { [weak self] in self?.escapeFromTree() ?? false }
        outlineView.setAccessibilityLabel("Files")
        contextMenu.delegate = self
        contextMenu.autoenablesItems = false
        outlineView.menu = contextMenu

        scrollView.documentView = outlineView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)

        messageLabel.alignment = .center
        messageLabel.maximumNumberOfLines = 4
        messageLabel.lineBreakMode = .byWordWrapping

        for subview in [header, headerRule, scrollView, messageLabel] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),
            stack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            headerRule.topAnchor.constraint(equalTo: header.bottomAnchor),
            headerRule.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerRule.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            headerRule.heightAnchor.constraint(equalToConstant: 1),

            scrollView.topAnchor.constraint(equalTo: headerRule.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            messageLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor, constant: -20),
            messageLabel.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -48),
        ])

        runningThreads = Set(engine.threads.filter(\.isRunning).map(\.id))
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
            case let .threadChanged(threadID): threadChanged(threadID)
            case .threadListChanged: pruneDeletedThreads()
            default: break
            }
        }
        applyPalette(PaletteCenter.shared.palette)
        stateChanged()
    }

    // MARK: - Focus

    /// Makes the tree (or the search matches) the first responder, selecting the first row when
    /// nothing is selected.
    func focusTree() {
        guard isViewLoaded else { return }
        if outlineView.selectedRow < 0, outlineView.numberOfRows > 0 {
            outlineView.selectRowIndexes([0], byExtendingSelection: false)
        }
        view.window?.makeFirstResponder(outlineView)
    }

    /// Puts the caret in the search field.
    func focusSearch() {
        guard isViewLoaded else { return }
        searchField.focus()
    }

    // MARK: - State

    private var isShowing: Bool {
        state.isRightPanelVisible && state.rightPanelSurface == .files
    }

    private func stateChanged() {
        guard isViewLoaded else { return }
        if state.selectedThreadID != lastThreadID {
            lastThreadID = state.selectedThreadID
            if !searchField.text.isEmpty { searchField.text = "" }
        }
        render()
    }

    /// Reloads the listing of a thread whose turn just ended (now if it shows, else when it does).
    private func threadChanged(_ threadID: String) {
        let isRunning = engine.thread(threadID)?.isRunning == true
        if isRunning {
            runningThreads.insert(threadID)
            return
        }
        guard runningThreads.remove(threadID) != nil, listings[threadID] != nil else { return }
        staleThreads.insert(threadID)
        render()
    }

    private func pruneDeletedThreads() {
        let ids = Set(engine.threads.map(\.id))
        for key in listings.keys where !ids.contains(key) {
            listings[key] = nil
            versions[key] = nil
            pendingLoads[key] = nil
            expanded[key] = nil
            staleThreads.remove(key)
        }
        runningThreads.formIntersection(ids)
    }

    private func refresh() {
        guard let threadID = state.selectedThreadID, engine.thread(threadID) != nil else { return }
        load(threadID)
    }

    // MARK: - Loading

    private func load(_ threadID: String) {
        generation += 1
        let generation = generation
        pendingLoads[threadID] = generation
        staleThreads.remove(threadID)
        if case .loaded = listings[threadID] {
            // Keep the current tree on screen while it refreshes.
        } else {
            listings[threadID] = .loading
        }
        let engine = engine
        Task { [weak self] in
            let listing: Listing
            do {
                let paths = try await engine.workspaceFiles(threadID)
                let tree = await Task.detached(priority: .userInitiated) { WorkspaceFileTree(paths: paths) }.value
                listing = .loaded(tree)
            } catch {
                listing = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            self?.finishLoad(threadID: threadID, generation: generation, listing: listing)
        }
        render()
    }

    private func finishLoad(threadID: String, generation: Int, listing: Listing) {
        guard pendingLoads[threadID] == generation else { return }
        pendingLoads[threadID] = nil
        listings[threadID] = listing
        if case let .loaded(tree) = listing {
            versions[threadID, default: 0] += 1
            if var folders = expanded[threadID] {
                folders.formIntersection(tree.directoryPaths)
                expanded[threadID] = folders
            }
        }
        render()
    }

    // MARK: - Rendering

    private func render() {
        guard isViewLoaded, isShowing else { return }
        guard let threadID = state.selectedThreadID, engine.thread(threadID) != nil else {
            show(message: "Start the thread to browse its files.")
            return
        }
        guard let listing = listings[threadID] else {
            load(threadID)
            return
        }
        if staleThreads.contains(threadID), pendingLoads[threadID] == nil {
            load(threadID)
            return
        }
        switch listing {
        case .loading:
            show(message: "Loading files…")
        case let .failed(text):
            show(message: text)
        case let .loaded(tree):
            showTree(tree, threadID: threadID)
        }
    }

    private func show(message: String) {
        shownKey = nil
        rows = []
        outlineView.reloadData()
        messageLabel.stringValue = message
        messageLabel.isHidden = false
        scrollView.isHidden = true
    }

    private func showTree(_ tree: WorkspaceFileTree, threadID: String) {
        guard !tree.isEmpty else {
            show(message: "No files.")
            return
        }
        let query = searchField.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = "\(threadID)\u{0}\(versions[threadID] ?? 0)\u{0}\(query)"
        if key != shownKey {
            shownKey = key
            isSearching = !query.isEmpty
            if isSearching {
                rows = tree.search(query).map { path in
                    WorkspaceFileNode(name: path.split(separator: "/").last.map(String.init) ?? path, path: path, isDirectory: false)
                }
            } else {
                rows = tree.roots
            }
            outlineView.reloadData()
            if isSearching {
                if !rows.isEmpty { outlineView.selectRowIndexes([0], byExtendingSelection: false) }
                outlineView.scrollRowToVisible(0)
            } else {
                restoreExpansion(rows, threadID: threadID)
            }
        }
        if rows.isEmpty {
            messageLabel.stringValue = "No matching files."
            messageLabel.isHidden = false
            scrollView.isHidden = true
        } else {
            messageLabel.isHidden = true
            scrollView.isHidden = false
        }
    }

    private func restoreExpansion(_ nodes: [WorkspaceFileNode], threadID: String) {
        guard let folders = expanded[threadID], !folders.isEmpty else { return }
        isRestoringExpansion = true
        defer { isRestoringExpansion = false }
        func walk(_ nodes: [WorkspaceFileNode]) {
            for node in nodes where node.isDirectory && folders.contains(node.path) {
                outlineView.expandItem(node)
                walk(node.children)
            }
        }
        walk(nodes)
    }

    // MARK: - Actions

    private func node(atRow row: Int) -> WorkspaceFileNode? {
        guard row >= 0 else { return nil }
        return outlineView.item(atRow: row) as? WorkspaceFileNode
    }

    @objc private func rowClicked() {
        activate(row: outlineView.clickedRow)
    }

    /// A folder toggles; a file opens as a tab.
    private func activate(row: Int) {
        guard let node = node(atRow: row) else { return }
        if node.isDirectory {
            if outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            } else {
                outlineView.expandItem(node)
            }
        } else {
            open(node.path)
        }
    }

    private func open(_ path: String) {
        state.showRightPanel(.file(path))
        onOpenFile?()
    }

    private func openFirstMatch() {
        guard isSearching, let first = rows.first else { return }
        open(first.path)
    }

    /// Escape in the tree clears an active search; otherwise it is not handled.
    private func escapeFromTree() -> Bool {
        guard !searchField.text.isEmpty else { return false }
        searchField.text = ""
        render()
        return true
    }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = node(atRow: outlineView.clickedRow) else { return }
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = node
            menu.addItem(item)
        }
        if !node.isDirectory {
            add("Open", #selector(openFromMenu(_:)))
            menu.addItem(.separator())
        }
        add("Reveal in Finder", #selector(revealFromMenu(_:)))
        menu.addItem(.separator())
        add("Copy Path", #selector(copyPathFromMenu(_:)))
        add("Copy Relative Path", #selector(copyRelativePathFromMenu(_:)))
    }

    private func fileURL(_ sender: NSMenuItem) -> URL? {
        guard let node = sender.representedObject as? WorkspaceFileNode, let threadID = state.selectedThreadID else { return nil }
        return engine.workspaceFileURL(threadID, path: node.path)
    }

    @objc private func openFromMenu(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? WorkspaceFileNode else { return }
        open(node.path)
    }

    @objc private func revealFromMenu(_ sender: NSMenuItem) {
        guard let url = fileURL(sender) else { return }
        WorkspaceFileActions.reveal(url)
    }

    @objc private func copyPathFromMenu(_ sender: NSMenuItem) {
        guard let url = fileURL(sender) else { return }
        WorkspaceFileActions.copy(url.path)
    }

    @objc private func copyRelativePathFromMenu(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? WorkspaceFileNode else { return }
        WorkspaceFileActions.copy(node.path)
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? WorkspaceFileNode else { return rows.count }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? WorkspaceFileNode else { return rows[index] }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? WorkspaceFileNode)?.isDirectory == true && !isSearching
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? WorkspaceFileNode else { return nil }
        let cell = (outlineView.makeView(withIdentifier: FilesCell.identifier, owner: self) as? FilesCell) ?? FilesCell()
        if isSearching {
            cell.configureMatch(node, palette: PaletteCenter.shared.palette)
        } else {
            cell.configure(node, depth: outlineView.level(forItem: node), isExpanded: outlineView.isItemExpanded(node),
                           palette: PaletteCenter.shared.palette)
        }
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        FilesRowView()
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        expansionChanged(notification, expanded: true)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        expansionChanged(notification, expanded: false)
    }

    private func expansionChanged(_ notification: Notification, expanded isExpanded: Bool) {
        guard let node = notification.userInfo?["NSObject"] as? WorkspaceFileNode else { return }
        if !isRestoringExpansion, !isSearching, let threadID = state.selectedThreadID {
            if isExpanded {
                expanded[threadID, default: []].insert(node.path)
            } else {
                expanded[threadID]?.remove(node.path)
            }
        }
        let row = outlineView.row(forItem: node)
        if row >= 0 {
            outlineView.reloadData(forRowIndexes: [row], columnIndexes: [0])
        }
    }

    // MARK: - Palette

    private func applyPalette(_ palette: Palette) {
        messageLabel.textColor = palette.mutedForeground
        let visible = outlineView.rows(in: outlineView.visibleRect)
        if visible.length > 0 {
            outlineView.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<NSMaxRange(visible)), columnIndexes: [0])
        }
        outlineView.enumerateAvailableRowViews { rowView, _ in rowView.needsDisplay = true }
    }
}

/// Background of the Files surface.
final class FilesSurfaceRootView: PaletteView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.background.cgColor
    }
}

/// The explorer's outline: no native disclosure triangles (rows draw their own chevron), full-
/// width cells, hover tracking, Return activates the selected row, Escape asks the owner.
final class FilesOutlineView: NSOutlineView {
    var onActivate: ((Int) -> Void)?
    /// Returns true when the owner handled Escape.
    var onEscape: (() -> Bool)?

    private var hoveredRow = -1
    private var trackingArea: NSTrackingArea?

    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        let frame = super.frameOfCell(atColumn: column, row: row)
        let columnRect = rect(ofColumn: column)
        return NSRect(x: columnRect.minX, y: frame.minY, width: columnRect.width, height: frame.height)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: // Return, Enter
            if selectedRow >= 0 {
                onActivate?(selectedRow)
                return
            }
        case 53: // Escape
            if onEscape?() == true { return }
        default:
            break
        }
        super.keyDown(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        setHoveredRow(row(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHoveredRow(-1)
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setHoveredRow(visibleRect.contains(point) ? row(at: point) : -1)
    }

    override func reloadData() {
        hoveredRow = -1
        super.reloadData()
    }

    private func setHoveredRow(_ row: Int) {
        guard row != hoveredRow else { return }
        if hoveredRow >= 0, hoveredRow < numberOfRows {
            (rowView(atRow: hoveredRow, makeIfNecessary: false) as? FilesRowView)?.isHovered = false
        }
        hoveredRow = row
        if row >= 0 {
            (rowView(atRow: row, makeIfNecessary: false) as? FilesRowView)?.isHovered = true
        }
    }
}

/// Row background: rounded hover and selection fills, like the diff file tree's rows.
final class FilesRowView: NSTableRowView {
    var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawBackground(in dirtyRect: NSRect) {
        guard isHovered, !isSelected else { return }
        fill(PaletteCenter.shared.palette.accent.fading(0.6))
    }

    override func drawSelection(in dirtyRect: NSRect) {
        fill(PaletteCenter.shared.palette.accent)
    }

    private func fill(_ color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 0), xRadius: Radius.md, yRadius: Radius.md).fill()
    }
}

/// One explorer row: indentation, chevron (folders), glyph, name; search matches show the folder
/// part muted after the name.
final class FilesCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("FilesCell")

    private let chevron = NSImageView()
    private let icon = NSImageView()
    private let label = NSTextField.label(size: Typography.smallSize)
    private var leading: NSLayoutConstraint?
    private var chevronWidth: NSLayoutConstraint?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        chevron.imageScaling = .scaleNone
        icon.imageScaling = .scaleNone
        label.lineBreakMode = .byTruncatingTail
        for subview in [chevron, icon, label] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        let leading = chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        let chevronWidth = chevron.widthAnchor.constraint(equalToConstant: 12)
        self.leading = leading
        self.chevronWidth = chevronWidth
        NSLayoutConstraint.activate([
            leading,
            chevronWidth,
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// A tree row at `depth`.
    func configure(_ node: WorkspaceFileNode, depth: Int, isExpanded: Bool, palette: Palette) {
        leading?.constant = 8 + CGFloat(max(0, depth)) * 12
        chevronWidth?.constant = 12
        chevron.isHidden = !node.isDirectory
        chevron.image = NSImage.symbol(isExpanded ? Icon.chevronDown : Icon.chevronRight, size: 9, weight: .semibold)
        chevron.contentTintColor = palette.mutedForeground
        icon.image = NSImage.symbol(node.isDirectory ? "folder" : WorkspaceFileActions.symbol(forFileNamed: node.name), size: 11)
        icon.contentTintColor = palette.mutedForeground
        label.attributedStringValue = NSAttributedString(string: node.name, attributes: [
            .font: Typography.ui(Typography.smallSize), .foregroundColor: palette.foreground,
        ])
        toolTip = node.path
        setAccessibilityLabel(node.path)
    }

    /// A flat search match: name, then its folder muted.
    func configureMatch(_ node: WorkspaceFileNode, palette: Palette) {
        leading?.constant = 8
        chevronWidth?.constant = 0
        chevron.isHidden = true
        icon.image = NSImage.symbol(WorkspaceFileActions.symbol(forFileNamed: node.name), size: 11)
        icon.contentTintColor = palette.mutedForeground
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSMutableAttributedString(string: node.name, attributes: [
            .font: Typography.ui(Typography.smallSize), .foregroundColor: palette.foreground, .paragraphStyle: paragraph,
        ])
        let directory = node.directory
        if !directory.isEmpty {
            text.append(NSAttributedString(string: "  " + directory, attributes: [
                .font: Typography.ui(Typography.smallSize), .foregroundColor: palette.mutedForeground, .paragraphStyle: paragraph,
            ]))
        }
        label.attributedStringValue = text
        toolTip = node.path
        setAccessibilityLabel(node.path)
    }
}

/// The explorer's search input: magnifier, borderless 13 pt field "Search files", clear button.
/// Hover and focus fill it like the sidebar search; Return submits, Down moves to the list,
/// Escape clears (or, when empty, leaves the field).
final class FilesSearchField: InteractiveView, NSTextFieldDelegate {
    let field = SearchTextField()
    private let icon = NSImageView()
    private let clearButton = GhostIconButton(symbol: "xmark", size: 20, symbolSize: 9, toolTip: "Clear file search")

    var onChange: ((String) -> Void)?
    var onSubmit: (() -> Void)?
    var onMoveDown: (() -> Void)?
    var onEscape: (() -> Void)?

    private var isEditing: Bool {
        guard let editor = field.currentEditor() else { return false }
        return window?.firstResponder === editor
    }

    var text: String {
        get { field.stringValue }
        set {
            guard newValue != field.stringValue else { return }
            field.stringValue = newValue
            updateClear()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = Radius.md
        icon.image = NSImage.symbol(Icon.search, size: 12)
        icon.imageScaling = .scaleNone
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.font = Typography.ui(Typography.rowSize)
        field.delegate = self
        field.setAccessibilityLabel("Search files")
        setAccessibilityLabel("Search files")
        field.onFocusChange = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.applyPalette(self.palette)
                }
            }
        }
        clearButton.onClick = { [weak self] in
            guard let self else { return }
            text = ""
            onChange?("")
            field.requestFocus()
        }
        for view in [icon, field, clearButton] as [NSView] { addSubview(view) }
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        updateClear()
        applyPalette(palette)
    }

    func focus() {
        field.requestFocus()
    }

    private func updateClear() {
        clearButton.isHidden = field.stringValue.isEmpty
        needsLayout = true
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 8, y: (bounds.height - 16) / 2, width: 16, height: 16)
        let clearWidth: CGFloat = clearButton.isHidden ? 0 : 20
        clearButton.frame = NSRect(x: bounds.width - 4 - clearWidth, y: (bounds.height - 20) / 2, width: 20, height: 20)
        let fieldHeight = ceil(field.intrinsicContentSize.height)
        let fieldX = icon.frame.maxX + 6
        field.frame = NSRect(x: fieldX, y: (bounds.height - fieldHeight) / 2,
                             width: max(0, bounds.width - fieldX - 8 - clearWidth), height: fieldHeight)
    }

    override func mouseDown(with event: NSEvent) {
        focus()
    }

    override func applyPalette(_ palette: Palette) {
        let active = isHovered || isEditing
        layer?.backgroundColor = (active ? palette.accent.fading(0.6) : .clear).cgColor
        layer?.borderWidth = isEditing ? 1 : 0
        layer?.borderColor = palette.primary.withAlphaComponent(palette.primary.alphaComponent * 0.7).cgColor
        icon.contentTintColor = palette.mutedForeground
        field.textColor = palette.foreground
        field.placeholderAttributedString = NSAttributedString(string: "Search files", attributes: [
            .foregroundColor: palette.placeholder, .font: Typography.ui(Typography.rowSize),
        ])
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        updateClear()
        onChange?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            if field.stringValue.isEmpty {
                onEscape?()
            } else {
                text = ""
                onChange?("")
            }
            return true
        case #selector(NSResponder.moveDown(_:)):
            onMoveDown?()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            onSubmit?()
            return true
        default:
            return false
        }
    }
}
