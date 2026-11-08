import AppKit

/// What a chat timeline shows and answers to: a chat tab's `AgentChatSession`, or the Agent
/// Dashboard's read-only view of a terminal agent's transcript (`DashTranscriptSource`).
@MainActor
protocol ChatTimelineSource: AnyObject {
    var thread: ChatThread { get }
    /// What the timeline says while the conversation has no turns.
    func emptyTimelineText(agentName: String) -> String
    /// A queued message can be steered into the running turn.
    var canSendQueuedNow: Bool { get }
    func choosePermissionOption(_ optionId: String)
    func sendQueuedPromptNow(id: String)
    func removeQueuedPrompt(id: String)
}

extension AgentChatSession: ChatTimelineSource {
    func emptyTimelineText(agentName: String) -> String {
        phase == .starting ? "Starting \(agentName)…" : "Send a message to start the conversation."
    }

    var canSendQueuedNow: Bool { phase == .working && supportsSteering }
}

/// The chat's timeline, ported from Soprano Agents' `TimelineViewController`: the source's
/// turns in the centered chat lane (`TimelineListView`), what is expanded, the "Working for"
/// clock and the jump-to-latest pill. Rows ask it for every action through `TimelineRowDelegate`.
@MainActor
final class ChatTimelineView: PaletteView, TimelineRowDelegate {
    let source: ChatTimelineSource
    var agentName: String

    /// Space at the bottom the floating composer covers; the timeline pads its content by it.
    var bottomInset: CGFloat = 0 {
        didSet {
            list.bottomInset = bottomInset
            needsLayout = true
        }
    }

    /// Keys the list does not use (typing, Escape).
    var keyHandler: ((NSEvent) -> Bool)? {
        get { list.keyHandler }
        set { list.keyHandler = newValue }
    }

    /// Called when the timeline starts or stops following its newest row.
    var onFollowingChange: ((Bool) -> Void)?

    private let scrollView = NSScrollView()
    private let list = TimelineListView()
    private let jumpPill = JumpToLatestPill(frame: .zero)
    private(set) var expansion = TimelineExpansion()
    private var clock: Timer?

    init(source: ChatTimelineSource, agentName: String, identifier: String = "agent-chat-timeline") {
        self.source = source
        self.agentName = agentName
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .none
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        list.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        list.autoresizingMask = [.width]
        list.rowDelegate = self
        scrollView.documentView = list
        scrollView.identifier = NSUserInterfaceItemIdentifier(identifier)
        addSubview(scrollView)

        jumpPill.isHidden = true
        jumpPill.onClick = { [weak self] in self?.jumpToLatest() }
        addSubview(jumpPill)

        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.list.didScroll() }
        }
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.list.clipDidResize() }
        }
        list.onPinnedChange = { [weak self] pinned in
            self?.setJumpPillVisible(!pinned)
            self?.onFollowingChange?(pinned)
        }
        applyPalette(palette)
        reload(scrollToEnd: true)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.background.cgColor
        // Rendered Markdown carries its colors: rebuild what is on screen.
        list.reconfigureVisibleRows()
    }

    override func layout() {
        super.layout()
        let pillSize = jumpPill.pillSize
        jumpPill.frame = NSRect(
            x: floor((bounds.width - pillSize.width) / 2), y: bounds.height - bottomInset - pillSize.height + 6,
            width: pillSize.width, height: pillSize.height
        )
    }

    /// The list, which takes the keyboard while the person reads.
    var listView: NSView { list }

    var rows: [TimelineRow] { list.rows }

    // MARK: Rows

    /// What the empty chat says.
    private var emptyText: String {
        source.emptyTimelineText(agentName: agentName)
    }

    func reload(scrollToEnd: Bool = false) {
        let thread = source.thread
        list.setRows(TimelineBuilder.rows(for: thread, emptyText: emptyText, expansion: expansion), scrollToEnd: scrollToEnd)
        updateClock(running: thread.isRunning)
        setJumpPillVisible(!list.isPinnedToBottom)
    }

    /// Whether the timeline sticks to its newest row as rows arrive.
    var isFollowing: Bool { list.isPinnedToBottom }

    /// The detailed work log (folds, groups and diffs open by default) or the minimal one.
    /// What the person toggled is read against the default, so switching drops it.
    var isDetailed: Bool {
        get { expansion.detailed }
        set {
            guard newValue != expansion.detailed else { return }
            expansion.detailed = newValue
            expansion.turns = []
            expansion.groups = []
            expansion.diffs = []
            reload()
        }
    }

    /// Scrolls by `delta` points, as the person would.
    func scroll(by delta: CGFloat) {
        list.scrollUser(by: delta)
    }

    /// The visible height a page scroll moves by.
    var pageHeight: CGFloat {
        max(48, scrollView.contentView.bounds.height - bottomInset - 40)
    }

    /// Scrolls the next (`direction` > 0) or previous message the person sent to the top. Past
    /// the last message it follows the newest row; before the first it goes to the top.
    func jumpToMessage(_ direction: Int) {
        let messages = list.rows.compactMap { row -> String? in
            if case let .user(model) = row.content, model.turnID != nil { return row.id }
            return nil
        }
        let current = scrollView.contentView.bounds.minY
        let tops = messages.compactMap { id in list.top(ofRow: id).map { (id: id, top: $0) } }
        let target = direction > 0
            ? tops.first { $0.top > current + list.topPadding + 8 }
            : tops.last { $0.top < current + list.topPadding - 8 }
        if let target {
            list.scrollRowToTop(target.id)
        } else if direction > 0 {
            jumpToLatest()
        } else {
            list.scrollUser(by: -current)
        }
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

    /// Stops the clock (the tab is closing).
    func close() {
        clock?.invalidate()
        clock = nil
    }

    private func setJumpPillVisible(_ visible: Bool) {
        let show = visible && !list.rows.isEmpty
        guard jumpPill.isHidden == show else { return }
        jumpPill.isHidden = !show
        needsLayout = true
    }

    func jumpToLatest() {
        list.jumpToEnd()
        setJumpPillVisible(false)
    }

    // MARK: Expansion

    private func toggle(_ id: String, in keyPath: WritableKeyPath<TimelineExpansion, Set<String>>) {
        if expansion[keyPath: keyPath].contains(id) {
            expansion[keyPath: keyPath].remove(id)
        } else {
            expansion[keyPath: keyPath].insert(id)
        }
        reload()
        // A pinned timeline follows its end; keep an opened row's header in view instead.
        if let rowID = openedRowID(id, in: keyPath) {
            list.reveal(rowID: rowID, rect: NSRect(x: 0, y: 0, width: 1, height: 24))
        }
    }

    /// The row that `id` opened, if toggling it opened one.
    private func openedRowID(_ id: String, in keyPath: WritableKeyPath<TimelineExpansion, Set<String>>) -> String? {
        list.rows.first { row in
            switch row.content {
            case let .fold(model): keyPath == \.turns && model.turnID == id && model.expanded
            case let .workGroup(model): keyPath == \.groups && model.groupID == id && model.expanded
            case let .liveWork(model): keyPath == \.groups && model.groupID == id && model.expanded
            case let .workEntry(model): keyPath == \.entries && model.entry.id == id && model.expanded
            case let .fileDiff(model): keyPath == \.diffs && model.id == id && model.expanded
            case let .user(model): keyPath == \.messages && model.message.id == id && model.expanded
            default: false
            }
        }?.id
    }

    // MARK: TimelineRowDelegate

    func timelineToggleFold(turnID: String) { toggle(turnID, in: \.turns) }
    func timelineToggleGroup(_ groupID: String) { toggle(groupID, in: \.groups) }
    func timelineToggleEntry(_ itemID: String) { toggle(itemID, in: \.entries) }
    func timelineToggleDiff(_ diffID: String) { toggle(diffID, in: \.diffs) }
    func timelineToggleMessage(_ messageID: String) { toggle(messageID, in: \.messages) }

    func timelineSetClosedFolders(turnID: String, paths: Set<String>) {
        expansion.closedFolders[turnID] = paths
        reload()
    }

    func timelineRespond(approvalID: String, optionID: String) {
        source.choosePermissionOption(optionID)
    }

    /// Opens the turn's fold and the work group holding the file's diff, opens the diff and
    /// scrolls to it.
    func timelineRevealDiff(turnID: String, path: String) {
        expansion.set(turnID, open: true, in: \.turns)
        for _ in 0..<2 {
            let thread = source.thread
            let rows = TimelineBuilder.rows(for: thread, emptyText: emptyText, expansion: expansion)
            let messageRow = thread.turns.first { $0.id == turnID }.map { "user:\($0.userMessage.id)" }
            guard let start = rows.firstIndex(where: { $0.id == messageRow || $0.id == "fold:\(turnID)" }) else { break }
            // The turn's rows run until the next turn's message.
            let end = rows[(start + 1)...].firstIndex {
                if case let .user(model) = $0.content { return model.turnID != nil }
                return false
            } ?? rows.endIndex
            for row in rows[start..<end] {
                guard case let .fileDiff(model) = row.content, (model.change.movePath ?? model.change.path) == path else { continue }
                expansion.set(model.id, open: true, in: \.diffs)
                reload()
                list.reveal(rowID: row.id, rect: NSRect(x: 0, y: 0, width: 1, height: 24))
                return
            }
            // The diff sits in a closed group: open the turn's groups and look again.
            for row in rows[start..<end] {
                if case let .workGroup(model) = row.content, !model.expanded {
                    expansion.set(model.groupID, open: true, in: \.groups)
                }
            }
        }
        reload()
    }

    var timelineCanSendQueuedNow: Bool {
        source.canSendQueuedNow
    }

    func timelineSendQueuedNow(messageID: String) {
        source.sendQueuedPromptNow(id: messageID)
    }

    func timelineRemoveQueued(messageID: String) {
        source.removeQueuedPrompt(id: messageID)
    }

    func timelineCopy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// "Scroll to end" floating over the composer while the timeline is scrolled up.
final class JumpToLatestPill: InteractiveView {
    private let icon = TimelineIconView(symbol: Icon.chevronDown, size: 11)
    private let label = NSTextField.timelineLabel("Scroll to end", size: Typography.smallSize, weight: .medium)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = 13
        layer?.borderWidth = 1
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        addSubview(icon)
        addSubview(label)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Scroll to end")
        toolTip = "Jump to latest"
        applyPalette(palette)
    }

    var pillSize: NSSize {
        let labelWidth = label.textFitWidth
        return NSSize(width: 10 + 14 + 4 + labelWidth + 12, height: 26)
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 10, y: (bounds.height - 14) / 2, width: 14, height: 14)
        label.frame = NSRect(x: 28, y: (bounds.height - 16) / 2, width: bounds.width - 28 - 10, height: 16)
    }

    override func applyPalette(_ palette: Palette) {
        let fill = palette.background.mixed(with: palette.foreground, fraction: isHovered ? 0.06 : 0.02)
        layer?.backgroundColor = fill.timelineAlpha(0.92).cgColor
        layer?.borderColor = palette.foreground.timelineAlpha(0.1).cgColor
        layer?.shadowColor = NSColor.black.timelineAlpha(palette.isDark ? 0.5 : 0.12).cgColor
        icon.contentTintColor = palette.foreground
        label.textColor = palette.foreground
    }
}
