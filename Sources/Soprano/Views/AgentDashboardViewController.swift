import AppKit

/// Full-window operational view over every attached agent, laid out like a
/// mail client: the shared overlay header, a sidebar listing the agents under
/// Needs you, Working, Ready and Stopped, and beside it the selected agent's
/// detail — a header with a toolbar, its conversation, and a reply composer.
final class AgentDashboardViewController: NSViewController {
    typealias TerminalStateProvider = (TerminalTarget) -> TerminalInteractionState
    typealias PromptSender = (TerminalTarget, String) -> Bool
    /// A folder's branch when it is not its repository's default, else nil.
    typealias BranchProvider = (String) -> String?

    /// The agent sidebar's width; a narrow window takes it down to
    /// `listMaximumFraction` of the dashboard.
    fileprivate static let listWidth: CGFloat = 380
    fileprivate static let listMaximumFraction: CGFloat = 0.4
    /// The sidebar's footer with the list's key hints.
    fileprivate static let footerHeight: CGFloat = 44

    let agentManager: AgentManager
    let themeManager: ThemeManager

    var onDismiss: (() -> Void)?
    var onAgentSelected: ((String, String) -> Void)?

    private let terminalStateProvider: TerminalStateProvider
    private let promptSender: PromptSender
    private let branchProvider: BranchProvider
    private let transcriptStore: AgentTranscriptStore
    private var headerView: ShellPageHeaderView!
    private var listPanel: NSView!
    private var listRule: DashRuleView!
    private var keyHintsView: AgentDashboardHintsView!
    private var keyHintsRule: DashRuleView!
    private var rowsStack: NSStackView!
    private var detailView: AgentDashboardDetailView!
    private var agentRows: [AgentDashboardRowView] = []
    private var sectionHeaders: [AgentDashboardSection: AgentDashboardSectionHeaderView] = [:]
    private var emptyStateView: NSView?
    private var entriesById: [String: AgentDashboardEntry] = [:]
    private var selectedEntryId: String?
    /// Whether the keyboard is on the agent list, which marks its selected
    /// row with the pencil tick.
    private var isListFocused = false
    nonisolated(unsafe) private var elapsedTimer: Timer?
    private let observerId = "AgentDashboardViewController"

    init(
        agentManager: AgentManager,
        themeManager: ThemeManager,
        terminalStateProvider: @escaping TerminalStateProvider = { _ in .unavailable },
        promptSender: @escaping PromptSender = { _, _ in false },
        branchProvider: @escaping BranchProvider = { _ in nil },
        transcriptStore: AgentTranscriptStore = AgentTranscriptStore()
    ) {
        self.agentManager = agentManager
        self.themeManager = themeManager
        self.terminalStateProvider = terminalStateProvider
        self.promptSender = promptSender
        self.branchProvider = branchProvider
        self.transcriptStore = transcriptStore
        super.init(nibName: nil, bundle: nil)
        agentManager.addObserver(id: observerId) { [weak self] change in
            switch change {
            case .model:
                self?.refresh()
            case .tabTitle(let target), .tabWorkingDirectory(let target):
                self?.refreshEntry(target)
            case .browserURL, .document:
                break
            }
        }
        transcriptStore.onChange = { [weak self] entryId in
            self?.transcriptDidChange(entryId)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        elapsedTimer?.invalidate()
        agentManager.removeObserver(id: observerId)
    }

    override func loadView() {
        let theme = themeManager.currentTheme
        let root = AgentDashboardRootView()
        root.identifier = NSUserInterfaceItemIdentifier("agent-dashboard")
        root.onEscape = { [weak self] in
            self?.onDismiss?()
        }
        root.onMoveSelection = { [weak self] delta in
            self?.moveSelection(by: delta)
        }
        root.onActivateSelection = { [weak self] in
            self?.activateSelection()
        }
        root.onFocusReply = { [weak self] in
            self?.detailView.focusReply()
        }
        root.onScroll = { [weak self] amount in
            self?.detailView.scrollText(amount)
        }
        root.onJumpTurn = { [weak self] direction in
            self?.detailView.jumpToTurn(direction)
        }
        root.onToggleDetails = { [weak self] in
            self?.detailView.toggleDetails()
        }
        root.onFollowLatest = { [weak self] in
            self?.detailView.followLatest()
        }
        root.onToggleTerminal = { [weak self] in
            self?.detailView.toggleTerminal()
        }
        root.onFocusChange = { [weak self] focused in
            self?.setListFocused(focused)
        }
        root.wantsLayer = true
        root.layer?.backgroundColor = PaletteCenter.shared.palette.background.cgColor

        headerView = ShellPageHeaderView(title: "Agent Dashboard")
        headerView.onClose = { [weak self] in
            self?.onDismiss?()
        }
        root.addSubview(headerView)

        listPanel = makeAgentListPanel(theme: theme)
        root.addSubview(listPanel)

        detailView = AgentDashboardDetailView(theme: theme)
        detailView.waitingReason = { [weak agentManager] entry in
            agentManager?.agent(paneId: entry.paneId, tabId: entry.tabId)?.waitingReason
        }
        detailView.onOpen = { [weak self] target in
            self?.onAgentSelected?(target.paneId, target.tabId)
        }
        detailView.onStop = { [weak agentManager] target in
            agentManager?.stopAgent(target: target)
        }
        detailView.onRestart = { [weak agentManager] target in
            agentManager?.restartAgent(target: target)
        }
        detailView.onSend = { [weak self] target, prompt in
            self?.promptSender(target, prompt) ?? false
        }
        detailView.onTerminalShown = { [weak self] in
            self?.refreshDetailTerminal()
        }
        detailView.keyHandler = { [weak root] event in
            root?.handleKey(event) ?? false
        }
        detailView.onLeaveReply = { [weak root] in
            guard let root else { return }
            root.window?.makeFirstResponder(root)
        }
        root.addSubview(detailView)

        let preferredListWidth = listPanel.widthAnchor.constraint(equalToConstant: Self.listWidth)
        preferredListWidth.priority = dashFillPriority
        NSLayoutConstraint.activate([
            headerView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            headerView.topAnchor.constraint(equalTo: root.topAnchor),

            listPanel.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            preferredListWidth,
            listPanel.widthAnchor.constraint(
                lessThanOrEqualTo: root.widthAnchor,
                multiplier: Self.listMaximumFraction
            ),
            listPanel.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            listPanel.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            detailView.leadingAnchor.constraint(equalTo: listPanel.trailingAnchor),
            detailView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            detailView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            detailView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        self.view = root
        refresh()
        elapsedTimer = Timer.scheduledTimer(
            withTimeInterval: 1,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Date()
                self.transcriptStore.refresh()
                for row in self.agentRows {
                    row.updateElapsed(now: now)
                    row.updateActivity(self.activity(for: row.entry, now: now))
                }
                self.refreshDetailTerminal()
                self.detailView.tick(now: now)
            }
        }
    }

    func apply(theme: AppTheme) {
        guard isViewLoaded else { return }
        let palette = PaletteCenter.shared.palette
        view.layer?.backgroundColor = palette.background.cgColor
        headerView.apply(theme: theme)
        listPanel.layer?.backgroundColor = palette.sidebar.cgColor
        listRule.applyPalette(palette)
        keyHintsRule.applyPalette(palette)
        keyHintsView.apply(theme: theme)
        detailView.apply(theme: theme)
        // Rows, section headings and the empty state take their colors when
        // they are built, so a theme change rebuilds them.
        rowsStack.setArrangedSubviews([])
        agentRows.removeAll()
        sectionHeaders.removeAll()
        emptyStateView = nil
        refresh()
    }

    /// Brings the dashboard up to date with the agent manager. This runs for
    /// every model notification, and busy agents retitle their tabs several
    /// times a second, so it only touches views whose content changed.
    private func refresh() {
        guard isViewLoaded else { return }
        let snapshot = agentManager.agentDashboardSnapshot()
        let entries = snapshot.entries.map(withBranch)
        let theme = themeManager.currentTheme
        let previousSelection = selectedEntryId
        let previousSelectedEntry = previousSelection.flatMap { entriesById[$0] }
        entriesById = Dictionary(
            uniqueKeysWithValues: entries.map { ($0.id, $0) }
        )
        selectedEntryId = entries.contains {
            $0.id == previousSelection
        } ? previousSelection : entries.first?.id
        trackTranscripts(of: entries)
        let subtitle = monitoringSubtitle(
            agentCount: snapshot.totalCount,
            windowCount: agentManager.windowCount
        )
        if headerView.subtitle != subtitle {
            headerView.subtitle = subtitle
        }
        reconcileRows(with: AgentDashboardSection.group(entries), theme: theme)
        updateRowSelection(
            scrollIntoView: previousSelection != nil && selectedEntryId != previousSelection
        )
        if selectedEntryId.flatMap({ entriesById[$0] }) != previousSelectedEntry {
            updateDetail()
        }
    }

    /// Follows a title or directory change of one tab. Busy agents retitle
    /// their tabs several times a second; neither change moves an agent in the
    /// urgency order or alters the counts, so only its row and, while it is
    /// selected, the detail view are redrawn.
    private func refreshEntry(_ target: TerminalTarget) {
        guard isViewLoaded,
              let row = agentRows.first(where: {
                  $0.entry.paneId == target.paneId && $0.entry.tabId == target.tabId
              }),
              let entry = agentManager.agentDashboardEntry(for: target).map(withBranch)
        else { return }
        entriesById[entry.id] = entry
        row.update(entry: entry)
        if entry.id == selectedEntryId {
            updateDetail()
        }
    }

    /// The entry with its notable branch. A branch read on each refresh is a
    /// cache lookup in the shared monitor, which watches every pane's HEAD;
    /// a checkout comes with agent activity that refreshes the dashboard.
    private func withBranch(_ entry: AgentDashboardEntry) -> AgentDashboardEntry {
        var entry = entry
        entry.branch = entry.cwd.flatMap(branchProvider)
        return entry
    }

    /// Lays out the sections in urgency order: updates surviving rows and
    /// headings in place, adds them for new agents and sections, drops those
    /// that are gone, and moves rows whose urgency changed.
    private func reconcileRows(
        with sections: [(section: AgentDashboardSection, entries: [AgentDashboardEntry])],
        theme: AppTheme
    ) {
        var reusableRows = Dictionary(
            uniqueKeysWithValues: agentRows.map { ($0.entry.id, $0) }
        )
        var headers: [AgentDashboardSection: AgentDashboardSectionHeaderView] = [:]
        var rows: [AgentDashboardRowView] = []
        var views: [NSView] = []
        for (section, entries) in sections {
            let header = sectionHeaders[section]
                ?? AgentDashboardSectionHeaderView(section: section, theme: theme)
            header.update(count: entries.count)
            headers[section] = header
            views.append(header)
            for entry in entries {
                let row = reusableRows.removeValue(forKey: entry.id).map { row in
                    row.update(entry: entry)
                    return row
                } ?? makeRow(entry: entry, theme: theme)
                row.updateActivity(activity(for: entry))
                rows.append(row)
                views.append(row)
            }
        }
        sectionHeaders = headers
        agentRows = rows
        if !rows.isEmpty {
            emptyStateView = nil
        } else if emptyStateView == nil {
            emptyStateView = makeEmptyState(theme: theme)
        }
        rowsStack.setArrangedSubviews(emptyStateView.map { [$0] } ?? views) { view in
            view.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }
    }

    private func makeRow(entry: AgentDashboardEntry, theme: AppTheme) -> AgentDashboardRowView {
        let row = AgentDashboardRowView(entry: entry, theme: theme) { [weak agentManager] entry in
            agentManager?.agent(paneId: entry.paneId, tabId: entry.tabId)?.waitingReason
        }
        row.isListFocused = isListFocused
        row.onSelect = { [weak self] in
            guard let self else { return }
            self.view.window?.makeFirstResponder(self.view)
            self.selectEntry(entry.id)
        }
        row.onOpen = { [weak self] in
            self?.onAgentSelected?(entry.paneId, entry.tabId)
        }
        return row
    }

    /// The sidebar: the sectioned rows on the panel surface over a footer
    /// with the list's key hints, closed by one hairline on its trailing edge.
    private func makeAgentListPanel(theme: AppTheme) -> NSView {
        let palette = PaletteCenter.shared.palette
        let panel = NSView()
        panel.identifier = NSUserInterfaceItemIdentifier("agent-dashboard-list")
        panel.wantsLayer = true
        panel.layer?.backgroundColor = palette.sidebar.cgColor
        panel.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(scrollView)

        let documentView = AgentDashboardFlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 2
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(rowsStack)

        keyHintsRule = DashRuleView(axis: .horizontal)
        panel.addSubview(keyHintsRule)

        keyHintsView = AgentDashboardHintsView(
            hints: [(["J", "K"], "Select"), (["↵"], "Open"), (["Tab"], "Reply"), (["T"], "Terminal")],
            spacing: 14,
            theme: theme
        )
        keyHintsView.identifier = NSUserInterfaceItemIdentifier("agent-dashboard-key-hints")
        panel.addSubview(keyHintsView)

        listRule = DashRuleView(axis: .vertical)
        panel.addSubview(listRule)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: listRule.leadingAnchor),
            scrollView.topAnchor.constraint(equalTo: panel.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: keyHintsRule.topAnchor),

            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.bottomAnchor.constraint(
                greaterThanOrEqualTo: scrollView.contentView.bottomAnchor
            ),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            rowsStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            rowsStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 4),
            rowsStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -8),

            keyHintsRule.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            keyHintsRule.trailingAnchor.constraint(equalTo: listRule.leadingAnchor),
            keyHintsRule.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -Self.footerHeight),

            keyHintsView.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: ShellSidebarMetrics.contentLeft),
            keyHintsView.trailingAnchor.constraint(lessThanOrEqualTo: listRule.leadingAnchor, constant: -12),
            keyHintsView.centerYAnchor.constraint(equalTo: panel.bottomAnchor, constant: -Self.footerHeight / 2),

            listRule.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            listRule.topAnchor.constraint(equalTo: panel.topAnchor),
            listRule.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])
        return panel
    }

    private func selectEntry(_ entryId: String) {
        guard entriesById[entryId] != nil else { return }
        selectedEntryId = entryId
        updateRowSelection(scrollIntoView: false)
        updateDetail()
    }

    private func moveSelection(by delta: Int) {
        guard !agentRows.isEmpty else { return }
        let currentIndex = selectedEntryId.flatMap { selectedId in
            agentRows.firstIndex { $0.entry.id == selectedId }
        } ?? 0
        let nextIndex = min(max(0, currentIndex + delta), agentRows.count - 1)
        // J/K drive the list even from the timeline or terminal; take focus
        // back so the moved row shows the focused pill and pencil tick.
        view.window?.makeFirstResponder(view)
        selectedEntryId = agentRows[nextIndex].entry.id
        updateRowSelection(scrollIntoView: true)
        updateDetail()
    }

    private func activateSelection() {
        guard let selectedEntryId,
              let entry = agentRows.first(where: {
                  $0.entry.id == selectedEntryId
              })?.entry
        else { return }
        onAgentSelected?(entry.paneId, entry.tabId)
    }

    private func setListFocused(_ focused: Bool) {
        guard isListFocused != focused else { return }
        isListFocused = focused
        for row in agentRows {
            row.isListFocused = focused
        }
    }

    private func updateDetail() {
        guard let selectedEntryId,
              let entry = entriesById[selectedEntryId]
        else {
            detailView.update(entry: nil, terminal: .unavailable, timeline: nil, hasTranscript: false)
            return
        }
        let target = TerminalTarget(paneId: entry.paneId, tabId: entry.tabId)
        detailView.update(
            entry: entry,
            terminal: terminalStateProvider(target),
            timeline: transcriptStore.timeline(for: entry.id),
            hasTranscript: transcriptStore.isTracking(entry.id)
        )
    }

    /// Reads the live terminal of the selected agent, but only while the
    /// detail view shows it: reading terminal text every second is not free.
    private func refreshDetailTerminal() {
        guard detailView.isShowingTerminal,
              let selectedEntryId,
              let entry = entriesById[selectedEntryId]
        else { return }
        let target = TerminalTarget(paneId: entry.paneId, tabId: entry.tabId)
        detailView.updateTerminal(terminalStateProvider(target))
    }

    /// Follows the transcripts of the listed agents whose CLI writes one.
    private func trackTranscripts(of entries: [AgentDashboardEntry]) {
        var sources: [String: AgentTranscriptSource] = [:]
        for entry in entries {
            sources[entry.id] = AgentTranscriptSource(
                profileId: entry.profileId,
                conversation: entry.conversation
            )
        }
        transcriptStore.track(sources)
    }

    private func transcriptDidChange(_ entryId: String) {
        guard isViewLoaded, let entry = entriesById[entryId] else { return }
        agentRows.first { $0.entry.id == entryId }?.updateActivity(activity(for: entry))
        if entryId == selectedEntryId {
            detailView.updateTimeline(
                transcriptStore.timeline(for: entryId),
                hasTranscript: transcriptStore.isTracking(entryId)
            )
        }
    }

    private func activity(for entry: AgentDashboardEntry, now: Date = Date()) -> AgentTimelineActivity? {
        AgentTimelineActivity.current(
            in: transcriptStore.timeline(for: entry.id),
            status: entry.status,
            now: now
        )
    }

    private func updateRowSelection(scrollIntoView: Bool) {
        for row in agentRows {
            row.setKeyboardSelected(row.entry.id == selectedEntryId)
        }
        guard scrollIntoView,
              let selectedRow = agentRows.first(where: { $0.entry.id == selectedEntryId })
        else { return }
        // A row added by this refresh has no frame until layout runs.
        view.layoutSubtreeIfNeeded()
        selectedRow.scrollToVisible(selectedRow.bounds)
    }

    private func monitoringSubtitle(agentCount: Int, windowCount: Int) -> String {
        let agentNoun = agentCount == 1 ? "agent" : "agents"
        let windowNoun = windowCount == 1 ? "window" : "windows"
        return "Monitoring \(agentCount) \(agentNoun) across \(windowCount) \(windowNoun)"
    }

    private func makeEmptyState(theme: AppTheme) -> NSView {
        let container = NSView()
        container.identifier = NSUserInterfaceItemIdentifier("agent-dashboard-empty")
        container.translatesAutoresizingMaskIntoConstraints = false
        container.heightAnchor.constraint(equalToConstant: 150).isActive = true

        // Both lines wrap, centered, so a narrow sidebar never cuts them off.
        let titleText = "No agents to monitor"
        let title = NSTextField(wrappingLabelWithString: titleText)
        title.alignment = .center
        title.lineBreakMode = .byWordWrapping
        title.attributedStringValue = NSAttributedString(string: titleText, attributes: [
            .font: Typography.ui(Typography.bodySize, weight: .medium),
            .foregroundColor: PaletteCenter.shared.palette.mutedForeground,
        ])
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(title)

        let detailText = "Launch an agent from the sidebar or command palette."
        let detail = NSTextField(wrappingLabelWithString: detailText)
        detail.alignment = .center
        detail.lineBreakMode = .byWordWrapping
        detail.attributedStringValue = NSAttributedString(string: detailText, attributes: [
            .font: Typography.ui(Typography.smallSize),
            .foregroundColor: PaletteCenter.shared.palette.mutedForeground.shellScaled(by: 0.7),
        ])
        detail.alignment = .center
        detail.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(detail)

        let inset: CGFloat = 16
        NSLayoutConstraint.activate([
            title.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            title.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: inset),
            title.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -10),
            detail.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: inset),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
        ])
        return container
    }
}

/// How far one keyboard shortcut scrolls the detail text.
private enum AgentDashboardScroll: Equatable {
    case lines(Int)
    case pages(Int)
}

/// Just below `.windowSizeStayPut`: the dashboard's preferred widths give way
/// before the window would resize for them.
private let dashFillPriority = NSLayoutConstraint.Priority(
    rawValue: NSLayoutConstraint.Priority.windowSizeStayPut.rawValue - 1
)

/// A one-point `border` hairline (the sidebar's trailing edge, the footer's top).
private final class DashRuleView: PaletteView {
    private let axis: NSLayoutConstraint.Orientation

    init(axis: NSLayoutConstraint.Orientation) {
        self.axis = axis
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: axis == .horizontal ? .vertical : .horizontal)
        applyPalette(palette)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        axis == .horizontal
            ? NSSize(width: NSView.noIntrinsicMetric, height: 1)
            : NSSize(width: 1, height: NSView.noIntrinsicMetric)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.border.cgColor
    }
}

/// The live terminal's read-only text. It hands plain keys back to the
/// dashboard, so clicking into the text to copy something never captures J/K.
private final class DashTerminalTextView: NSTextView {
    var keyHandler: ((NSEvent) -> Bool)?

    /// A read-only text view in a borderless scroll view.
    static func makeScrollView(identifier: String, inset: NSSize) -> (NSScrollView, DashTerminalTextView) {
        let scrollView = NSScrollView()
        scrollView.identifier = NSUserInterfaceItemIdentifier(identifier)
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.hasHorizontalScroller = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let textView = DashTerminalTextView(usingTextLayoutManager: false)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.font = Typography.mono()
        textView.textContainerInset = inset
        scrollView.documentView = textView
        return (scrollView, textView)
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }
}

/// How long an agent has been running: `38s`, `4m 12s`, `2h 7m`.
private func agentDashboardElapsedText(status: AgentStatus, startedAt: Date?, now: Date) -> String {
    guard let startedAt else { return "" }
    if status == .stopped {
        return "stopped"
    }
    let interval = max(0, Int(now.timeIntervalSince(startedAt)))
    if interval < 60 {
        return "\(interval)s"
    }
    if interval < 3_600 {
        return "\(interval / 60)m \(interval % 60)s"
    }
    return "\(interval / 3_600)h \((interval % 3_600) / 60)m"
}

/// The Agent Dashboard's read-only source for the chat timeline: the selected agent's
/// transcript as turns (`ChatThread(transcript:isRunning:)`). The dashboard answers no
/// approvals and queues no messages through it.
@MainActor
final class DashTranscriptSource: ChatTimelineSource {
    var thread = ChatThread()
    /// What the timeline says before the transcript has a turn.
    var emptyText = ""

    func emptyTimelineText(agentName: String) -> String { emptyText }
    var canSendQueuedNow: Bool { false }
    func choosePermissionOption(_ optionId: String) {}
    func sendQueuedPromptNow(id: String) {}
    func removeQueuedPrompt(id: String) {}
}

/// The selected agent: its title and context over a toolbar (Timeline or
/// Terminal, details, Open / Stop / Restart), then its conversation in Soprano
/// Agents' chat timeline (user bubbles, Worked-for folds, the work log, diffs,
/// Markdown) — or its live terminal in a code card — and at the bottom a
/// composer with what the agent is doing right now over the reply field.
private final class AgentDashboardDetailView: NSView, NSTextFieldDelegate {
    var onOpen: ((TerminalTarget) -> Void)?
    var onStop: ((TerminalTarget) -> Void)?
    var onRestart: ((TerminalTarget) -> Void)?
    var onSend: ((TerminalTarget, String) -> Bool)?
    /// Called after switching to the live terminal, whose text is only read
    /// while it is shown.
    var onTerminalShown: (() -> Void)?
    /// Called on ⇧Tab in the reply field to hand focus back to the agent list.
    var onLeaveReply: (() -> Void)?
    /// Takes plain keys typed while the timeline or terminal text has focus,
    /// so a click into the text to copy something never captures J/K.
    var keyHandler: ((NSEvent) -> Bool)? {
        didSet {
            timelineView.keyHandler = keyHandler
            terminalTextView.keyHandler = keyHandler
        }
    }

    private static let gutter: CGFloat = 24
    /// The composer keeps to the timeline's chat lane, centered.
    private static let readableWidth = Metrics.chatMaxWidth
    private static let replyFieldHeight: CGFloat = 48

    private var theme: AppTheme
    private var entry: AgentDashboardEntry?
    private var terminal = TerminalInteractionState.unavailable
    private var timeline: AgentTimeline?
    private var hasTranscript = false
    /// Set with T; applies to every agent until switched back.
    private var prefersTerminal = false
    /// The detailed work log (O); the minimal one by default.
    private var isDetailed = false
    private let transcriptSource: DashTranscriptSource
    private let timelineView: ChatTimelineView

    /// The status pill's symbol before the title (Agents' header pill).
    private let statusMark = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "No agent selected")
    private let statusLabel = NSTextField(labelWithString: "")
    private let timerLabel = NSTextField(labelWithString: "")
    private let locationLabel = NSTextField(labelWithString: "")
    private let modeControl = ShellSegmentedControl(titles: ["Timeline", "Terminal"])
    private let detailsButton = ShellTextButton(title: "Show details", keycap: "O", variant: .ghost)
    private let openButton = ShellTextButton(title: "Open", keycap: "↵")
    private let stopButton = ShellTextButton(title: "Stop")
    private let restartButton = ShellTextButton(title: "Restart")
    private let toolbar = NSStackView()
    private let contentRule = NSView()
    private var terminalCard: NSView!
    private var terminalScrollView: NSScrollView!
    private var terminalTextView: DashTerminalTextView!
    private let activityMark = NSImageView()
    private let activityLabel = NSTextField(labelWithString: "")
    /// Agents' composer card around the reply field and the send button.
    private let replyFieldView = ShellComposerSurface()
    private let replyField = AgentDashboardReplyField()
    /// The chat composer's round send button: the primary disc while there is
    /// something to send, the faint disabled disc otherwise.
    private let sendButton = ComposerPrimaryButton()
    private let replyHintLabel = NSTextField(labelWithString: "")

    /// Whether the selected agent shows its live terminal instead of its
    /// timeline: agents without a readable transcript, or after T.
    var isShowingTerminal: Bool { !showsTimeline }

    /// A chat has no terminal to show, so it always shows its conversation.
    private var showsTimeline: Bool { entry?.isChat == true || (hasTranscript && !prefersTerminal) }

    init(theme: AppTheme) {
        self.theme = theme
        let source = DashTranscriptSource()
        let timelineView = ChatTimelineView(source: source, agentName: "", identifier: "agent-dashboard-timeline")
        timelineView.isDetailed = false
        transcriptSource = source
        self.timelineView = timelineView
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("agent-dashboard-detail")
        translatesAutoresizingMaskIntoConstraints = false
        build()
        apply(theme: theme)
        refreshEntryLabels()
        applyMode()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        let palette = PaletteCenter.shared.palette
        refreshEntryLabels()
        contentRule.layer?.backgroundColor = palette.border.cgColor
        layer?.backgroundColor = palette.background.cgColor
        // The live terminal sits in an Agents code card (SF Mono 13 on the
        // code background, radius 8), a terminal shown inside the page.
        terminalCard.layer?.backgroundColor = palette.codeBackground.cgColor
        terminalCard.layer?.borderColor = palette.border.cgColor
        terminalScrollView.backgroundColor = palette.codeBackground
        terminalTextView.backgroundColor = palette.codeBackground
        terminalTextView.insertionPointColor = palette.foreground
        terminalTextView.selectedTextAttributes = [
            .backgroundColor: palette.primary.withAlphaComponent(palette.isDark ? 0.45 : 0.22),
        ]
        styleReplyField()
        setReplyPlaceholder(replyField.placeholderAttributedString?.string)
        updateTerminalText()
        renderTimeline()
        updateActivity()
        updateControls()
    }

    func update(
        entry: AgentDashboardEntry?,
        terminal: TerminalInteractionState,
        timeline: AgentTimeline?,
        hasTranscript: Bool
    ) {
        guard entry != self.entry
            || terminal != self.terminal
            || timeline != self.timeline
            || hasTranscript != self.hasTranscript
        else { return }
        let selectionChanged = entry?.id != self.entry?.id
        // Highlighting the terminal text is the expensive part; redo it only
        // when the text shown in the terminal area can differ.
        let terminalTextChanged = terminal != self.terminal
            || (entry == nil) != (self.entry == nil)
        // The status decides whether calls without a result still run.
        let timelineChanged = selectionChanged
            || timeline != self.timeline
            || entry?.status != self.entry?.status
        let modeChanged = hasTranscript != self.hasTranscript || entry?.isChat != self.entry?.isChat
        if selectionChanged {
            replyField.stringValue = ""
        }
        self.entry = entry
        self.terminal = terminal
        self.timeline = timeline
        self.hasTranscript = hasTranscript
        refreshEntryLabels()
        if modeChanged {
            applyMode()
        } else if showsTimeline {
            // A newly selected agent's conversation opens at its newest entry.
            if timelineChanged { renderTimeline(scrollToEnd: selectionChanged) }
        } else if terminalTextChanged {
            updateTerminalText()
        }
        updateActivity()
        updateControls()
    }

    /// Follows the transcript store: a newly read timeline for the shown agent.
    func updateTimeline(_ timeline: AgentTimeline?, hasTranscript: Bool) {
        guard entry != nil,
              timeline != self.timeline || hasTranscript != self.hasTranscript
        else { return }
        let modeChanged = hasTranscript != self.hasTranscript
        self.timeline = timeline
        self.hasTranscript = hasTranscript
        if modeChanged {
            applyMode()
        } else if showsTimeline {
            renderTimeline()
        }
        updateActivity()
    }

    func updateTerminal(_ terminal: TerminalInteractionState) {
        guard entry != nil, terminal != self.terminal else { return }
        self.terminal = terminal
        if !showsTimeline {
            updateTerminalText()
        }
        updateControls()
    }

    /// Advances the elapsed times in the title and the activity line.
    func tick(now: Date) {
        updateTimer(now: now)
        updateActivity(now: now)
    }

    func focusReply() {
        guard replyField.isEnabled else { return }
        window?.makeFirstResponder(replyField)
    }

    func controlTextDidChange(_ notification: Notification) {
        updateSendButton()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        replyFieldView.isFocused = false
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard commandSelector == #selector(NSResponder.insertBacktab(_:)) else {
            return false
        }
        onLeaveReply?()
        return true
    }

    // MARK: - Keyboard

    func scrollText(_ amount: AgentDashboardScroll) {
        if showsTimeline {
            switch amount {
            case .lines(let count): timelineView.scroll(by: CGFloat(count) * 48)
            case .pages(let count): timelineView.scroll(by: CGFloat(count) * timelineView.pageHeight)
            }
            return
        }
        let clip = terminalScrollView.contentView
        let delta: CGFloat
        switch amount {
        case .lines(let count):
            delta = CGFloat(count) * 48
        case .pages(let count):
            delta = CGFloat(count) * max(clip.bounds.height - 40, 48)
        }
        let documentHeight = terminalScrollView.documentView?.frame.height ?? 0
        let maximum = max(0, documentHeight - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: min(max(0, clip.bounds.minY + delta), maximum)))
        terminalScrollView.reflectScrolledClipView(clip)
    }

    /// Scrolls the next (`direction` > 0) or previous prompt to the top.
    func jumpToTurn(_ direction: Int) {
        guard showsTimeline else { return }
        timelineView.jumpToMessage(direction)
    }

    /// O: the detailed work log (thinking, every step, open diffs) or the minimal one.
    func toggleDetails() {
        guard showsTimeline else { return }
        isDetailed.toggle()
        detailsButton.title = isDetailed ? "Hide details" : "Show details"
        timelineView.isDetailed = isDetailed
    }

    func followLatest() {
        if showsTimeline {
            timelineView.jumpToLatest()
        } else {
            let length = terminalTextView.textStorage?.length ?? 0
            terminalTextView.scrollRangeToVisible(NSRange(location: length, length: 0))
        }
    }

    func toggleTerminal() {
        setPrefersTerminal(!prefersTerminal)
    }

    private func setPrefersTerminal(_ prefers: Bool) {
        guard hasTranscript, entry?.isChat != true, prefers != prefersTerminal else { return }
        prefersTerminal = prefers
        applyMode()
        if prefersTerminal {
            onTerminalShown?()
        }
    }

    // MARK: - Layout

    private func build() {
        wantsLayer = true
        statusMark.imageScaling = .scaleNone
        statusMark.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusMark)

        titleLabel.identifier = NSUserInterfaceItemIdentifier("agent-dashboard-detail-title")
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        for label in [statusLabel, timerLabel] {
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        statusLabel.identifier = NSUserInterfaceItemIdentifier("agent-dashboard-detail-status")
        timerLabel.identifier = NSUserInterfaceItemIdentifier("agent-dashboard-detail-elapsed")

        locationLabel.identifier = NSUserInterfaceItemIdentifier("agent-dashboard-detail-location")
        locationLabel.lineBreakMode = .byTruncatingMiddle
        locationLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        locationLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(locationLabel)

        // Toolbar: the view switch and details on the left, the agent's
        // actions on the right. A narrow window drops only controls a key
        // also reaches — details (O), then the switch (T), then Open (Return);
        // Stop and Restart have no key, so they always stay.
        modeControl.identifier = NSUserInterfaceItemIdentifier("agent-dashboard-mode")
        modeControl.target = self
        modeControl.action = #selector(modeChanged(_:))
        modeControl.toolTip = "Show the conversation or the live terminal (T)"

        configureButton(detailsButton, identifier: "agent-dashboard-details", action: #selector(detailsClicked))
        detailsButton.toolTip = "Show thinking, full commands, and output (O)"

        configureButton(openButton, identifier: "agent-dashboard-open", action: #selector(openClicked))
        openButton.toolTip = "Open the agent in its window (Return)"
        configureButton(stopButton, identifier: "agent-dashboard-stop", action: #selector(stopClicked))
        configureButton(restartButton, identifier: "agent-dashboard-restart", action: #selector(restartClicked))

        toolbar.identifier = NSUserInterfaceItemIdentifier("agent-dashboard-toolbar")
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 6
        toolbar.setClippingResistancePriority(.defaultLow, for: .horizontal)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addView(modeControl, in: .leading)
        toolbar.addView(detailsButton, in: .leading)
        for button in [openButton, stopButton, restartButton] {
            toolbar.addView(button, in: .trailing)
        }
        toolbar.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: 880), for: detailsButton)
        toolbar.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: 890), for: modeControl)
        toolbar.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: 895), for: openButton)
        addSubview(toolbar)

        contentRule.wantsLayer = true
        contentRule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentRule)

        timelineView.translatesAutoresizingMaskIntoConstraints = false
        timelineView.bottomInset = 8
        addSubview(timelineView)

        terminalCard = NSView()
        terminalCard.identifier = NSUserInterfaceItemIdentifier("agent-dashboard-terminal-card")
        terminalCard.wantsLayer = true
        terminalCard.layer?.cornerRadius = Radius.lg
        terminalCard.layer?.borderWidth = 1
        terminalCard.layer?.masksToBounds = true
        terminalCard.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminalCard)
        (terminalScrollView, terminalTextView) = DashTerminalTextView.makeScrollView(
            identifier: "agent-dashboard-terminal",
            inset: NSSize(width: 14, height: 12)
        )
        terminalCard.addSubview(terminalScrollView)

        activityLabel.identifier = NSUserInterfaceItemIdentifier("agent-dashboard-activity-line")
        activityLabel.lineBreakMode = .byTruncatingTail
        activityLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        activityLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(activityMark)
        addSubview(activityLabel)

        addSubview(replyFieldView)
        replyField.identifier = NSUserInterfaceItemIdentifier("agent-dashboard-reply")
        replyField.isEditable = true
        replyField.isSelectable = true
        replyField.usesSingleLineMode = true
        replyField.cell?.isScrollable = true
        replyField.cell?.wraps = false
        replyField.delegate = self
        replyField.target = self
        replyField.action = #selector(sendClicked)
        replyField.onFocus = { [weak self] in
            guard let self else { return }
            self.replyFieldView.isFocused = true
            self.styleReplyField()
        }
        replyField.translatesAutoresizingMaskIntoConstraints = false
        replyFieldView.addSubview(replyField)

        sendButton.identifier = NSUserInterfaceItemIdentifier("agent-dashboard-send")
        sendButton.onClick = { [weak self] in self?.sendClicked() }
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        replyFieldView.addSubview(sendButton)
        activityMark.imageScaling = .scaleNone
        activityMark.translatesAutoresizingMaskIntoConstraints = false

        replyHintLabel.identifier = NSUserInterfaceItemIdentifier("agent-dashboard-reply-hint")
        replyHintLabel.font = Typography.ui(Typography.smallSize)
        replyHintLabel.lineBreakMode = .byTruncatingTail
        replyHintLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(replyHintLabel)

        // The composer keeps to the timeline's chat lane: the lane width, or
        // the gutters on a narrow window.
        let column = NSLayoutGuide()
        addLayoutGuide(column)
        let preferredColumnWidth = column.widthAnchor.constraint(equalToConstant: Self.readableWidth)
        // Just below the sidebar's preferred width, so a window too narrow for
        // both shrinks the column rather than the sidebar.
        preferredColumnWidth.priority = NSLayoutConstraint.Priority(rawValue: dashFillPriority.rawValue - 1)

        let gutter = Self.gutter
        NSLayoutConstraint.activate([
            statusMark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: gutter),
            statusMark.widthAnchor.constraint(equalToConstant: 16),
            statusMark.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: statusMark.trailingAnchor, constant: 10),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 18),

            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 10),
            statusLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            timerLabel.leadingAnchor.constraint(equalTo: statusLabel.trailingAnchor, constant: 10),
            timerLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            timerLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -gutter),

            locationLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            locationLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            locationLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -gutter),

            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: gutter),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -gutter),
            toolbar.topAnchor.constraint(equalTo: locationLabel.bottomAnchor, constant: 14),
            toolbar.heightAnchor.constraint(equalToConstant: ShellTextButton.height),

            contentRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentRule.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12),
            contentRule.heightAnchor.constraint(equalToConstant: 1),

            // The timeline centers its own chat lane across the full width.
            timelineView.leadingAnchor.constraint(equalTo: leadingAnchor),
            timelineView.trailingAnchor.constraint(equalTo: trailingAnchor),
            timelineView.topAnchor.constraint(equalTo: contentRule.bottomAnchor),
            timelineView.bottomAnchor.constraint(equalTo: activityLabel.topAnchor, constant: -12),

            // The terminal keeps the full width: its lines are as wide as the
            // agent's pane and wrap badly in the reading column.
            terminalCard.leadingAnchor.constraint(equalTo: leadingAnchor, constant: gutter),
            terminalCard.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -gutter),
            terminalCard.topAnchor.constraint(equalTo: contentRule.bottomAnchor, constant: 16),
            terminalCard.bottomAnchor.constraint(equalTo: activityLabel.topAnchor, constant: -16),
            terminalScrollView.leadingAnchor.constraint(equalTo: terminalCard.leadingAnchor, constant: 1),
            terminalScrollView.trailingAnchor.constraint(equalTo: terminalCard.trailingAnchor, constant: -1),
            terminalScrollView.topAnchor.constraint(equalTo: terminalCard.topAnchor, constant: 1),
            terminalScrollView.bottomAnchor.constraint(equalTo: terminalCard.bottomAnchor, constant: -1),

            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: Self.readableWidth),
            column.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -2 * gutter),
            preferredColumnWidth,

            activityMark.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 2),
            activityMark.centerYAnchor.constraint(equalTo: activityLabel.centerYAnchor),
            activityMark.widthAnchor.constraint(equalToConstant: 16),
            activityMark.heightAnchor.constraint(equalToConstant: 16),
            statusMark.heightAnchor.constraint(equalToConstant: 16),
            activityLabel.leadingAnchor.constraint(equalTo: activityMark.trailingAnchor, constant: 8),
            activityLabel.trailingAnchor.constraint(lessThanOrEqualTo: column.trailingAnchor),

            replyFieldView.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            replyFieldView.topAnchor.constraint(equalTo: activityLabel.bottomAnchor, constant: 8),
            replyFieldView.heightAnchor.constraint(equalToConstant: Self.replyFieldHeight),
            replyFieldView.trailingAnchor.constraint(equalTo: column.trailingAnchor),

            replyField.leadingAnchor.constraint(equalTo: replyFieldView.leadingAnchor, constant: 16),
            replyField.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -10),
            replyField.centerYAnchor.constraint(equalTo: replyFieldView.centerYAnchor),

            // Agents' round send button inside the composer card.
            sendButton.trailingAnchor.constraint(equalTo: replyFieldView.trailingAnchor, constant: -10),
            sendButton.centerYAnchor.constraint(equalTo: replyFieldView.centerYAnchor),

            replyHintLabel.leadingAnchor.constraint(equalTo: replyFieldView.leadingAnchor, constant: 2),
            replyHintLabel.trailingAnchor.constraint(lessThanOrEqualTo: column.trailingAnchor),
            replyHintLabel.topAnchor.constraint(equalTo: replyFieldView.bottomAnchor, constant: 6),
            replyHintLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    private func configureButton(
        _ button: NSButton,
        identifier: String,
        action: Selector
    ) {
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.target = self
        button.action = action
    }

    // MARK: - Content

    /// Shows the timeline or the live terminal and sets the toolbar to match.
    private func applyMode() {
        let timelineVisible = showsTimeline
        timelineView.isHidden = !timelineVisible
        terminalCard.isHidden = timelineVisible
        modeControl.select(timelineVisible ? 0 : 1)
        if timelineVisible {
            renderTimeline(scrollToEnd: true)
        } else {
            updateTerminalText()
        }
        updateActivity()
        updateControls()
    }

    /// Hands the transcript to the chat timeline as turns; the last one runs
    /// while the agent works. The timeline keeps following its newest row
    /// unless the person scrolled away (`scrollToEnd` forces it).
    private func renderTimeline(scrollToEnd: Bool = false) {
        guard showsTimeline else { return }
        transcriptSource.thread = timeline.map { ChatThread(transcript: $0, isRunning: isAgentWorking) } ?? ChatThread()
        transcriptSource.emptyText = entry == nil
            ? "Choose an agent to follow its work."
            : "Waiting for the agent's first message…"
        timelineView.reload(scrollToEnd: scrollToEnd)
    }

    /// Whether the newest turn is still going ("Working for", Thinking). An
    /// agent that waits on the person shows its turn finished, its question or
    /// last message as the answer.
    private var isAgentWorking: Bool {
        switch entry?.status {
        case .running?, .starting?: true
        default: false
        }
    }

    /// The composer's activity line: the agent's pill symbol, then what it is
    /// doing according to its transcript (`▶ Bash · swift test · 38s`), or its
    /// state in words when it writes none.
    private func updateActivity(now: Date = Date()) {
        let palette = PaletteCenter.shared.palette
        guard let entry else {
            activityMark.isHidden = true
            activityLabel.stringValue = ""
            return
        }
        let pill = self.pill(for: entry)
        activityMark.isHidden = false
        activityMark.image = NSImage.symbol(pill.symbol, size: 12)
        activityMark.contentTintColor = palette.color(for: pill.tone)
        let activity = AgentTimelineActivity.current(in: timeline, status: entry.status, now: now)
        let color = activity?.tone == .failed ? palette.errorForeground : palette.mutedForeground
        let line = activity.map {
            $0.attributed(
                font: Typography.ui(Typography.rowSize),
                titleFont: Typography.ui(Typography.rowSize, weight: .medium),
                codeFont: Typography.mono(Typography.smallSize),
                color: color,
                codeColor: activity?.tone == .failed ? palette.errorForeground : palette.foreground
            )
        } ?? NSAttributedString(string: fallbackActivity, attributes: [
            .font: Typography.ui(Typography.rowSize), .foregroundColor: color,
        ])
        guard activityLabel.attributedStringValue != line else { return }
        activityLabel.attributedStringValue = line
    }

    private var fallbackActivity: String {
        switch entry?.status {
        case .idle?: "Ready for a prompt"
        case .starting?: "Starting"
        case .running?: "Working"
        case .waiting?: "Waiting for input"
        case .error?: "Stopped with an error"
        case .stopped?: "Stopped"
        case nil: ""
        }
    }

    /// Why the selected agent waits; the entry does not carry it.
    var waitingReason: (AgentDashboardEntry) -> AgentWaitingReason? = { _ in nil }

    /// The Agents status pill for an entry; an idle agent reads Ready.
    private func pill(for entry: AgentDashboardEntry) -> ShellStatusPill {
        ShellStatusPill.of(status: entry.status, waitingReason: waitingReason(entry), workingSince: nil)
            ?? ShellStatusPill(label: "Ready", symbol: Icon.circleCheck, tone: .muted, since: nil)
    }

    /// Agents' chat header: the agent's task (14 pt semibold), its status
    /// pill and timer, over the location line `window / omp · folder`.
    private func refreshEntryLabels() {
        let palette = PaletteCenter.shared.palette
        titleLabel.attributedStringValue = NSAttributedString(string: entry?.title ?? "No agent selected", attributes: [
            .font: Typography.ui(Typography.bodySize, weight: .semibold),
            .foregroundColor: entry == nil ? palette.mutedForeground : palette.foreground,
        ])
        let meta = Typography.ui(Typography.smallSize)
        guard let entry else {
            statusMark.isHidden = true
            statusLabel.stringValue = ""
            timerLabel.stringValue = ""
            titleLabel.toolTip = nil
            locationLabel.attributedStringValue = NSAttributedString(string: "Choose an agent to follow its work.", attributes: [
                .font: meta, .foregroundColor: palette.mutedForeground,
            ])
            locationLabel.toolTip = nil
            setReplyPlaceholder(nil)
            return
        }

        let pill = pill(for: entry)
        let tint = palette.color(for: pill.tone)
        statusMark.isHidden = false
        statusMark.image = NSImage.symbol(pill.symbol, size: 12.5)
        statusMark.contentTintColor = tint
        statusLabel.attributedStringValue = NSAttributedString(string: pill.label, attributes: [
            .font: Typography.ui(Typography.smallSize, weight: .medium), .foregroundColor: tint,
        ])
        updateTimer()
        titleLabel.toolTip = entry.title

        let location = NSMutableAttributedString(string: "\(entry.windowTitle)  /  ", attributes: [
            .font: meta, .foregroundColor: palette.secondaryLabel,
        ])
        location.append(entry.context.attributed(font: meta, color: palette.secondaryLabel))
        locationLabel.attributedStringValue = location
        let path = entry.cwd.map { ($0 as NSString).abbreviatingWithTildeInPath }
        locationLabel.toolTip = [entry.location, path].compactMap { $0 }.joined(separator: "\n")
        setReplyPlaceholder("Reply to \(entry.profileName)…")
    }

    private func updateTimer(now: Date = Date()) {
        guard let entry else { return }
        let text = agentDashboardElapsedText(status: entry.status, startedAt: entry.startedAt, now: now)
        timerLabel.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: Typography.tabular(Typography.smallSize), .foregroundColor: PaletteCenter.shared.palette.secondaryLabel,
        ])
    }

    private func setReplyPlaceholder(_ placeholder: String?) {
        replyField.placeholderAttributedString = placeholder.map {
            NSAttributedString(string: $0, attributes: [
                .font: Typography.ui(Typography.bodySize), .foregroundColor: PaletteCenter.shared.palette.placeholder,
            ])
        }
    }

    private func updateTerminalText() {
        guard terminalTextView != nil else { return }
        let displayText: String
        if entry == nil {
            displayText = "Select an agent to see its current terminal."
        } else if !terminal.isAvailable {
            displayText = "This terminal is not currently available."
        } else if terminal.visibleText.isEmpty {
            displayText = "No terminal output yet."
        } else {
            displayText = terminal.visibleText
        }

        let textChanged = terminalTextView.string != displayText
        let attributedText: NSAttributedString
        if terminal.isAvailable, !terminal.visibleText.isEmpty {
            attributedText = AgentOutputHighlighter.highlight(displayText, theme: theme, font: Typography.mono())
        } else {
            attributedText = NSAttributedString(
                string: displayText,
                attributes: [
                    .font: Typography.ui(Typography.rowSize),
                    .foregroundColor: PaletteCenter.shared.palette.mutedForeground,
                ]
            )
        }
        terminalTextView.textStorage?.setAttributedString(attributedText)
        if textChanged {
            terminalTextView.scrollRangeToVisible(
                NSRange(location: displayText.utf16.count, length: 0)
            )
        }
    }

    /// Agents' composer field: borderless 14 pt ink on the composer card,
    /// with an ink caret and the palette's selection while it edits.
    private func styleReplyField() {
        let palette = PaletteCenter.shared.palette
        replyField.isBordered = false
        replyField.isBezeled = false
        replyField.drawsBackground = false
        replyField.focusRingType = .none
        replyField.font = Typography.ui(Typography.bodySize)
        replyField.textColor = palette.foreground
        guard let editor = replyField.currentEditor() as? NSTextView else { return }
        editor.insertionPointColor = palette.foreground
        editor.selectedTextAttributes = [
            .backgroundColor: palette.primary.withAlphaComponent(palette.isDark ? 0.45 : 0.22),
        ]
    }

    private func updateControls() {
        replyHintLabel.textColor = PaletteCenter.shared.palette.mutedForeground
        modeControl.setEnabled(hasTranscript || entry?.isChat == true, forSegment: 0)
        modeControl.setEnabled(entry?.isChat != true, forSegment: 1)
        detailsButton.isEnabled = showsTimeline
        guard let entry else {
            openButton.isEnabled = false
            stopButton.isEnabled = false
            restartButton.isEnabled = false
            replyField.isEnabled = false
            replyHintLabel.stringValue = ""
            updateSendButton()
            return
        }

        openButton.isEnabled = true
        stopButton.isEnabled = entry.status != .stopped
        restartButton.isEnabled = entry.status != .starting
        replyField.isEnabled = canReply

        if !terminal.isAvailable {
            replyHintLabel.stringValue = entry.isChat
                ? "Restart the agent before replying."
                : "Open the agent to initialize its terminal."
        } else {
            switch entry.status {
            case .starting:
                replyHintLabel.stringValue = "Waiting for the agent to become ready."
            case .stopped:
                replyHintLabel.stringValue = "Restart the agent before replying."
            case .running, .idle, .waiting, .error:
                replyHintLabel.stringValue = "Press Return to send this single-line reply."
            }
        }
        updateSendButton()
    }

    private var canReply: Bool {
        guard terminal.isAvailable, let status = entry?.status else { return false }
        switch status {
        case .running, .idle, .waiting, .error:
            return true
        case .starting, .stopped:
            return false
        }
    }

    private func updateSendButton() {
        let canSend = canReply
            && !replyField.stringValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        sendButton.update(canSend ? .send : .sendDisabled, tooltip: "Send")
    }

    private var target: TerminalTarget? {
        entry.map { TerminalTarget(paneId: $0.paneId, tabId: $0.tabId) }
    }

    @objc private func openClicked() {
        guard let target else { return }
        onOpen?(target)
    }

    @objc private func stopClicked() {
        guard let target else { return }
        onStop?(target)
    }

    @objc private func restartClicked() {
        guard let target else { return }
        onRestart?(target)
    }

    @objc private func modeChanged(_ sender: ShellSegmentedControl) {
        setPrefersTerminal(sender.selectedSegment == 1)
    }

    @objc private func detailsClicked() {
        toggleDetails()
    }

    @objc private func sendClicked() {
        guard canReply, let target else { return }
        let prompt = replyField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }

        if onSend?(target, prompt) == true {
            replyField.stringValue = ""
            updateSendButton()
        } else {
            replyHintLabel.stringValue = "Could not send to this terminal."
            replyHintLabel.textColor = PaletteCenter.shared.palette.errorForeground
        }
    }
}

/// The reply field; reports when it takes the keyboard so its field surface
/// can show the focus edge.
private final class AgentDashboardReplyField: NSTextField {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onFocus?()
        }
        return accepted
    }
}

/// A sidebar section heading, `NEEDS YOU 2`: the eyebrow and a muted count,
/// lined up with the rows' status marks.
private final class AgentDashboardSectionHeaderView: NSView {
    private static let height: CGFloat = 32

    let section: AgentDashboardSection
    private let theme: AppTheme
    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private var count: Int?

    init(section: AgentDashboardSection, theme: AppTheme) {
        self.section = section
        self.theme = theme
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("agent-dashboard-section")
        translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.attributedStringValue = NSAttributedString(string: section.title, attributes: [
            .font: Typography.ui(Typography.rowSize, weight: .semibold),
            .foregroundColor: PaletteCenter.shared.palette.sidebarMutedForeground,
        ])
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        countLabel.identifier = NSUserInterfaceItemIdentifier("agent-dashboard-section-count")
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(countLabel)
        // Agents' section header: "Working  3", the title at the cards'
        // content edge and the count muted after it.
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ShellSidebarMetrics.contentLeft),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            countLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6),
            countLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            countLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -ShellSidebarMetrics.contentLeft),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(count: Int) {
        guard count != self.count else { return }
        self.count = count
        countLabel.attributedStringValue = NSAttributedString(string: "\(count)", attributes: [
            .font: Typography.tabular(Typography.smallSize),
            .foregroundColor: PaletteCenter.shared.palette.sidebarMutedForeground,
        ])
        setAccessibilityLabel("\(section.title), \(count)")
    }
}

/// A row of muted key hints: caps (`J` `K`) and a muted word each. When the
/// row does not fit, the last hints give way first.
private final class AgentDashboardHintsView: NSStackView {
    private let hints: [(caps: [String], label: String)]
    private var theme: AppTheme

    init(hints: [(caps: [String], label: String)], spacing: CGFloat, theme: AppTheme) {
        self.hints = hints
        self.theme = theme
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        self.spacing = spacing
        translatesAutoresizingMaskIntoConstraints = false
        // Holds its full width until the footer is too narrow; then the
        // visibility priorities drop hints rather than clip one. Below
        // `.windowSizeStayPut`, so the hints never widen the window.
        setHuggingPriority(.defaultLow, for: .horizontal)
        setClippingResistancePriority(dashFillPriority, for: .horizontal)
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        rebuild()
    }

    private func rebuild() {
        for view in views {
            removeView(view)
        }
        for (index, hint) in hints.enumerated() {
            // Agents' `KbdView` chips, one per key, then a muted label.
            let caps = NSStackView(views: hint.caps.map { KbdView($0) })
            caps.orientation = .horizontal
            caps.spacing = 3
            let label = NSTextField.label(hint.label, size: Typography.smallSize)
            label.textColor = PaletteCenter.shared.palette.mutedForeground
            let item = NSStackView(views: [caps, label])
            item.orientation = .horizontal
            item.alignment = .centerY
            item.spacing = 5
            item.setHuggingPriority(.required, for: .horizontal)
            addView(item, in: .leading)
            if index > 0 {
                setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: Float(900 - index)), for: item)
            }
        }
    }
}

/// One agent: 52 pt, two lines, named the way the sidebar names it. Mark,
/// the agent's task (or its name before it has one), the running time and
/// the status word; under it `omp · folder · ⎇ branch` and then what the
/// agent is doing. The selected row is the pill (with the pencil tick while
/// the list has the keyboard); a row that needs you gets the full-bleed
/// attention wash.
private final class AgentDashboardRowView: NSControl {
    private static let height: CGFloat = 52

    private(set) var entry: AgentDashboardEntry
    var onSelect: (() -> Void)?
    var onOpen: (() -> Void)?
    var isListFocused = false {
        didSet {
            guard isListFocused != oldValue, isKeyboardSelected else { return }
            needsDisplay = true
        }
    }

    private let theme: AppTheme
    private let monogram = ShellMonogramView()
    private let statusIcon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let elapsedLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let activityLabel = NSTextField(labelWithString: "")
    private var activity: AgentTimelineActivity?
    private var isHovered = false
    private var isKeyboardSelected = false
    /// Why a waiting agent waits; the entry does not carry it.
    private let waitingReason: (AgentDashboardEntry) -> AgentWaitingReason?

    init(
        entry: AgentDashboardEntry,
        theme: AppTheme,
        waitingReason: @escaping (AgentDashboardEntry) -> AgentWaitingReason?
    ) {
        self.entry = entry
        self.theme = theme
        self.waitingReason = waitingReason
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("agent-dashboard-row")
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        build()
        render(previous: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for trackingArea in trackingAreas {
            removeTrackingArea(trackingArea)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0 else { return }
        if event.clickCount >= 2 {
            onOpen?()
        } else {
            onSelect?()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 {
            onOpen?()
        } else if event.charactersIgnoringModifiers == " " {
            onSelect?()
        } else {
            super.keyDown(with: event)
        }
    }

    /// Agents' card surface: `sidebarRowActive` for the keyboard selection
    /// (`sidebarRowSelected` while the list does not have the keyboard), a
    /// soft warning wash for a row that needs you, `sidebarRowHover` under
    /// the pointer; rounded and inset like the sidebar's cards.
    override func draw(_ dirtyRect: NSRect) {
        let palette = PaletteCenter.shared.palette
        let fill: NSColor? = switch selectionStyle {
        case .selected: palette.sidebarRowActive
        case .selectedUnfocused: palette.sidebarRowSelected
        case .attention: palette.color(for: .approval).shellScaled(by: 0.10)
        case .hover: palette.sidebarRowHover
        default: nil
        }
        guard let fill else { return }
        let rect = bounds.insetBy(dx: ShellSidebarMetrics.contentInset, dy: 2)
        fill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: Radius.md, yRadius: Radius.md).fill()
        if selectionStyle == .selected, !palette.isDark {
            palette.sidebarBorder.shellScaled(by: 0.7).setStroke()
            let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: Radius.md, yRadius: Radius.md)
            ring.lineWidth = 1
            ring.stroke()
        }
    }

    private enum SelectionStyle {
        case none, hover, attention, selected, selectedUnfocused
    }

    private var selectionStyle: SelectionStyle {
        if isKeyboardSelected { return isListFocused ? .selected : .selectedUnfocused }
        if entry.needsAttention { return .attention }
        return isHovered ? .hover : .none
    }

    /// Shows `entry` in this row; an unchanged entry leaves the row untouched.
    func update(entry: AgentDashboardEntry) {
        guard entry != self.entry else { return }
        let previous = self.entry
        self.entry = entry
        render(previous: previous)
    }

    func updateElapsed(now: Date) {
        let text = agentDashboardElapsedText(status: entry.status, startedAt: entry.startedAt, now: now)
        guard elapsedLabel.stringValue != text else { return }
        elapsedLabel.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: Typography.tabular(Typography.smallSize),
            .foregroundColor: PaletteCenter.shared.palette.secondaryLabel,
        ])
    }

    /// Shows what the agent is doing according to its transcript after its
    /// context on the second line.
    func updateActivity(_ activity: AgentTimelineActivity?) {
        guard activity != self.activity else { return }
        self.activity = activity
        renderActivity()
    }

    func setKeyboardSelected(_ isSelected: Bool) {
        guard isKeyboardSelected != isSelected else { return }
        isKeyboardSelected = isSelected
        setAccessibilitySelected(isSelected)
        needsDisplay = true
    }

    private func build() {
        addSubview(monogram)
        statusIcon.imageScaling = .scaleNone
        addSubview(statusIcon)
        for view in [monogram, statusIcon] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }

        titleLabel.identifier = NSUserInterfaceItemIdentifier("agent-dashboard-title")
        elapsedLabel.identifier = NSUserInterfaceItemIdentifier("agent-dashboard-elapsed")
        statusLabel.identifier = NSUserInterfaceItemIdentifier("agent-dashboard-status")
        activityLabel.identifier = NSUserInterfaceItemIdentifier("agent-dashboard-activity")
        for label in [titleLabel, elapsedLabel, statusLabel, activityLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.cell?.wraps = false
            label.cell?.isScrollable = false
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        activityLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for label in [elapsedLabel, statusLabel] {
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            label.setContentHuggingPriority(.required, for: .horizontal)
        }

        // Two lines centered in the 52 pt card: monogram, title (14 pt
        // medium) and the status pill, then the context and activity.
        let firstLine: CGFloat = 17.5
        let secondLine: CGFloat = 35.5
        let left = ShellSidebarMetrics.contentLeft
        NSLayoutConstraint.activate([
            monogram.leadingAnchor.constraint(equalTo: leadingAnchor, constant: left),
            monogram.centerYAnchor.constraint(equalTo: topAnchor, constant: firstLine),
            monogram.widthAnchor.constraint(equalToConstant: 16),
            monogram.heightAnchor.constraint(equalToConstant: 16),

            titleLabel.leadingAnchor.constraint(equalTo: monogram.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: topAnchor, constant: firstLine),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: elapsedLabel.leadingAnchor, constant: -8),

            elapsedLabel.trailingAnchor.constraint(equalTo: statusIcon.leadingAnchor, constant: -8),
            elapsedLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            statusIcon.trailingAnchor.constraint(equalTo: statusLabel.leadingAnchor, constant: -2),
            statusIcon.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            statusIcon.widthAnchor.constraint(equalToConstant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -left),
            statusLabel.centerYAnchor.constraint(equalTo: topAnchor, constant: firstLine),

            activityLabel.leadingAnchor.constraint(equalTo: monogram.leadingAnchor),
            activityLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusLabel.trailingAnchor),
            activityLabel.centerYAnchor.constraint(equalTo: topAnchor, constant: secondLine),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    /// Redraws what depends on fields that differ from `previous`, or the
    /// whole row when there is none. A busy agent retitles its tab several
    /// times a second, mostly with a new spinner frame its title drops, so
    /// the labels are set only when what they show changed.
    private func render(previous: AgentDashboardEntry?) {
        let palette = PaletteCenter.shared.palette
        let statusChanged = previous?.status != entry.status
            || previous?.needsAttention != entry.needsAttention
        if statusChanged {
            let pill = ShellStatusPill.of(status: entry.status, waitingReason: waitingReason(entry), workingSince: nil)
                ?? ShellStatusPill(label: "Ready", symbol: Icon.circleCheck, tone: .muted, since: nil)
            let tint = palette.color(for: pill.tone)
            statusIcon.image = NSImage.symbol(pill.symbol, size: 12.5)
            statusIcon.contentTintColor = tint
            statusLabel.attributedStringValue = NSAttributedString(string: pill.label, attributes: [
                .font: Typography.ui(Typography.smallSize, weight: .medium),
                .foregroundColor: tint,
            ])
            needsDisplay = true
        }
        if statusChanged || previous?.startedAt != entry.startedAt {
            updateElapsed(now: Date())
        }
        let folder = entry.cwd.map { TerminalTitle.folderName($0) }
        monogram.projectName = folder ?? entry.profileName
        let title = entry.title
        if previous?.title != title {
            // An attributed string without a paragraph style wraps by word,
            // overriding the label's truncation; keep the title on one line.
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            titleLabel.attributedStringValue = NSAttributedString(string: title, attributes: [
                .font: Typography.ui(Typography.bodySize, weight: .medium),
                .foregroundColor: palette.sidebarForeground,
                .paragraphStyle: paragraph,
            ])
        }
        let context = entry.context
        if previous?.context != context {
            renderActivity()
        }

        let location = entry.location
        let path = entry.cwd.map { ($0 as NSString).abbreviatingWithTildeInPath }
        let agentDescription = [entry.profileName, entry.sessionName]
            .compactMap { $0 }.joined(separator: " · ")
        toolTip = [title, agentDescription, location, path, "Double-click to open agent"]
            .compactMap { $0 }.joined(separator: "\n")
        setAccessibilityLabel(
            "\(title), \(entry.profileName), \(entry.status.displayLabel), \(location)"
        )
    }

    /// `omp · folder · ⎇ branch — Bash · swift test`: the context, then after
    /// a dash what the agent is doing, all muted like a sidebar row's second
    /// line (the subject in mono), or the activity in the danger color when
    /// it failed. The composer's activity line keeps the subject in ink.
    private func renderActivity() {
        let palette = PaletteCenter.shared.palette
        let meta = Typography.ui(Typography.smallSize)
        let line = NSMutableAttributedString(
            attributedString: entry.context.attributed(font: meta, color: palette.secondaryLabel)
        )
        if let activity {
            let color = activity.tone == .failed ? palette.errorForeground : palette.secondaryLabel
            if line.length > 0 {
                line.append(NSAttributedString(string: " — ", attributes: [.font: meta, .foregroundColor: palette.secondaryLabel]))
            }
            line.append(activity.attributed(
                font: meta,
                titleFont: meta,
                codeFont: Typography.mono(Typography.tinySize),
                color: color,
                codeColor: color,
                compact: true
            ))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        line.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: line.length))
        activityLabel.attributedStringValue = line
    }
}

private final class AgentDashboardFlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class AgentDashboardRootView: NSView {
    var onEscape: (() -> Void)?
    var onMoveSelection: ((Int) -> Void)?
    var onActivateSelection: (() -> Void)?
    var onFocusReply: (() -> Void)?
    var onScroll: ((AgentDashboardScroll) -> Void)?
    var onJumpTurn: ((Int) -> Void)?
    var onToggleDetails: (() -> Void)?
    var onFollowLatest: (() -> Void)?
    var onToggleTerminal: (() -> Void)?
    /// Whether the dashboard itself, which drives the agent list, has the
    /// keyboard.
    var onFocusChange: ((Bool) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onFocusChange?(true)
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            onFocusChange?(false)
        }
        return resigned
    }

    /// Runs the dashboard shortcut `event` stands for; false when it is none.
    /// The detail text views forward their keys here as well.
    func handleKey(_ event: NSEvent) -> Bool {
        guard let action = keyboardAction(for: event) else { return false }
        perform(action)
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleKey(event) || super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if !handleKey(event) {
            super.keyDown(with: event)
        }
    }

    private enum KeyboardAction {
        case dismiss
        case move(Int)
        case activate
        case focusReply
        case scroll(AgentDashboardScroll)
        case jumpTurn(Int)
        case toggleDetails
        case followLatest
        case toggleTerminal
    }

    private func keyboardAction(for event: NSEvent) -> KeyboardAction? {
        guard event.type == .keyDown else { return nil }
        if let editor = window?.firstResponder as? NSTextView,
           editor.isFieldEditor
        {
            return event.keyCode == 53 ? .dismiss : nil
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.command),
              !flags.contains(.control),
              !flags.contains(.option)
        else { return nil }

        switch event.keyCode {
        case 53:
            return .dismiss
        case 125:
            return .move(1)
        case 126:
            return .move(-1)
        case 36, 76:
            return .activate
        case 48:
            // ⇧Tab leaves the reply field through its delegate instead.
            return flags.contains(.shift) ? nil : .focusReply
        case 121:
            return .scroll(.pages(1))
        case 116:
            return .scroll(.pages(-1))
        default:
            break
        }

        // Shift turns J/K from moving between agents into scrolling the timeline.
        let shifted = flags.contains(.shift)
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "j":
            return shifted ? .scroll(.lines(1)) : .move(1)
        case "k":
            return shifted ? .scroll(.lines(-1)) : .move(-1)
        case "r":
            return .focusReply
        case " ":
            return .activate
        case "]":
            return .jumpTurn(1)
        case "[":
            return .jumpTurn(-1)
        case "o":
            return .toggleDetails
        case "g":
            return .followLatest
        case "t":
            return .toggleTerminal
        default:
            return nil
        }
    }

    private func perform(_ action: KeyboardAction) {
        switch action {
        case .dismiss:
            onEscape?()
        case .move(let delta):
            onMoveSelection?(delta)
        case .activate:
            onActivateSelection?()
        case .focusReply:
            onFocusReply?()
        case .scroll(let amount):
            onScroll?(amount)
        case .jumpTurn(let direction):
            onJumpTurn?(direction)
        case .toggleDetails:
            onToggleDetails?()
        case .followLatest:
            onFollowLatest?()
        case .toggleTerminal:
            onToggleTerminal?()
        }
    }
}
