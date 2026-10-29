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
    private var headerView: SettingsHeaderView!
    private var listPanel: NSView!
    private var listRule: ChromeRuleView!
    private var keyHintsView: AgentDashboardHintsView!
    private var keyHintsRule: ChromeRuleView!
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
        let colors = theme.colors
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
        root.layer?.backgroundColor = colors.bgBase.cgColor

        headerView = SettingsHeaderView(title: "Agent Dashboard", theme: theme)
        headerView.onClose = { [weak self] in
            self?.onDismiss?()
        }
        root.addSubview(headerView)

        listPanel = makeAgentListPanel(theme: theme)
        root.addSubview(listPanel)

        detailView = AgentDashboardDetailView(theme: theme)
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
        preferredListWidth.priority = Chrome.fillPriority
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
        let colors = theme.colors
        view.layer?.backgroundColor = colors.bgBase.cgColor
        headerView.apply(theme: theme)
        listPanel.layer?.backgroundColor = colors.bgPanel.cgColor
        listRule.color = colors.borderSubtle
        keyHintsRule.color = colors.borderSubtle
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
        let row = AgentDashboardRowView(entry: entry, theme: theme)
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
        let colors = theme.colors
        let panel = NSView()
        panel.identifier = NSUserInterfaceItemIdentifier("agent-dashboard-list")
        panel.wantsLayer = true
        panel.layer?.backgroundColor = colors.bgPanel.cgColor
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

        keyHintsRule = ChromeRuleView(axis: .horizontal, color: colors.borderSubtle)
        panel.addSubview(keyHintsRule)

        keyHintsView = AgentDashboardHintsView(
            hints: [(["J", "K"], "Select"), (["↵"], "Open"), (["Tab"], "Reply"), (["T"], "Terminal")],
            spacing: 14,
            theme: theme
        )
        keyHintsView.identifier = NSUserInterfaceItemIdentifier("agent-dashboard-key-hints")
        panel.addSubview(keyHintsView)

        listRule = ChromeRuleView(axis: .vertical, color: colors.borderSubtle)
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

            keyHintsView.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: Chrome.pillInset + 14),
            keyHintsView.trailingAnchor.constraint(lessThanOrEqualTo: listRule.leadingAnchor, constant: -Chrome.Space.s12),
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
        title.setChromeText(titleText, font: ChromeFont.empty, color: theme.colors.textMuted)
        title.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(title)

        let detailText = "Launch an agent from the sidebar or command palette."
        let detail = NSTextField(wrappingLabelWithString: detailText)
        detail.alignment = .center
        detail.lineBreakMode = .byWordWrapping
        detail.setChromeText(detailText, font: ChromeFont.meta, color: theme.colors.textMuted)
        detail.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(detail)

        let inset = Chrome.Space.s16
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

/// The selected agent: its title and context over a toolbar (Timeline or
/// Terminal, details, Open / Stop / Restart), then its conversation in a
/// readable column — or its live terminal in a card — and at the bottom a
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
            timelineTextView.keyHandler = keyHandler
            terminalTextView.keyHandler = keyHandler
        }
    }

    private static let gutter = Chrome.Space.page
    /// The conversation and the composer keep to this width, centered.
    private static let readableWidth: CGFloat = 760
    private static let replyFieldHeight: CGFloat = 32

    private var theme: AppTheme
    private var entry: AgentDashboardEntry?
    private var terminal = TerminalInteractionState.unavailable
    private var timeline: AgentTimeline?
    private var hasTranscript = false
    /// Set with T; applies to every agent until switched back.
    private var prefersTerminal = false
    private var isDetailed = false
    /// Whether the timeline sticks to its newest entry as entries arrive.
    private var isFollowing = true
    private var turnStarts: [Int] = []
    private let timelineRenderer: AgentTimelineRenderer

    private let statusMark = ChromeStatusMark()
    private let titleLabel = NSTextField(labelWithString: "No agent selected")
    private let statusLabel = NSTextField(labelWithString: "")
    private let timerLabel = NSTextField(labelWithString: "")
    private let locationLabel = NSTextField(labelWithString: "")
    private let modeControl: ChromeSegmentedControl
    private let detailsButton: ChromeButton
    private let openButton: ChromeButton
    private let stopButton: ChromeButton
    private let restartButton: ChromeButton
    private let toolbar = NSStackView()
    private let contentRule: ChromeRuleView
    private var terminalCard: NSView!
    private var terminalScrollView: NSScrollView!
    private var terminalTextView: AgentDashboardTextView!
    private var timelineScrollView: NSScrollView!
    private var timelineTextView: AgentDashboardTextView!
    private let jumpButton: ChromeButton
    private let composerRule: ChromeRuleView
    private let activityMark = ChromeStatusMark()
    private let activityLabel = NSTextField(labelWithString: "")
    private let replyFieldView: ChromeFieldView
    private let replyField = AgentDashboardReplyField()
    private let sendButton: ChromeButton
    private let replyHintLabel = NSTextField(labelWithString: "")

    /// Whether the selected agent shows its live terminal instead of its
    /// timeline: agents without a readable transcript, or after T.
    var isShowingTerminal: Bool { !showsTimeline }

    private var showsTimeline: Bool { hasTranscript && !prefersTerminal }

    init(theme: AppTheme) {
        self.theme = theme
        timelineRenderer = AgentTimelineRenderer(colors: theme.colors)
        modeControl = ChromeSegmentedControl(titles: ["Timeline", "Terminal"], theme: theme)
        detailsButton = ChromeButton(title: "Show details", theme: theme, keycap: "O")
        openButton = ChromeButton(title: "Open", theme: theme, keycap: "↵")
        stopButton = ChromeButton(title: "Stop", theme: theme)
        restartButton = ChromeButton(title: "Restart", theme: theme)
        jumpButton = ChromeButton(title: "Jump to latest", theme: theme, keycap: "G")
        sendButton = ChromeButton(title: "Send", theme: theme, kind: .ink)
        contentRule = ChromeRuleView(axis: .horizontal, color: theme.colors.borderSubtle)
        composerRule = ChromeRuleView(axis: .horizontal, color: theme.colors.borderSubtle)
        replyFieldView = ChromeFieldView(theme: theme)
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
        let colors = theme.colors
        refreshEntryLabels()
        contentRule.color = colors.borderSubtle
        composerRule.color = colors.borderSubtle
        modeControl.apply(theme: theme)
        replyFieldView.apply(theme: theme)
        timelineScrollView.backgroundColor = colors.bgBase
        timelineTextView.backgroundColor = colors.bgBase
        // The live terminal sits in a card on the panel surface, so it reads
        // as a terminal shown inside the page rather than as the page.
        terminalCard.layer?.backgroundColor = colors.bgPanel.cgColor
        terminalCard.layer?.borderColor = colors.borderSubtle.cgColor
        terminalScrollView.backgroundColor = colors.bgPanel
        terminalTextView.backgroundColor = colors.bgPanel
        for textView in [terminalTextView!, timelineTextView!] {
            textView.insertionPointColor = colors.caret
            textView.selectedTextAttributes = [.backgroundColor: colors.textSelection]
        }
        // NSTextView draws links with these instead of the renderer's own.
        timelineTextView.linkTextAttributes = [
            .foregroundColor: colors.blue,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        ChromeFieldView.styleEmbedded(replyField, colors: colors, font: ChromeFont.row)
        ChromeFieldView.styleEditor(of: replyField, colors: colors)
        setReplyPlaceholder(replyField.placeholderAttributedString?.string)
        [detailsButton, openButton, stopButton, restartButton, jumpButton, sendButton].forEach {
            $0.apply(theme: theme)
        }
        // The jump button floats over the conversation with e2 elevation; its
        // drawn pill casts the shadow, so no layer ring.
        let shadow = colors.shadowE2
        jumpButton.layer?.shadowColor = shadow.color.cgColor
        jumpButton.layer?.shadowOpacity = shadow.opacity
        jumpButton.layer?.shadowRadius = shadow.blur / 2
        jumpButton.layer?.shadowOffset = CGSize(width: 0, height: -shadow.offsetY)
        timelineRenderer.apply(colors: colors)
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
        let modeChanged = hasTranscript != self.hasTranscript
        if selectionChanged {
            replyField.stringValue = ""
            isFollowing = true
        }
        self.entry = entry
        self.terminal = terminal
        self.timeline = timeline
        self.hasTranscript = hasTranscript
        refreshEntryLabels()
        if modeChanged {
            applyMode()
        } else if showsTimeline {
            if timelineChanged { renderTimeline() }
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
        let scrollView: NSScrollView = showsTimeline ? timelineScrollView : terminalScrollView
        let clip = scrollView.contentView
        let delta: CGFloat
        switch amount {
        case .lines(let count):
            delta = CGFloat(count) * 48
        case .pages(let count):
            delta = CGFloat(count) * max(clip.bounds.height - 40, 48)
        }
        scroll(scrollView, toY: clip.bounds.minY + delta)
    }

    /// Scrolls the next (`direction` > 0) or previous prompt to the top.
    func jumpToTurn(_ direction: Int) {
        guard showsTimeline, !turnStarts.isEmpty,
              let layoutManager = timelineTextView.layoutManager,
              let container = timelineTextView.textContainer
        else { return }
        layoutManager.ensureLayout(for: container)
        let length = timelineTextView.textStorage?.length ?? 0
        let originY = timelineTextView.textContainerOrigin.y
        let tops = turnStarts.filter { $0 < length }.map { start in
            layoutManager.lineFragmentRect(
                forGlyphAt: layoutManager.glyphIndexForCharacter(at: start),
                effectiveRange: nil
            ).minY + originY
        }
        let current = timelineScrollView.contentView.bounds.minY
        let target = direction > 0
            ? tops.first { $0 > current + 8 }
            : tops.last { $0 < current - 8 }
        if let target {
            scroll(timelineScrollView, toY: target - 8)
        } else if direction > 0 {
            followLatest()
        } else {
            scroll(timelineScrollView, toY: 0)
        }
    }

    func toggleDetails() {
        guard showsTimeline else { return }
        isDetailed.toggle()
        detailsButton.title = isDetailed ? "Hide details" : "Show details"
        renderTimeline()
    }

    func followLatest() {
        if showsTimeline {
            scrollTimelineToEnd()
        } else {
            let length = terminalTextView.textStorage?.length ?? 0
            terminalTextView.scrollRangeToVisible(NSRange(location: length, length: 0))
        }
    }

    func toggleTerminal() {
        setPrefersTerminal(!prefersTerminal)
    }

    private func setPrefersTerminal(_ prefers: Bool) {
        guard hasTranscript, prefers != prefersTerminal else { return }
        prefersTerminal = prefers
        applyMode()
        if prefersTerminal {
            onTerminalShown?()
        }
    }

    // MARK: - Layout

    private func build() {
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
        toolbar.spacing = Chrome.Space.s8
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

        addSubview(contentRule)

        (timelineScrollView, timelineTextView) = Self.makeTextScrollView(
            identifier: "agent-dashboard-timeline",
            inset: NSSize(width: Self.gutter, height: 20)
        )
        timelineTextView.minimumInset = Self.gutter
        timelineTextView.readableWidth = Self.readableWidth
        addSubview(timelineScrollView)
        timelineScrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(timelineDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: timelineScrollView.contentView
        )

        terminalCard = NSView()
        terminalCard.identifier = NSUserInterfaceItemIdentifier("agent-dashboard-terminal-card")
        terminalCard.wantsLayer = true
        terminalCard.layer?.cornerRadius = Chrome.Radius.card
        terminalCard.layer?.borderWidth = Chrome.hairline
        terminalCard.layer?.masksToBounds = true
        terminalCard.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminalCard)
        (terminalScrollView, terminalTextView) = Self.makeTextScrollView(
            identifier: "agent-dashboard-terminal",
            inset: NSSize(width: 16, height: 14)
        )
        terminalCard.addSubview(terminalScrollView)

        configureButton(jumpButton, identifier: "agent-dashboard-jump", action: #selector(jumpClicked))
        jumpButton.toolTip = "Scroll to the newest entry and keep following it (G)"
        jumpButton.wantsLayer = true
        jumpButton.layer?.masksToBounds = false
        addSubview(jumpButton)

        addSubview(composerRule)

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
            ChromeFieldView.styleEditor(of: self.replyField, colors: self.theme.colors)
        }
        replyField.translatesAutoresizingMaskIntoConstraints = false
        replyFieldView.addSubview(replyField)

        configureButton(sendButton, identifier: "agent-dashboard-send", action: #selector(sendClicked))
        addSubview(sendButton)

        replyHintLabel.identifier = NSUserInterfaceItemIdentifier("agent-dashboard-reply-hint")
        replyHintLabel.font = ChromeFont.meta
        replyHintLabel.lineBreakMode = .byTruncatingTail
        replyHintLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(replyHintLabel)

        // The composer keeps to the conversation's column: the readable width,
        // or the gutters on a narrow window.
        let column = NSLayoutGuide()
        addLayoutGuide(column)
        let preferredColumnWidth = column.widthAnchor.constraint(equalToConstant: Self.readableWidth)
        // Just below the sidebar's preferred width, so a window too narrow for
        // both shrinks the column rather than the sidebar.
        preferredColumnWidth.priority = NSLayoutConstraint.Priority(rawValue: Chrome.fillPriority.rawValue - 1)

        let gutter = Self.gutter
        NSLayoutConstraint.activate([
            statusMark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: gutter),
            statusMark.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: statusMark.trailingAnchor, constant: 10),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 18),

            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 10),
            statusLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            timerLabel.leadingAnchor.constraint(equalTo: statusLabel.trailingAnchor, constant: 10),
            timerLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            timerLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -gutter),

            locationLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: gutter + 18),
            locationLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            locationLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -gutter),

            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: gutter),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -gutter),
            toolbar.topAnchor.constraint(equalTo: locationLabel.bottomAnchor, constant: 14),
            toolbar.heightAnchor.constraint(equalToConstant: Chrome.fieldHeight),

            contentRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentRule.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12),

            timelineScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            timelineScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            timelineScrollView.topAnchor.constraint(equalTo: contentRule.bottomAnchor),
            timelineScrollView.bottomAnchor.constraint(equalTo: composerRule.topAnchor),

            // The terminal keeps the full width: its lines are as wide as the
            // agent's pane and wrap badly in the reading column.
            terminalCard.leadingAnchor.constraint(equalTo: leadingAnchor, constant: gutter),
            terminalCard.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -gutter),
            terminalCard.topAnchor.constraint(equalTo: contentRule.bottomAnchor, constant: Chrome.Space.s16),
            terminalCard.bottomAnchor.constraint(equalTo: composerRule.topAnchor, constant: -Chrome.Space.s16),
            terminalScrollView.leadingAnchor.constraint(equalTo: terminalCard.leadingAnchor, constant: Chrome.hairline),
            terminalScrollView.trailingAnchor.constraint(equalTo: terminalCard.trailingAnchor, constant: -Chrome.hairline),
            terminalScrollView.topAnchor.constraint(equalTo: terminalCard.topAnchor, constant: Chrome.hairline),
            terminalScrollView.bottomAnchor.constraint(equalTo: terminalCard.bottomAnchor, constant: -Chrome.hairline),

            jumpButton.centerXAnchor.constraint(equalTo: timelineScrollView.centerXAnchor),
            jumpButton.bottomAnchor.constraint(equalTo: composerRule.topAnchor, constant: -Chrome.Space.s12),

            composerRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            composerRule.trailingAnchor.constraint(equalTo: trailingAnchor),

            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: Self.readableWidth),
            column.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -2 * gutter),
            preferredColumnWidth,

            activityMark.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 2),
            activityMark.centerYAnchor.constraint(equalTo: activityLabel.centerYAnchor),
            activityLabel.leadingAnchor.constraint(equalTo: activityMark.trailingAnchor, constant: 8),
            activityLabel.trailingAnchor.constraint(lessThanOrEqualTo: column.trailingAnchor),
            activityLabel.topAnchor.constraint(equalTo: composerRule.bottomAnchor, constant: Chrome.Space.s12),

            replyFieldView.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            replyFieldView.topAnchor.constraint(equalTo: activityLabel.bottomAnchor, constant: Chrome.Space.s8),
            replyFieldView.heightAnchor.constraint(equalToConstant: Self.replyFieldHeight),
            replyFieldView.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -Chrome.Space.s8),

            replyField.leadingAnchor.constraint(equalTo: replyFieldView.leadingAnchor, constant: 10),
            replyField.trailingAnchor.constraint(equalTo: replyFieldView.trailingAnchor, constant: -10),
            replyField.centerYAnchor.constraint(equalTo: replyFieldView.centerYAnchor),

            sendButton.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            sendButton.centerYAnchor.constraint(equalTo: replyFieldView.centerYAnchor),
            sendButton.heightAnchor.constraint(equalToConstant: Self.replyFieldHeight),
            sendButton.widthAnchor.constraint(
                equalToConstant: sendButton.intrinsicContentSize.width + 2 * (Chrome.Space.s16 - ChromeButton.horizontalPadding)
            ),

            replyHintLabel.leadingAnchor.constraint(equalTo: replyFieldView.leadingAnchor, constant: 2),
            replyHintLabel.trailingAnchor.constraint(lessThanOrEqualTo: column.trailingAnchor),
            replyHintLabel.topAnchor.constraint(equalTo: replyFieldView.bottomAnchor, constant: 6),
            replyHintLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Chrome.Space.s12),
        ])
    }

    /// A read-only text view in a borderless scroll view. TextKit 1, because
    /// the timeline draws its cards, diffs and code with `NSTextBlock`.
    private static func makeTextScrollView(
        identifier: String,
        inset: NSSize
    ) -> (NSScrollView, AgentDashboardTextView) {
        let scrollView = NSScrollView()
        scrollView.identifier = NSUserInterfaceItemIdentifier(identifier)
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let textView = AgentDashboardTextView(usingTextLayoutManager: false)
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.font = ChromeFont.mono
        textView.textContainerInset = inset
        scrollView.documentView = textView
        return (scrollView, textView)
    }

    private func configureButton(
        _ button: ChromeButton,
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
        timelineScrollView.isHidden = !timelineVisible
        terminalCard.isHidden = timelineVisible
        modeControl.select(timelineVisible ? 0 : 1)
        if timelineVisible {
            renderTimeline()
        } else {
            updateTerminalText()
        }
        updateJumpButton()
        updateActivity()
        updateControls()
    }

    private func renderTimeline() {
        guard timelineTextView != nil, showsTimeline else { return }
        let follows = isFollowing
        if let timeline {
            let output = timelineRenderer.render(
                timeline,
                detailed: isDetailed,
                isAgentActive: isAgentActive,
                agentName: entry?.profileName
            )
            timelineTextView.textStorage?.setAttributedString(output.text)
            turnStarts = output.turnStarts
        } else {
            timelineTextView.textStorage?.setAttributedString(NSAttributedString(
                string: "Waiting for the agent's first message…",
                attributes: [
                    .font: ChromeFont.row,
                    .foregroundColor: theme.colors.textMuted,
                ]
            ))
            turnStarts = []
        }
        if follows {
            scrollTimelineToEnd()
        }
        updateJumpButton()
    }

    private var isAgentActive: Bool {
        switch entry?.status {
        case .running?, .starting?, .waiting?: true
        default: false
        }
    }

    private func scrollTimelineToEnd() {
        let length = timelineTextView.textStorage?.length ?? 0
        timelineTextView.scrollRangeToVisible(NSRange(location: length, length: 0))
        isFollowing = true
        updateJumpButton()
    }

    @objc private func timelineDidScroll(_ notification: Notification) {
        let clip = timelineScrollView.contentView
        let documentHeight = timelineScrollView.documentView?.frame.height ?? 0
        let following = clip.bounds.maxY >= documentHeight - 24
        guard following != isFollowing else { return }
        isFollowing = following
        updateJumpButton()
    }

    /// Offers the way back to the newest entry once the timeline was
    /// scrolled away from it.
    private func updateJumpButton() {
        jumpButton.isHidden = !showsTimeline || isFollowing || entry == nil
    }

    private func scroll(_ scrollView: NSScrollView, toY y: CGFloat) {
        let clip = scrollView.contentView
        let documentHeight = scrollView.documentView?.frame.height ?? 0
        let maximum = max(0, documentHeight - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: min(max(0, y), maximum)))
        scrollView.reflectScrolledClipView(clip)
    }

    /// The composer's activity line: the agent's status mark, then what it is
    /// doing according to its transcript (`▶ Bash · swift test · 38s`), or its
    /// state in words when it writes none.
    private func updateActivity(now: Date = Date()) {
        let colors = theme.colors
        guard let entry else {
            activityMark.isHidden = true
            activityLabel.stringValue = ""
            return
        }
        activityMark.isHidden = false
        activityMark.set(status: entry.status.chromeStatus, colors: colors)
        let activity = AgentTimelineActivity.current(in: timeline, status: entry.status, now: now)
        let color = activity?.tone == .failed ? colors.danger : colors.textMuted
        let line = activity.map {
            $0.attributed(
                font: ChromeFont.label,
                titleFont: ChromeFont.labelStrong,
                codeFont: ChromeFont.mono,
                color: color,
                codeColor: activity?.tone == .failed ? colors.danger : colors.textPrimary
            )
        } ?? ChromeText.attributed(fallbackActivity, font: ChromeFont.label, color: color, lineBreakMode: .byTruncatingTail)
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

    /// Title row (mark, New York title, status, timer) and the location line:
    /// the agent's task as the sidebar names it, over `window ▸ omp · folder`.
    private func refreshEntryLabels() {
        let colors = theme.colors
        titleLabel.setChromeText(
            entry?.title ?? "No agent selected",
            font: ChromeFont.headline,
            color: entry == nil ? colors.textMuted : colors.textPrimary
        )
        guard let entry else {
            statusMark.isHidden = true
            statusLabel.setStatusText("", color: colors.textMuted)
            timerLabel.stringValue = ""
            titleLabel.toolTip = nil
            locationLabel.setChromeText("Choose an agent to follow its work.", font: ChromeFont.meta, color: colors.textMuted)
            locationLabel.toolTip = nil
            setReplyPlaceholder(nil)
            return
        }

        let status = entry.status.chromeStatus
        statusMark.isHidden = false
        statusMark.set(status: status, colors: colors)
        statusLabel.setStatusText(status.label, color: status.color(in: colors))
        updateTimer()
        titleLabel.toolTip = entry.title

        let location = NSMutableAttributedString(attributedString: ChromeText.attributed(
            "\(entry.windowTitle) ▸ ",
            font: ChromeFont.meta,
            color: colors.textMuted
        ))
        location.append(entry.context.attributed(font: ChromeFont.meta, color: colors.textMuted))
        locationLabel.attributedStringValue = location
        let path = entry.cwd.map { ($0 as NSString).abbreviatingWithTildeInPath }
        locationLabel.toolTip = [entry.location, path].compactMap { $0 }.joined(separator: "\n")
        setReplyPlaceholder("Reply to \(entry.profileName)…")
    }

    private func updateTimer(now: Date = Date()) {
        guard let entry else { return }
        let text = agentDashboardElapsedText(status: entry.status, startedAt: entry.startedAt, now: now)
        timerLabel.setChromeText(text, font: ChromeFont.count, color: theme.colors.textMuted)
    }

    private func setReplyPlaceholder(_ placeholder: String?) {
        replyField.placeholderAttributedString = placeholder.map {
            ChromeText.attributed($0, font: ChromeFont.row, color: theme.colors.textMuted)
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
            attributedText = AgentOutputHighlighter.highlight(
                displayText,
                theme: theme,
                font: ChromeFont.mono
            )
        } else {
            attributedText = NSAttributedString(
                string: displayText,
                attributes: [
                    .font: ChromeFont.row,
                    .foregroundColor: theme.colors.textMuted,
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

    private func updateControls() {
        replyHintLabel.textColor = theme.colors.textMuted
        modeControl.setEnabled(hasTranscript, forSegment: 0)
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
            replyHintLabel.stringValue = "Open the agent to initialize its terminal."
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
        sendButton.isEnabled = canReply
            && !replyField.stringValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
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

    @objc private func modeChanged(_ sender: ChromeSegmentedControl) {
        setPrefersTerminal(sender.selectedSegment == 1)
    }

    @objc private func detailsClicked() {
        toggleDetails()
    }

    @objc private func jumpClicked() {
        followLatest()
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
            replyHintLabel.textColor = theme.colors.danger
        }
    }
}

/// Read-only dashboard text that hands the keyboard back to the dashboard:
/// clicking into it selects text for copying without capturing J/K.
private final class AgentDashboardTextView: NSTextView {
    var keyHandler: ((NSEvent) -> Bool)?
    /// When set, the text keeps to this width, centered, with at least
    /// `minimumInset` on either side: a readable column on a wide window.
    var readableWidth: CGFloat? {
        didSet { updateReadableInset() }
    }
    var minimumInset: CGFloat = 0

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateReadableInset()
    }

    private func updateReadableInset() {
        guard let readableWidth else { return }
        let inset = max(minimumInset, floor((bounds.width - readableWidth) / 2))
        guard textContainerInset.width != inset else { return }
        textContainerInset = NSSize(width: inset, height: textContainerInset.height)
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
        titleLabel.setEyebrowText(section.title, color: theme.colors.textMuted)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        countLabel.identifier = NSUserInterfaceItemIdentifier("agent-dashboard-section-count")
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(countLabel)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Chrome.pillInset + 14),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            countLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6),
            countLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            countLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Chrome.Space.s12),
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
        countLabel.setChromeText("\(count)", font: ChromeFont.count, color: theme.colors.textMuted)
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
        setClippingResistancePriority(Chrome.fillPriority, for: .horizontal)
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
            let caps = ChromeKeycapGroupView(caps: hint.caps, theme: theme, style: .standard, tone: .muted)
            let label = NSTextField(labelWithString: hint.label)
            label.setChromeText(hint.label, font: ChromeFont.meta, color: theme.colors.textMuted)
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
    private let statusMark = ChromeStatusMark()
    private let titleLabel = NSTextField(labelWithString: "")
    private let elapsedLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let activityLabel = NSTextField(labelWithString: "")
    private var activity: AgentTimelineActivity?
    private var isHovered = false
    private var isKeyboardSelected = false

    init(entry: AgentDashboardEntry, theme: AppTheme) {
        self.entry = entry
        self.theme = theme
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

    override func draw(_ dirtyRect: NSRect) {
        let style = selectionStyle
        guard style == .attention else {
            ChromeSelectionPill.draw(style, in: bounds, colors: theme.colors)
            return
        }
        drawAttention()
    }

    /// `.agent.is-attention`: the full-bleed wash, with the attention tick
    /// where the selected pill's pencil tick sits (pill inset + tick inset),
    /// so the two line up in one list.
    private func drawAttention() {
        let colors = theme.colors
        colors.attentionRowWash.setFill()
        bounds.fill(using: .sourceOver)
        let tick = NSRect(
            x: bounds.minX + Chrome.pillInset + Chrome.tickInset,
            y: floor(bounds.midY - Chrome.tickHeight / 2),
            width: Chrome.tickWidth,
            height: Chrome.tickHeight
        )
        colors.attention.setFill()
        NSBezierPath(roundedRect: tick, xRadius: 1, yRadius: 1).fill()
    }

    private var selectionStyle: ChromeSelectionPill.Style {
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
        elapsedLabel.setChromeText(text, font: ChromeFont.count, color: theme.colors.textMuted)
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
        addSubview(statusMark)

        titleLabel.identifier = NSUserInterfaceItemIdentifier("agent-dashboard-title")
        elapsedLabel.identifier = NSUserInterfaceItemIdentifier("agent-dashboard-elapsed")
        statusLabel.identifier = NSUserInterfaceItemIdentifier("agent-dashboard-status")
        activityLabel.identifier = NSUserInterfaceItemIdentifier("agent-dashboard-activity")
        for label in [titleLabel, elapsedLabel, statusLabel, activityLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        activityLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for label in [elapsedLabel, statusLabel] {
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            label.setContentHuggingPriority(.required, for: .horizontal)
        }

        // Two lines (16 + 3 + 14) centered in the 52 pt row. The pill sits
        // 4 pt in, and `.agent` pads 14 / 12 inside it.
        let firstLine: CGFloat = 17.5
        let secondLine: CGFloat = 35.5
        NSLayoutConstraint.activate([
            statusMark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Chrome.pillInset + 14),
            statusMark.centerYAnchor.constraint(equalTo: topAnchor, constant: firstLine),

            titleLabel.leadingAnchor.constraint(equalTo: statusMark.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: topAnchor, constant: firstLine),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: elapsedLabel.leadingAnchor, constant: -8),

            elapsedLabel.trailingAnchor.constraint(equalTo: statusLabel.leadingAnchor, constant: -8),
            elapsedLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(Chrome.pillInset + 12)),
            statusLabel.centerYAnchor.constraint(equalTo: topAnchor, constant: firstLine),

            activityLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
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
        let colors = theme.colors
        let statusChanged = previous?.status != entry.status
            || previous?.needsAttention != entry.needsAttention
        if statusChanged {
            let status = entry.status.chromeStatus
            statusMark.set(status: status, colors: colors)
            statusLabel.setStatusText(status.label, color: status.color(in: colors))
            needsDisplay = true
        }
        if statusChanged || previous?.startedAt != entry.startedAt {
            updateElapsed(now: Date())
        }
        let title = entry.title
        if previous?.title != title {
            titleLabel.setChromeText(title, font: ChromeFont.labelStrong, color: colors.textPrimary)
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
        let colors = theme.colors
        let line = NSMutableAttributedString(
            attributedString: entry.context.attributed(font: ChromeFont.meta, color: colors.textMuted)
        )
        if let activity {
            let color = activity.tone == .failed ? colors.danger : colors.textMuted
            if line.length > 0 {
                line.append(ChromeText.attributed(" — ", font: ChromeFont.meta, color: colors.textMuted))
            }
            line.append(activity.attributed(
                font: ChromeFont.meta,
                titleFont: ChromeFont.meta,
                codeFont: ChromeFont.monoSmall,
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
