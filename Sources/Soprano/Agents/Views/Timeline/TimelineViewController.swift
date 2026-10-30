import AppKit
import SopranoAgentsCore

/// Timeline slice: the selected thread's messages, work groups and cards in the centered chat
/// lane (T3 Code's `MessagesTimeline`). Owns what is expanded, find in thread, and the
/// "Working for" clock; rows ask it for every action through `TimelineRowDelegate`.
@MainActor
final class TimelineViewController: NSViewController, FocusRegionController, TimelineRowDelegate {
    let engine: AgentEngine
    let state: WorkspaceState

    /// Space at the bottom the floating composer covers; the timeline pads its content by it.
    var bottomInset: CGFloat = 0 {
        didSet {
            guard isViewLoaded else { return }
            list.bottomInset = bottomInset
            view.needsLayout = true
        }
    }

    private let scrollView = NSScrollView()
    private let list = TimelineListView()
    private let findBar = ThreadFindBar(frame: .zero)
    private let jumpPill = JumpToLatestPill(frame: .zero)

    private(set) var expansion = TimelineExpansion()
    private var shownThreadID: String?
    private var reloadScheduled = false
    private var clock: Timer?

    // Find in thread
    private(set) var isFindOpen = false
    private var findQuery = ""
    private var findMatches: [TimelineFindMatch] = []
    private var findIndex = 0

    init(engine: AgentEngine, state: WorkspaceState) {
        self.engine = engine
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = TimelineRootView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view = root

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .none
        scrollView.frame = root.bounds
        scrollView.autoresizingMask = [.width, .height]
        list.frame = NSRect(x: 0, y: 0, width: root.bounds.width, height: root.bounds.height)
        list.autoresizingMask = [.width]
        list.rowDelegate = self
        list.bottomInset = bottomInset
        scrollView.documentView = list
        root.addSubview(scrollView)

        jumpPill.isHidden = true
        jumpPill.onClick = { [weak self] in self?.jumpToLatest() }
        root.addSubview(jumpPill)

        findBar.isHidden = true
        findBar.onQueryChange = { [weak self] query in self?.setFindQuery(query) }
        findBar.onNext = { [weak self] in self?.moveFind(by: 1) }
        findBar.onPrevious = { [weak self] in self?.moveFind(by: -1) }
        findBar.onClose = { [weak self] in self?.closeFind() }
        root.addSubview(findBar)

        root.onLayout = { [weak self] in self?.layoutOverlays() }

        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.list.didScroll() }
        }
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.list.clipDidResize() }
        }
        list.onPinnedChange = { [weak self] pinned in self?.setJumpPillVisible(!pinned) }

        engine.addObserver(self) { [weak self] event in
            guard let self else { return }
            switch event {
            case let .threadChanged(threadID), let .itemChanged(threadID, _, _):
                if threadID == state.selectedThreadID { scheduleReload() }
            case .threadListChanged:
                scheduleReload()
            case .projectsChanged, .providersChanged:
                break
            }
        }
        state.addObserver(self) { [weak self] change in
            guard let self else { return }
            switch change {
            case .selection:
                if isFindOpen { closeFind(focusTimeline: false) }
                reload(scrollToEnd: true)
            case .panels:
                layoutOverlays()
            case .filter, .composerRestore:
                break
            }
        }
        PaletteCenter.shared.addObserver(self) { [weak self] _ in
            // Rendered Markdown carries its colors: rebuild what is on screen.
            self?.list.reconfigureVisibleRows()
        }
        reload(scrollToEnd: true)
    }

    // MARK: Rows

    /// Rows of the selected thread (none for a draft: the composer draws the hero).
    var currentRows: [TimelineRow] { list.rows }

    private var selectedThread: AgentThread? {
        state.isDraft ? nil : engine.thread(state.selectedThreadID)
    }

    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            reloadScheduled = false
            reload()
        }
    }

    func reload(scrollToEnd: Bool = false) {
        guard isViewLoaded else { return }
        let thread = selectedThread
        let rows = TimelineBuilder.rows(for: thread, expansion: expansion)
        let threadChanged = thread?.id != shownThreadID
        shownThreadID = thread?.id
        list.setRows(rows, scrollToEnd: scrollToEnd || threadChanged)
        if isFindOpen { refreshFind(keepIndex: true, reveal: false) }
        updateClock(running: thread?.isRunning ?? false)
    }

    private func updateClock(running: Bool) {
        if running, clock == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            clock = timer
        } else if !running {
            clock?.invalidate()
            clock = nil
        }
    }

    private func tick() {
        for case let row as WorkingRowView in list.visibleRowViews { row.tick() }
    }

    private func layoutOverlays() {
        let bounds = view.bounds
        let pillSize = jumpPill.pillSize
        jumpPill.frame = NSRect(x: floor((bounds.width - pillSize.width) / 2), y: bounds.height - bottomInset - pillSize.height + 6, width: pillSize.width, height: pillSize.height)
        // Top right like T3 Code; left of the Thread details card when it shows.
        let detailsOffset: CGFloat = state.isThreadDetailsVisible ? Metrics.threadDetailsWidth + 12 : 0
        let width = min(ThreadFindBar.width, bounds.width - 24)
        findBar.frame = NSRect(x: bounds.width - 12 - detailsOffset - width, y: 12, width: width, height: ThreadFindBar.height)
    }

    private func setJumpPillVisible(_ visible: Bool) {
        let show = visible && !list.rows.isEmpty
        guard jumpPill.isHidden == show else { return }
        jumpPill.isHidden = !show
        layoutOverlays()
    }

    func jumpToLatest() {
        list.jumpToEnd()
        setJumpPillVisible(false)
    }

    // MARK: Expansion

    /// Opens every fold and work group of the selected thread.
    func expandAll() {
        guard let thread = selectedThread else { return }
        expansion.turns.formUnion(thread.turns.map(\.id))
        for _ in 0..<2 {
            for row in TimelineBuilder.rows(for: thread, expansion: expansion) {
                switch row.content {
                case let .workGroup(model): expansion.groups.insert(model.groupID)
                case let .liveWork(model): expansion.groups.insert(model.groupID)
                default: break
                }
            }
        }
        reload()
    }

    func collapseAll() {
        guard let thread = selectedThread else { return }
        let turnIDs = Set(thread.turns.map(\.id))
        expansion.turns.subtract(turnIDs)
        let rows = TimelineBuilder.rows(for: thread, expansion: TimelineExpansion(turns: turnIDs, groups: expansion.groups))
        for row in rows {
            switch row.content {
            case let .workGroup(model): expansion.groups.remove(model.groupID)
            case let .liveWork(model): expansion.groups.remove(model.groupID)
            case let .workEntry(model): expansion.entries.remove(model.entry.id)
            default: break
            }
        }
        reload()
    }

    private func toggle(_ id: String, in keyPath: WritableKeyPath<TimelineExpansion, Set<String>>) {
        if expansion[keyPath: keyPath].contains(id) {
            expansion[keyPath: keyPath].remove(id)
        } else {
            expansion[keyPath: keyPath].insert(id)
        }
        reload()
    }

    // MARK: TimelineRowDelegate

    func timelineToggleFold(turnID: String) { toggle(turnID, in: \.turns) }
    func timelineToggleGroup(_ groupID: String) { toggle(groupID, in: \.groups) }
    func timelineToggleEntry(_ itemID: String) { toggle(itemID, in: \.entries) }
    func timelineToggleMessage(_ messageID: String) { toggle(messageID, in: \.messages) }
    func timelineTogglePlan(_ itemID: String) { toggle(itemID, in: \.plans) }

    func timelineSetClosedFolders(turnID: String, paths: Set<String>) {
        expansion.closedFolders[turnID] = paths
        reload()
    }

    func timelineEditFromHere(turnID: String) {
        guard let threadID = selectedThread?.id else { return }
        let window = view.window
        Task { @MainActor [engine, state] in
            let choice = await Dialogs.choose(
                title: "Edit from here?",
                message: "Rewind chat to before this message. Your prompt and attachments return to the composer. “Revert files too” also undoes your own edits.",
                buttons: [
                    DialogButton("Cancel", style: .outline),
                    DialogButton("Revert files too", style: .destructiveOutline),
                    DialogButton("Revert and keep changes", style: .primary),
                ],
                in: window
            )
            guard let choice, choice > 0 else { return }
            do {
                let message = try await engine.revert(threadID, toBeforeTurn: turnID, restoreFiles: choice == 1)
                state.restoreComposer(with: message)
            } catch {
                await Dialogs.alert(title: "Couldn’t edit from here", message: error.localizedDescription, in: window)
            }
        }
    }

    func timelineRespond(approvalID: String, decision: ApprovalDecision) {
        guard let threadID = selectedThread?.id else { return }
        Task { @MainActor [engine] in
            await engine.respond(threadID, approvalID: approvalID, decision: decision)
        }
    }

    func timelineOpenDiff(turnOrdinal: Int, path: String?) {
        state.showDiff(.turn(turnOrdinal), focus: path)
    }

    func timelineSendQueuedNow(messageID: String) {
        guard let threadID = selectedThread?.id else { return }
        Task { @MainActor [engine] in
            await engine.sendQueuedNow(threadID, messageID: messageID)
        }
    }

    func timelineRemoveQueued(messageID: String) {
        guard let threadID = selectedThread?.id else { return }
        engine.cancelQueued(threadID, messageID: messageID)
    }

    func timelineCopy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Find in thread

    func showFind() {
        guard selectedThread != nil else { return }
        isFindOpen = true
        findBar.isHidden = false
        list.revealTopInset = 12 + ThreadFindBar.height
        layoutOverlays()
        view.window?.makeFirstResponder(findBar.field)
        findBar.field.currentEditor()?.selectAll(nil)
        refreshFind(keepIndex: true, reveal: true)
    }

    func closeFind(focusTimeline: Bool = true) {
        isFindOpen = false
        findBar.isHidden = true
        list.revealTopInset = 0
        findQuery = ""
        findBar.field.stringValue = ""
        findMatches = []
        findIndex = 0
        list.findHighlights = [:]
        if focusTimeline { view.window?.makeFirstResponder(list) }
    }

    private func setFindQuery(_ query: String) {
        findQuery = query
        findIndex = 0
        refreshFind(keepIndex: false, reveal: true)
    }

    private func moveFind(by delta: Int) {
        guard !findMatches.isEmpty else { return }
        findIndex = (findIndex + delta + findMatches.count) % findMatches.count
        applyFindHighlights()
        revealActiveMatch()
    }

    private func refreshFind(keepIndex: Bool, reveal: Bool) {
        let units = list.rows.map { (id: $0.id, units: TimelineFind.units(of: $0)) }
        findMatches = TimelineFind.matches(of: findQuery, in: units)
        if !keepIndex { findIndex = 0 }
        findIndex = findMatches.isEmpty ? 0 : min(findIndex, findMatches.count - 1)
        applyFindHighlights()
        if reveal { revealActiveMatch() }
    }

    private func applyFindHighlights() {
        var highlights: [String: [FindHighlight]] = [:]
        for (index, match) in findMatches.enumerated() {
            highlights[match.rowID, default: []].append(FindHighlight(unit: match.unit, range: match.range, active: index == findIndex))
        }
        list.findHighlights = highlights
        let hasQuery = !findQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        findBar.setCount(
            hasQuery ? TimelineFind.countLabel(index: findIndex, total: findMatches.count) : "",
            noResults: hasQuery && findMatches.isEmpty,
            canNavigate: !findMatches.isEmpty
        )
    }

    /// Opens a folded message or plan that holds the current match, then scrolls to it.
    private func revealActiveMatch() {
        guard findIndex < findMatches.count else { return }
        let match = findMatches[findIndex]
        if let row = list.rows.first(where: { $0.id == match.rowID }) {
            switch row.content {
            case let .user(model) where !model.expanded:
                expansion.messages.insert(model.message.id)
                reload()
            case let .plan(model) where !model.expanded && model.canCollapse:
                expansion.plans.insert(model.itemID)
                reload()
            default:
                break
            }
        }
        list.reveal(rowID: match.rowID)
        if let rowView = list.view(forRow: match.rowID), let rect = rowView.findRect(unit: match.unit, range: match.range) {
            list.reveal(rowID: match.rowID, rect: rect)
        }
    }

    // MARK: FocusRegionController

    var focusRegion: FocusRegion { .timeline }
    var focusRootView: NSView { view }

    func takeFocus() {
        view.window?.makeFirstResponder(list)
    }
}

/// The timeline's root: chat background, lays out the floating find bar and jump pill.
final class TimelineRootView: PaletteView {
    var onLayout: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        applyPalette(palette)
    }

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.background.cgColor
    }
}
