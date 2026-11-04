import AppKit
import SopranoAgentsCore

/// Timeline slice: the selected thread's messages, work groups and cards in the centered chat
/// lane. Owns what is expanded, find in thread, and the
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
            case let .subagentChanged(threadID, subagentID):
                if threadID == state.selectedThreadID, subagentID == state.selectedSubagentID { scheduleReload() }
            case .threadListChanged:
                scheduleReload()
            case .projectsChanged, .providersChanged, .commandsChanged, .subagentListChanged:
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
        list.maxLaneWidth = SettingsCenter.shared.settings.chatWidth.maxWidth
        expansion.detailed = SettingsCenter.shared.settings.workLog == .detailed
        SettingsCenter.shared.addObserver(self) { [weak self] in
            guard let self else { return }
            list.maxLaneWidth = SettingsCenter.shared.settings.chatWidth.maxWidth
            setDetailed(SettingsCenter.shared.settings.workLog == .detailed)
        }
        reload(scrollToEnd: true)
    }

    // MARK: Rows

    /// Rows of the selected thread or subagent (none for a draft: the composer draws the hero).
    var currentRows: [TimelineRow] { list.rows }

    /// The selected thread; a selected subagent as a thread of its runs
    /// (`Subagent.timelineThread`), whose id no engine thread has, so thread actions do nothing.
    private var selectedThread: AgentThread? {
        if state.isDraft { return nil }
        guard let thread = engine.thread(state.selectedThreadID) else { return nil }
        guard let subagentID = state.selectedSubagentID else { return thread }
        return thread.subagent(subagentID)?.timelineThread(in: thread)
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
        // Find searches the shown rows: while it has a query, every turn's checks are open so their
        // notes and replies stay findable.
        var shown = expansion
        if isSearching, let thread { shown.checks.formUnion(thread.turns.map(\.id)) }
        let rows = TimelineBuilder.rows(for: thread, expansion: shown, editable: state.selectedSubagentID == nil)
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
        // Top right; left of the Thread details card when it shows.
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

    /// Switches the work log's defaults; what the user opened or closed was relative to the old
    /// ones, so it starts over.
    private func setDetailed(_ detailed: Bool) {
        guard expansion.detailed != detailed else { return }
        expansion.detailed = detailed
        expansion.turns.removeAll()
        expansion.groups.removeAll()
        expansion.diffs.removeAll()
        reload()
    }

    /// Opens every fold, checks row, work group and file diff of the selected thread.
    func expandAll() {
        guard let thread = selectedThread else { return }
        for turn in thread.turns { expansion.set(turn.id, open: true, in: \.turns) }
        expansion.checks.formUnion(thread.turns.map(\.id))
        for _ in 0..<2 {
            for row in TimelineBuilder.rows(for: thread, expansion: expansion) {
                switch row.content {
                case let .workGroup(model): expansion.set(model.groupID, open: true, in: \.groups)
                case let .liveWork(model): expansion.set(model.groupID, open: true, in: \.groups)
                case let .fileDiff(model): expansion.set(model.id, open: true, in: \.diffs)
                default: break
                }
            }
        }
        reload()
    }

    func collapseAll() {
        guard let thread = selectedThread else { return }
        let turnIDs = thread.turns.map(\.id)
        // Every fold and checks row open, so the work inside them is listed too.
        var everything = expansion
        for id in turnIDs { everything.set(id, open: true, in: \.turns) }
        everything.checks.formUnion(turnIDs)
        let rows = TimelineBuilder.rows(for: thread, expansion: everything)
        for id in turnIDs { expansion.set(id, open: false, in: \.turns) }
        expansion.checks.subtract(turnIDs)
        for row in rows {
            switch row.content {
            case let .workGroup(model): expansion.set(model.groupID, open: false, in: \.groups)
            case let .liveWork(model): expansion.set(model.groupID, open: false, in: \.groups)
            case let .workEntry(model): expansion.entries.remove(model.entry.id)
            case let .fileDiff(model): expansion.set(model.id, open: false, in: \.diffs)
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
    func timelineToggleChecks(turnID: String) {
        // While Find has a query every checks row is open (see `reload`).
        guard !isSearching else { return }
        let opening = !expansion.checks.contains(turnID)
        toggle(turnID, in: \.checks)
        // A pinned timeline follows its end; keep the opened row's header in view instead.
        if opening { list.reveal(rowID: "checks:\(turnID)", rect: NSRect(x: 0, y: 0, width: 1, height: 24)) }
    }
    func timelineToggleGroup(_ groupID: String) { toggle(groupID, in: \.groups) }
    func timelineToggleEntry(_ itemID: String) { toggle(itemID, in: \.entries) }
    func timelineToggleDiff(_ diffID: String) { toggle(diffID, in: \.diffs) }
    func timelineToggleMessage(_ messageID: String) { toggle(messageID, in: \.messages) }

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
            } catch let failure as EngineError {
                if case let .filesNotRestored(message, _) = failure {
                    // The conversation was rewound: the prompt still goes back to the composer.
                    state.restoreComposer(with: message)
                    await Dialogs.alert(title: "Files not restored", message: failure.localizedDescription, in: window)
                } else {
                    await Dialogs.alert(title: "Couldn’t edit from here", message: failure.localizedDescription, in: window)
                }
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

    func timelineOpenDiff(turnOrdinal: Int?, path: String?) {
        state.showDiff(turnOrdinal.map { .turn($0) } ?? .uncommitted, focus: path)
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
        let wasSearching = isSearching
        isFindOpen = false
        findBar.isHidden = true
        list.revealTopInset = 0
        findQuery = ""
        findBar.field.stringValue = ""
        findMatches = []
        findIndex = 0
        list.findHighlights = [:]
        if wasSearching { reload() }
        if focusTimeline { view.window?.makeFirstResponder(list) }
    }

    /// Find is open with a query: checks render open (see `reload`).
    private var isSearching: Bool {
        isFindOpen && !findQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func setFindQuery(_ query: String) {
        let wasSearching = isSearching
        findQuery = query
        findIndex = 0
        if isSearching != wasSearching { reload() }
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

    /// Opens a folded message that holds the current match, then scrolls to it.
    private func revealActiveMatch() {
        guard findIndex < findMatches.count else { return }
        let match = findMatches[findIndex]
        if let row = list.rows.first(where: { $0.id == match.rowID }) {
            if case let .user(model) = row.content, !model.expanded {
                expansion.messages.insert(model.message.id)
                reload()
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
