import AppKit
import SopranoAgentsCore

/// The thread inbox: 52 pt header with the brand, the search row with
/// the project filter / add project / new thread buttons, the list (collapsible Pinned, Working,
/// Blocked, Failed, Done and Idle sections of cards, then the Settled shelf pushed to the bottom)
/// and the footer with Settings, the Statistics board toggle and the account button.
/// The list is an `NSTableView` of reused cells, so hundreds of threads stay cheap.
@MainActor
final class SidebarViewController: NSViewController, FocusRegionController, NSTableViewDataSource, NSTableViewDelegate {
    let engine: AgentEngine
    let state: WorkspaceState

    private let toggleButton = GhostIconButton(symbol: Icon.sidebarLeft, symbolSize: 14, toolTip: "Toggle sidebar (⌘E)")
    private let brandLabel = NSTextField.label("", size: Typography.bodySize, weight: .medium)
    let searchField = SidebarSearchField()
    private let searchRow = NSView()
    private let filterButton = SidebarIconButton(symbol: Icon.listFilter, label: "Filter threads by project")
    private let addProjectButton = SidebarIconButton(symbol: Icon.folderPlus, label: "Add project")
    private let newThreadButton = SidebarIconButton(symbol: Icon.squarePen, label: "New thread (⌘N)")
    private let scrollView = NSScrollView()
    let tableView = SidebarTableView()
    private let settingsButton = SidebarIconButton(symbol: Icon.settings, size: 32, symbolSize: 15, label: "Settings")
    private let statisticsButton = SidebarIconButton(symbol: Icon.statistics, size: 32, symbolSize: 15, label: "Statistics (⇧⌘U)")
    /// Accounts next to Statistics: toggles the usage card, tinted when a limit runs low.
    private let accountButton = AccountButton()
    private let usageCard = UsageCardPresenter()
    private lazy var filterPopup = ProjectFilterPopup(engine: engine, state: state)

    /// The rows on screen, top to bottom.
    private(set) var items: [SidebarItem] = []
    private var heightWithoutSpacer: CGFloat = 0
    private var expandedShelves = SidebarListModel.defaultExpandedShelves
    private var settledLimit = SidebarListModel.settledInitialCount
    /// Subagent disclosures the user toggled, per thread (`SidebarListOptions.subagentDisclosure`).
    private var subagentDisclosure: [String: Bool] = [:]
    private var renamingThreadID: String?
    private var reloadAfterRename = false
    private var showsJumpHints = false
    private var jumpHintWork: DispatchWorkItem?
    nonisolated(unsafe) private var flagsMonitor: Any?
    nonisolated(unsafe) private var timer: Timer?
    private var timerInterval: TimeInterval = 0
    private weak var observedWindow: NSWindow?

    init(engine: AgentEngine, state: WorkspaceState) {
        self.engine = engine
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        timer?.invalidate()
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
    }

    // MARK: FocusRegionController

    var focusRegion: FocusRegion { .sidebar }
    var focusRootView: NSView { view }

    func takeFocus() {
        view.window?.makeFirstResponder(tableView)
    }

    // MARK: View

    override func loadView() {
        let root = SidebarRootView(frame: NSRect(x: 0, y: 0, width: Metrics.sidebarWidth, height: 700))
        view = root

        brandLabel.setAccessibilityLabel("Soprano Agents")
        toggleButton.onClick = { [weak self] in self?.perform("view.toggleSidebar") }

        filterButton.onClick = { [weak self] in self?.toggleProjectFilter() }
        addProjectButton.onClick = { [weak self] in self?.perform("project.open") }
        newThreadButton.onClick = { [weak self] in
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            self?.perform(shift ? "chat.newLocal" : "chat.new")
        }
        settingsButton.onClick = { [weak self] in self?.perform("settings.open") }
        statisticsButton.onClick = { [weak self] in self?.perform("statistics.toggle") }
        accountButton.onClick = { [weak self] in self?.perform("usage.open") }
        usageCard.onManageAccounts = { [weak self] in self?.perform("accounts.manage") }

        searchField.text = state.searchText
        searchField.onChange = { [weak self] text in self?.state.setSearchText(text) }
        searchField.onMove = { [weak self] delta in self?.selectAdjacent(delta) }
        searchField.onSubmit = { [weak self] in
            guard let self, state.selectedThreadID == nil, let first = threadOrder.first else { return }
            open(first)
        }

        configureTable()

        for subview in [searchField, filterButton, addProjectButton, newThreadButton] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            searchRow.addSubview(subview)
        }
        for subview in [toggleButton, brandLabel, searchRow, scrollView, settingsButton, statisticsButton, accountButton] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        let inset = SidebarLayout.contentInset
        NSLayoutConstraint.activate([
            // Header: the floating sidebar toggle right of the traffic lights, then the brand
            // (`--workspace-titlebar-content-left` = 90 + 28 + 12).
            toggleButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Metrics.windowControlsInset + 1),
            toggleButton.centerYAnchor.constraint(equalTo: root.topAnchor, constant: Metrics.topbarHeight / 2),
            brandLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Metrics.windowControlsInset + Metrics.titlebarControlSize + 12),
            brandLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            brandLabel.centerYAnchor.constraint(equalTo: root.topAnchor, constant: Metrics.topbarHeight / 2),

            searchRow.topAnchor.constraint(equalTo: root.topAnchor, constant: Metrics.topbarHeight + inset),
            searchRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            searchRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
            searchRow.heightAnchor.constraint(equalToConstant: 32),

            searchField.leadingAnchor.constraint(equalTo: searchRow.leadingAnchor),
            searchField.topAnchor.constraint(equalTo: searchRow.topAnchor),
            searchField.bottomAnchor.constraint(equalTo: searchRow.bottomAnchor),
            searchField.trailingAnchor.constraint(equalTo: filterButton.leadingAnchor, constant: -4),
            filterButton.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),
            filterButton.trailingAnchor.constraint(equalTo: addProjectButton.leadingAnchor),
            addProjectButton.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),
            addProjectButton.trailingAnchor.constraint(equalTo: newThreadButton.leadingAnchor),
            newThreadButton.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),
            newThreadButton.trailingAnchor.constraint(equalTo: searchRow.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: searchRow.bottomAnchor, constant: inset),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: settingsButton.topAnchor, constant: -4),

            settingsButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            settingsButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -4),
            statisticsButton.leadingAnchor.constraint(equalTo: settingsButton.trailingAnchor, constant: 2),
            statisticsButton.centerYAnchor.constraint(equalTo: settingsButton.centerYAnchor),
            accountButton.leadingAnchor.constraint(equalTo: statisticsButton.trailingAnchor, constant: 2),
            accountButton.centerYAnchor.constraint(equalTo: settingsButton.centerYAnchor),
        ])

        engine.addObserver(self) { [weak self] event in
            switch event {
            case .projectsChanged, .threadListChanged, .subagentListChanged: self?.reload()
            case let .threadChanged(threadID): self?.refreshRow(of: threadID)
            case .itemChanged, .subagentChanged, .providersChanged, .commandsChanged: break
            }
        }
        state.addObserver(self) { [weak self] change in
            guard let self else { return }
            switch change {
            case .selection:
                // A subagent's timeline does not show its thread's answer: the thread stays unread.
                if case let .thread(id) = state.selection { engine.markVisited(id) }
                reload()
            case .filter:
                searchField.text = state.searchText
                reload()
            case .panels:
                statisticsButton.isOn = state.isStatisticsVisible
            case .composerRestore:
                break
            }
        }
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateSpacerHeight() }
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.handleFlags(event) }
            return event
        }
        root.onPalette = { [weak self] palette in self?.applyPalette(palette) }
        applyPalette(PaletteCenter.shared.palette)
        reload()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if let window = view.window, observedWindow !== window {
            observedWindow = window
            NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
        }
        settingsButton.isEnabled = CommandRegistry.shared.command("settings.open") != nil
    }

    private func configureTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("thread"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.selectionHighlightStyle = .none
        tableView.rowSizeStyle = .custom
        tableView.focusRingType = .none
        tableView.gridStyleMask = []
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityLabel("Threads")
        tableView.onMove = { [weak self] delta in self?.selectAdjacent(delta) }
        tableView.onRename = { [weak self] in
            guard let self, let id = state.selectedThreadID else { return }
            beginRename(id)
        }

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)
        scrollView.postsFrameChangedNotifications = true
    }

    private func applyPalette(_ palette: Palette) {
        let brand = NSMutableAttributedString(string: "Soprano", attributes: [
            .foregroundColor: palette.sidebarForeground,
            .font: Typography.ui(Typography.bodySize, weight: .medium),
            .kern: -0.35,
        ])
        brand.append(NSAttributedString(string: " Agents", attributes: [
            .foregroundColor: palette.mutedForeground,
            .font: Typography.ui(Typography.bodySize, weight: .medium),
            .kern: -0.35,
        ]))
        brandLabel.attributedStringValue = brand
    }

    // MARK: Model

    private var listOptions: SidebarListOptions {
        SidebarListOptions(
            selectedThreadID: state.selectedThreadID,
            selectedSubagentID: state.selectedSubagentID,
            projectFilter: state.projectFilter,
            searchText: state.searchText,
            expandedShelves: expandedShelves,
            settledLimit: settledLimit,
            subagentDisclosure: subagentDisclosure
        )
    }

    /// Thread ids in list order.
    var threadOrder: [String] { SidebarListModel.threadOrder(items) }

    /// Rebuilds the rows. Same row identities → only the changed rows reload.
    func reload() {
        guard isViewLoaded else { return }
        if renamingThreadID != nil {
            reloadAfterRename = true
            return
        }
        markSelectedVisitedIfSeen()
        let next = SidebarListModel.build(threads: engine.threads, projects: engine.projects, options: listOptions)
        updateHeaderButtons()
        if next.map(\.identity) == items.map(\.identity) {
            let changed = IndexSet(next.indices.filter { next[$0] != items[$0] })
            items = next
            recomputeHeights()
            guard !changed.isEmpty else { return }
            tableView.reloadData(forRowIndexes: changed, columnIndexes: [0])
            tableView.noteHeightOfRows(withIndexesChanged: changed.union(spacerIndexes))
        } else {
            items = next
            recomputeHeights()
            tableView.reloadData()
        }
        updateTimer()
    }

    /// One thread's turns changed: re-derive just its row.
    private func refreshRow(of threadID: String) {
        guard isViewLoaded, renamingThreadID == nil,
              let index = items.firstIndex(where: { $0.thread?.threadID == threadID }),
              let thread = engine.thread(threadID) else { return }
        guard state.searchText.isEmpty else {
            reload()
            return
        }
        let projects = Dictionary(engine.projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let row = SidebarListModel.row(for: thread, projects: projects, options: listOptions)
        let item: SidebarItem = if case .slim = items[index] { .slim(row) } else { .card(row) }
        guard item != items[index] else { return }
        // Status or section changes reshuffle the list; anything else is this row only.
        if items[index].thread?.status != row.status || items[index].thread?.section != row.section {
            reload()
            return
        }
        items[index] = item
        recomputeHeights()
        tableView.reloadData(forRowIndexes: [index], columnIndexes: [0])
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: index).union(spacerIndexes))
    }

    /// The open thread finished while the user is looking at it: no unread pill.
    private func markSelectedVisitedIfSeen() {
        guard view.window?.isKeyWindow == true, case let .thread(id) = state.selection, let thread = engine.thread(id) else { return }
        let status = ThreadStatus.of(thread)
        if status == .done || status == .failed { engine.markVisited(id) }
    }

    private var spacerIndexes: IndexSet {
        IndexSet(items.indices.filter { items[$0] == .spacer })
    }

    private func recomputeHeights() {
        heightWithoutSpacer = items.reduce(0) { $0 + SidebarLayout.height(of: $1) }
    }

    private func updateSpacerHeight() {
        let spacers = spacerIndexes
        guard !spacers.isEmpty else { return }
        tableView.noteHeightOfRows(withIndexesChanged: spacers)
    }

    private func updateHeaderButtons() {
        let hasProjects = !engine.projects.isEmpty
        filterButton.isHidden = !hasProjects
        addProjectButton.isHidden = !hasProjects
        newThreadButton.isEnabled = hasProjects
        let scoped = engine.projects.filter { state.projectFilter.contains($0.id) }
        filterButton.isOn = !scoped.isEmpty
        let label = scoped.isEmpty ? "Filter threads by project" : "Filter threads by project: \(scoped.map(\.title).joined(separator: ", "))"
        filterButton.toolTip = label
        filterButton.setAccessibilityLabel(label)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard items.indices.contains(row) else { return 1 }
        if items[row] == .spacer {
            let visible = scrollView.contentView.bounds.height - scrollView.contentInsets.bottom
            return max(1, visible - heightWithoutSpacer)
        }
        return SidebarLayout.height(of: items[row])
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("sidebar.row")
        if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? ThreadSidebarRowView { return reused }
        let rowView = ThreadSidebarRowView()
        rowView.identifier = identifier
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let now = engine.environment.now()
        let order = threadOrder
        switch items[row] {
        case let .card(model):
            let cell = reuse("card") { SidebarCardCell(frame: .zero) }
            cell.actions = rowActions
            cell.configure(model, now: now)
            cell.jumpHint = jumpHint(for: model.threadID, order: order)
            return cell
        case let .slim(model):
            let cell = reuse("slim") { SidebarSlimCell(frame: .zero) }
            cell.actions = rowActions
            cell.configure(model, now: now)
            cell.jumpHint = jumpHint(for: model.threadID, order: order)
            return cell
        case let .subagent(model):
            let cell = reuse("subagent") { SidebarSubagentCell(frame: .zero) }
            cell.actions = rowActions
            cell.configure(model, now: now)
            return cell
        case let .shelf(section, count, expanded):
            let cell = reuse("shelf") { SidebarShelfCell(frame: .zero) }
            cell.configure(section: section, count: count, expanded: expanded)
            cell.onToggle = { [weak self] section in self?.toggleShelf(section) }
            return cell
        case let .showMore(count):
            let cell = reuse("more") { SidebarShowMoreCell(frame: .zero) }
            cell.configure(count: count)
            cell.onClick = { [weak self] in self?.showMoreSettled() }
            return cell
        case .spacer:
            let cell = reuse("spacer") { NSView(frame: .zero) }
            return cell
        case let .empty(emptyState):
            let cell = reuse("empty") { SidebarEmptyCell(frame: .zero) }
            cell.configure(emptyState)
            cell.addProjectButton.onClick = { [weak self] in self?.perform("project.open") }
            return cell
        }
    }

    private func reuse<Cell: NSView>(_ identifier: String, make: () -> Cell) -> Cell {
        let id = NSUserInterfaceItemIdentifier("sidebar.\(identifier)")
        if let cell = tableView.makeView(withIdentifier: id, owner: nil) as? Cell { return cell }
        let cell = make()
        cell.identifier = id
        return cell
    }

    private lazy var rowActions = SidebarRowActions(
        select: { [weak self] id in self?.open(id) },
        rename: { [weak self] id in self?.beginRename(id) },
        setSettled: { [weak self] id, settled in self?.engine.setSettled(id, settled) },
        menu: { [weak self] id in self?.menu(for: id) },
        commitRename: { [weak self] id, title in self?.finishRename(id, title: title) },
        cancelRename: { [weak self] in self?.finishRename(nil, title: nil) },
        selectSubagent: { [weak self] threadID, subagentID in self?.openSubagent(threadID, subagentID) },
        subagentMenu: { [weak self] threadID, subagentID in
            guard let self else { return nil }
            return SubagentActions.menu(threadID: threadID, subagentID: subagentID, engine: engine, state: state, window: view.window)
        },
        toggleSubagents: { [weak self] threadID in self?.toggleSubagents(threadID) }
    )

    // MARK: Actions

    func open(_ threadID: String) {
        ThreadActions.open(threadID, engine: engine, state: state)
        if view.window?.firstResponder !== searchField.field.currentEditor() {
            view.window?.makeFirstResponder(tableView)
        }
        scrollToThread(threadID)
    }

    func openSubagent(_ threadID: String, _ subagentID: String) {
        SubagentActions.open(threadID: threadID, subagentID: subagentID, state: state)
        if view.window?.firstResponder !== searchField.field.currentEditor() {
            view.window?.makeFirstResponder(tableView)
        }
    }

    /// Opens or closes a card's subagent rows (the selected subagent stays listed).
    func toggleSubagents(_ threadID: String) {
        guard let thread = engine.thread(threadID) else { return }
        subagentDisclosure[threadID] = !SidebarListModel.subagentsExpanded(thread, options: listOptions)
        reload()
    }

    /// Moves the selection `delta` rows in list order (wrapping), like ⇧⌘[ / ⇧⌘].
    func selectAdjacent(_ delta: Int) {
        let order = threadOrder
        guard !order.isEmpty else { return }
        let next: Int
        if let current = state.selectedThreadID, let index = order.firstIndex(of: current) {
            next = (index + delta % order.count + order.count) % order.count
        } else {
            next = delta >= 0 ? 0 : order.count - 1
        }
        ThreadActions.open(order[next], engine: engine, state: state)
        scrollToThread(order[next])
    }

    /// ⌃1…⌃9: the Nth thread in list order.
    func jump(to position: Int) {
        let order = threadOrder
        guard position >= 1, position <= order.count else { return }
        ThreadActions.open(order[position - 1], engine: engine, state: state)
        scrollToThread(order[position - 1])
    }

    private func scrollToThread(_ threadID: String) {
        guard let index = items.firstIndex(where: { $0.thread?.threadID == threadID }) else { return }
        tableView.scrollRowToVisible(index)
    }

    func focusSearch() {
        searchField.focus()
    }

    /// Open Project… → Choose Folder…: any folder from a Finder panel becomes a project with a
    /// new thread draft.
    func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add project"
        panel.message = "Choose a project folder"
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let project = engine.addProject(path: url.path)
            ThreadActions.newDraft(projectID: project.id, state: state)
        }
        if let window = view.window {
            panel.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { finish(response) }
            }
        } else {
            finish(panel.runModal())
        }
    }

    func toggleProjectFilter() {
        if filterPopup.isShown {
            filterPopup.dismiss()
        } else {
            filterPopup.show(below: searchRow)
        }
    }

    /// `usage.open`: the usage card above the account button.
    func toggleUsageCard() {
        view.layoutSubtreeIfNeeded()
        usageCard.toggle(anchoredTo: accountButton)
    }

    var isUsageCardShown: Bool { usageCard.isShown }

    private func toggleShelf(_ section: InboxSection) {
        if expandedShelves.contains(section) {
            expandedShelves.remove(section)
            if section == .settled { settledLimit = SidebarListModel.settledInitialCount }
        } else {
            expandedShelves.insert(section)
        }
        reload()
    }

    private func showMoreSettled() {
        settledLimit += SidebarListModel.settledPageCount
        reload()
    }

    private func menu(for threadID: String) -> NSMenu? {
        ThreadActions.menu(for: threadID, engine: engine, state: state, window: view.window) { [weak self] in
            self?.beginRename(threadID)
        }
    }

    /// Inline rename of a row (double-click, F2, "Rename thread").
    func beginRename(_ threadID: String) {
        guard let index = items.firstIndex(where: { $0.thread?.threadID == threadID }) else { return }
        tableView.scrollRowToVisible(index)
        guard let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: true) as? SidebarThreadCell else { return }
        renamingThreadID = threadID
        cell.beginRename()
    }

    private func finishRename(_ threadID: String?, title: String?) {
        renamingThreadID = nil
        if let threadID, let title { engine.rename(threadID, title: title) }
        if reloadAfterRename {
            reloadAfterRename = false
            reload()
        }
        view.window?.makeFirstResponder(tableView)
    }

    private func perform(_ id: String) {
        (view.window?.windowController as? AgentsWindowController)?.perform(id)
    }

    // MARK: Live times and jump hints

    private func updateTimer() {
        let working = items.contains { item in
            if case let .subagent(row) = item { return row.status == .running }
            return item.thread?.status.isWorking == true
        }
        let interval: TimeInterval = working ? 1 : 30
        guard interval != timerInterval || timer == nil else { return }
        timer?.invalidate()
        timerInterval = interval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        let now = engine.environment.now()
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        for row in visible.location..<(visible.location + visible.length) {
            let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
            (cell as? SidebarThreadCell)?.refreshTime(now)
            (cell as? SidebarSubagentCell)?.refreshTime(now)
        }
    }

    private func jumpHint(for threadID: String, order: [String]) -> String? {
        guard showsJumpHints, let index = order.firstIndex(of: threadID), index < 9 else { return nil }
        return "⌃\(index + 1)"
    }

    /// Holding ⌃ alone for 200 ms shows ⌃1…⌃9 on the first nine rows.
    private func handleFlags(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .function, .numericPad])
        jumpHintWork?.cancel()
        jumpHintWork = nil
        guard flags == .control, event.window === view.window, !view.isHiddenOrHasHiddenAncestor else {
            setJumpHints(false)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.setJumpHints(true) }
        }
        jumpHintWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    func setJumpHints(_ shown: Bool) {
        guard shown != showsJumpHints else { return }
        showsJumpHints = shown
        let order = threadOrder
        tableView.enumerateAvailableRowViews { _, row in
            guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarThreadCell,
                  let id = cell.row?.threadID else { return }
            cell.jumpHint = jumpHint(for: id, order: order)
        }
    }
}

/// `bg-sidebar`.
final class SidebarRootView: PaletteView {
    var onPalette: ((Palette) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.sidebar.cgColor
        onPalette?(palette)
    }
}

/// Row container without selection drawing (rows draw their own surfaces).
final class ThreadSidebarRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}
    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}

/// The list: ↑/↓ move the selection, F2 renames (KeyChord has no function keys, so the list
/// handles F2 itself rather than through a binding).
final class SidebarTableView: NSTableView {
    var onMove: ((Int) -> Void)?
    var onRename: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch (event.specialKey, flags.isEmpty) {
        case (.upArrow?, true): onMove?(-1)
        case (.downArrow?, true): onMove?(1)
        case (.f2?, true): onRename?()
        default: super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // Rows build their own menus; the empty area has none.
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0, let cell = view(atColumn: 0, row: row, makeIfNecessary: false) else { return nil }
        return cell.menu(for: event)
    }
}
