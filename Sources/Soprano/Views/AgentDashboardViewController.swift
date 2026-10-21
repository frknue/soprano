import AppKit

/// Full-window operational view over every attached agent.
final class AgentDashboardViewController: NSViewController {
    typealias TerminalStateProvider = (TerminalTarget) -> TerminalInteractionState
    typealias PromptSender = (TerminalTarget, String) -> Bool

    let agentManager: AgentManager
    let themeManager: ThemeManager

    var onDismiss: (() -> Void)?
    var onAgentSelected: ((String, String) -> Void)?

    private let terminalStateProvider: TerminalStateProvider
    private let promptSender: PromptSender
    private let transcriptStore: AgentTranscriptStore
    private var headerView: NSView!
    private var titleLabel: NSTextField!
    private var subtitleLabel: NSTextField!
    private var doneButton: ChromeButton!
    private var headerRule: ChromeRuleView!
    private var summaryContainer: NSView!
    private var leftPanel: NSView!
    private var agentListHeading: ChromeEyebrowView!
    private var keyboardHintLabel: NSTextField!
    private var rowsStack: NSStackView!
    private var detailView: AgentDashboardDetailView!
    private var agentRows: [AgentDashboardRowView] = []
    private var emptyStateView: NSView?
    private var summaryCards: [AgentDashboardSummaryCard] = []
    private var entriesById: [String: AgentDashboardEntry] = [:]
    private var selectedEntryId: String?
    nonisolated(unsafe) private var elapsedTimer: Timer?
    private let observerId = "AgentDashboardViewController"

    init(
        agentManager: AgentManager,
        themeManager: ThemeManager,
        terminalStateProvider: @escaping TerminalStateProvider = { _ in .unavailable },
        promptSender: @escaping PromptSender = { _, _ in false },
        transcriptStore: AgentTranscriptStore = AgentTranscriptStore()
    ) {
        self.agentManager = agentManager
        self.themeManager = themeManager
        self.terminalStateProvider = terminalStateProvider
        self.promptSender = promptSender
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
        root.wantsLayer = true
        root.layer?.backgroundColor = theme.colors.bgBase.cgColor

        headerView = NSView()
        headerView.wantsLayer = true
        headerView.layer?.backgroundColor = theme.colors.bgPanel.cgColor
        headerView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(headerView)

        titleLabel = NSTextField(labelWithString: "Agent Dashboard")
        titleLabel.setChromeText(
            "Agent Dashboard",
            font: ChromeFont.screen,
            color: theme.colors.textPrimary
        )
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(titleLabel)

        subtitleLabel = NSTextField(labelWithString: "")
        subtitleLabel.font = ChromeFont.sans(size: 11, weight: .regular)
        subtitleLabel.textColor = theme.colors.textMuted
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(subtitleLabel)

        doneButton = ChromeButton(
            title: "Done",
            theme: theme,
            kind: .standard,
            target: self,
            action: #selector(doneClicked)
        )
        doneButton.keyEquivalent = "\u{1b}"
        doneButton.keyEquivalentModifierMask = []
        doneButton.toolTip = "Return to the workspace (Esc)"
        headerView.addSubview(doneButton)

        headerRule = ChromeRuleView(
            axis: .horizontal,
            color: theme.colors.borderSubtle
        )
        headerView.addSubview(headerRule)

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentView)

        summaryContainer = NSView()
        summaryContainer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(summaryContainer)

        let workspaceStack = NSStackView()
        workspaceStack.orientation = .horizontal
        workspaceStack.alignment = .top
        workspaceStack.distribution = .fill
        workspaceStack.spacing = 16
        workspaceStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(workspaceStack)

        leftPanel = makeAgentListPanel(theme: theme)
        workspaceStack.addArrangedSubview(leftPanel)
        let preferredListWidth = leftPanel.widthAnchor.constraint(equalToConstant: 380)
        preferredListWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            leftPanel.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
            leftPanel.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
            preferredListWidth,
        ])

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
        workspaceStack.addArrangedSubview(detailView)
        detailView.widthAnchor.constraint(greaterThanOrEqualToConstant: 400).isActive = true

        NSLayoutConstraint.activate([
            headerView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            headerView.topAnchor.constraint(equalTo: root.topAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 68),

            titleLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 28),
            titleLabel.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 9),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: doneButton.leadingAnchor,
                constant: -16
            ),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            subtitleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: doneButton.leadingAnchor,
                constant: -16
            ),

            doneButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -28),
            doneButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

            headerRule.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),
            headerRule.trailingAnchor.constraint(equalTo: headerView.trailingAnchor),
            headerRule.bottomAnchor.constraint(equalTo: headerView.bottomAnchor),

            contentView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            contentView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            contentView.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 24),
            contentView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -28),

            summaryContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            summaryContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            summaryContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
            summaryContainer.heightAnchor.constraint(equalToConstant: 92),

            workspaceStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            workspaceStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            workspaceStack.topAnchor.constraint(
                equalTo: summaryContainer.bottomAnchor,
                constant: 18
            ),
            workspaceStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            leftPanel.heightAnchor.constraint(equalTo: workspaceStack.heightAnchor),
            detailView.heightAnchor.constraint(equalTo: workspaceStack.heightAnchor),
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
        headerView.layer?.backgroundColor = colors.bgPanel.cgColor
        titleLabel.setChromeText(
            titleLabel.stringValue,
            font: ChromeFont.screen,
            color: colors.textPrimary
        )
        subtitleLabel.textColor = colors.textMuted
        doneButton.apply(theme: theme)
        headerRule.color = colors.borderSubtle
        leftPanel.layer?.backgroundColor = colors.bgPanel.cgColor
        leftPanel.layer?.borderColor = colors.borderStrong.cgColor
        agentListHeading.apply(theme: theme)
        keyboardHintLabel.setChromeText(keyboardHintLabel.stringValue, color: colors.textMuted)
        detailView.apply(theme: theme)
        // Rows, the empty state, and the summary cards take their colors when
        // they are built, so a theme change rebuilds them.
        rowsStack.setArrangedSubviews([])
        agentRows.removeAll()
        emptyStateView = nil
        summaryCards.removeAll()
        refresh()
    }

    /// Brings the dashboard up to date with the agent manager. This runs for
    /// every model notification, and busy agents retitle their tabs several
    /// times a second, so it only touches views whose content changed.
    private func refresh() {
        guard isViewLoaded else { return }
        let snapshot = agentManager.agentDashboardSnapshot()
        let theme = themeManager.currentTheme
        let previousSelection = selectedEntryId
        let previousSelectedEntry = previousSelection.flatMap { entriesById[$0] }
        entriesById = Dictionary(
            uniqueKeysWithValues: snapshot.entries.map { ($0.id, $0) }
        )
        selectedEntryId = snapshot.entries.contains {
            $0.id == previousSelection
        } ? previousSelection : snapshot.entries.first?.id
        trackTranscripts(of: snapshot.entries)
        let subtitle = monitoringSubtitle(
            agentCount: snapshot.totalCount,
            windowCount: agentManager.windowCount
        )
        if subtitleLabel.stringValue != subtitle {
            subtitleLabel.stringValue = subtitle
        }

        if summaryCards.isEmpty {
            rebuildSummary(theme: theme)
        }
        let counts = [
            snapshot.totalCount,
            snapshot.workingCount,
            snapshot.needsInputCount,
            snapshot.errorCount,
        ]
        for (card, count) in zip(summaryCards, counts) {
            card.update(value: count)
        }
        reconcileRows(with: snapshot.entries, theme: theme)
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
              let entry = agentManager.agentDashboardEntry(for: target)
        else { return }
        entriesById[entry.id] = entry
        row.update(entry: entry)
        if entry.id == selectedEntryId {
            updateDetail()
        }
    }

    /// Updates surviving rows in place, adds rows for new agents, drops rows
    /// for agents that are gone, and moves rows whose urgency order changed.
    private func reconcileRows(with entries: [AgentDashboardEntry], theme: AppTheme) {
        var reusableRows = Dictionary(
            uniqueKeysWithValues: agentRows.map { ($0.entry.id, $0) }
        )
        agentRows = entries.map { entry in
            let row = reusableRows.removeValue(forKey: entry.id).map { row in
                row.update(entry: entry)
                return row
            } ?? makeRow(entry: entry, theme: theme)
            row.updateActivity(activity(for: entry))
            return row
        }
        if !entries.isEmpty {
            emptyStateView = nil
        } else if emptyStateView == nil {
            emptyStateView = makeEmptyState(theme: theme)
        }
        let views: [NSView] = emptyStateView.map { [$0] } ?? agentRows
        rowsStack.setArrangedSubviews(views) { view in
            view.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }
    }

    private func makeRow(entry: AgentDashboardEntry, theme: AppTheme) -> AgentDashboardRowView {
        let row = AgentDashboardRowView(entry: entry, theme: theme)
        row.onSelect = { [weak self] in
            self?.selectEntry(entry.id)
        }
        row.onOpen = { [weak self] in
            self?.onAgentSelected?(entry.paneId, entry.tabId)
        }
        return row
    }

    private func makeAgentListPanel(theme: AppTheme) -> NSView {
        let panel = NSView()
        panel.wantsLayer = true
        panel.layer?.backgroundColor = theme.colors.bgPanel.cgColor
        panel.layer?.borderColor = theme.colors.borderStrong.cgColor
        panel.layer?.borderWidth = Chrome.hairline
        panel.layer?.cornerRadius = 0
        panel.translatesAutoresizingMaskIntoConstraints = false

        let sectionHeader = makeSectionHeader(theme: theme)
        panel.addSubview(sectionHeader)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(scrollView)

        let documentView = AgentDashboardFlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 10
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(rowsStack)

        NSLayoutConstraint.activate([
            sectionHeader.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14),
            sectionHeader.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14),
            sectionHeader.topAnchor.constraint(equalTo: panel.topAnchor, constant: 12),
            sectionHeader.heightAnchor.constraint(equalToConstant: 24),

            scrollView.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: sectionHeader.bottomAnchor, constant: 6),
            scrollView.bottomAnchor.constraint(equalTo: panel.bottomAnchor),

            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.bottomAnchor.constraint(
                greaterThanOrEqualTo: scrollView.contentView.bottomAnchor
            ),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            rowsStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 10),
            rowsStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -10),
            rowsStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 8),
            rowsStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -12),
        ])
        return panel
    }

    private func replaceContents(of container: NSView, with content: NSView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
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

    /// Builds the four count cards; refresh() keeps their values current.
    private func rebuildSummary(theme: AppTheme) {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fillEqually
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.heightAnchor.constraint(equalToConstant: 92).isActive = true

        let cards = [
            ("Total", theme.colors.accent),
            ("Working", theme.colors.success),
            ("Needs Input", theme.colors.yellow),
            ("Errors", theme.colors.danger),
        ]
        summaryCards = cards.map { title, color in
            let card = AgentDashboardSummaryCard(
                title: title,
                color: color,
                theme: theme
            )
            stack.addArrangedSubview(card)
            card.heightAnchor.constraint(equalTo: stack.heightAnchor).isActive = true
            return card
        }
        replaceContents(of: summaryContainer, with: stack)
    }

    private func makeSectionHeader(theme: AppTheme) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        agentListHeading = ChromeEyebrowView(title: "AGENTS", theme: theme)
        container.addSubview(agentListHeading)

        let keyboardHint = "J/K  ·  TAB REPLY  ·  ↩ OPEN"
        keyboardHintLabel = NSTextField(labelWithString: keyboardHint)
        keyboardHintLabel.alignment = .right
        keyboardHintLabel.lineBreakMode = .byTruncatingHead
        keyboardHintLabel.setChromeText(keyboardHint, color: theme.colors.textMuted)
        keyboardHintLabel.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        keyboardHintLabel.setContentHuggingPriority(.required, for: .horizontal)
        keyboardHintLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(keyboardHintLabel)

        NSLayoutConstraint.activate([
            agentListHeading.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            agentListHeading.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            keyboardHintLabel.leadingAnchor.constraint(
                equalTo: agentListHeading.trailingAnchor,
                constant: 12
            ),
            keyboardHintLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            keyboardHintLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    private func makeEmptyState(theme: AppTheme) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = theme.colors.bgPanel.cgColor
        card.layer?.borderColor = theme.colors.borderSubtle.cgColor
        card.layer?.borderWidth = 1
        card.layer?.cornerRadius = Chrome.Radius.card
        card.translatesAutoresizingMaskIntoConstraints = false
        card.heightAnchor.constraint(equalToConstant: 150).isActive = true

        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: "chart.xyaxis.line",
            accessibilityDescription: nil
        )
        icon.contentTintColor = theme.colors.textMuted
        icon.symbolConfiguration = .init(pointSize: 22, weight: .regular)
        icon.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(icon)

        let titleText = "No agents to monitor"
        let title = NSTextField(labelWithString: titleText)
        title.setChromeText(titleText, color: theme.colors.textPrimary)
        title.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(title)

        let detail = NSTextField(
            labelWithString: "Launch an agent from the sidebar or command palette."
        )
        detail.font = ChromeFont.sans(size: 11, weight: .regular)
        detail.textColor = theme.colors.textMuted
        detail.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(detail)

        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            icon.topAnchor.constraint(equalTo: card.topAnchor, constant: 28),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
            title.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            title.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 10),
            detail.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),
        ])
        return card
    }

    @objc private func doneClicked() {
        onDismiss?()
    }
}

/// How far one keyboard shortcut scrolls the detail text.
private enum AgentDashboardScroll: Equatable {
    case lines(Int)
    case pages(Int)
}

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

    private let titleLabel = NSTextField(labelWithString: "No agent selected")
    private let locationLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let terminalHeading: ChromeEyebrowView
    private let terminalStateLabel = NSTextField(labelWithString: "UNAVAILABLE")
    private let timelineHintLabel = NSTextField(labelWithString: "")
    private let replyHintLabel = NSTextField(labelWithString: "")
    private let openButton: ChromeButton
    private let stopButton: ChromeButton
    private let restartButton: ChromeButton
    private let viewButton: ChromeButton
    private let sendButton: ChromeButton
    private let separator: ChromeRuleView
    private let replyField = NSTextField()
    private let nowStrip = NSView()
    private let nowLabel = NSTextField(labelWithString: "")
    private var terminalScrollView: NSScrollView!
    private var terminalTextView: AgentDashboardTextView!
    private var timelineScrollView: NSScrollView!
    private var timelineTextView: AgentDashboardTextView!

    /// Whether the selected agent shows its live terminal instead of its
    /// timeline: agents without a readable transcript, or after T.
    var isShowingTerminal: Bool { !showsTimeline }

    private var showsTimeline: Bool { hasTranscript && !prefersTerminal }

    init(theme: AppTheme) {
        self.theme = theme
        timelineRenderer = AgentTimelineRenderer(colors: theme.colors)
        terminalHeading = ChromeEyebrowView(title: "LIVE TERMINAL", theme: theme)
        openButton = ChromeButton(title: "Open", theme: theme)
        stopButton = ChromeButton(title: "Stop", theme: theme)
        restartButton = ChromeButton(title: "Restart", theme: theme)
        viewButton = ChromeButton(title: "Terminal", theme: theme)
        sendButton = ChromeButton(title: "Send", theme: theme, kind: .ink)
        separator = ChromeRuleView(
            axis: .horizontal,
            color: theme.colors.borderSubtle
        )
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("agent-dashboard-detail")
        wantsLayer = true
        layer?.cornerRadius = 0
        layer?.borderWidth = Chrome.hairline
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
        layer?.backgroundColor = colors.bgPanel.cgColor
        layer?.borderColor = colors.borderStrong.cgColor
        refreshTitle()
        locationLabel.textColor = colors.textMuted
        terminalHeading.apply(theme: theme)
        separator.color = colors.borderSubtle
        replyHintLabel.textColor = colors.textMuted
        for (scrollView, textView) in [
            (terminalScrollView!, terminalTextView!),
            (timelineScrollView!, timelineTextView!),
        ] {
            scrollView.backgroundColor = colors.bgBase
            scrollView.layer?.borderColor = colors.borderStrong.cgColor
            textView.backgroundColor = colors.bgBase
            textView.insertionPointColor = colors.textPrimary
            textView.selectedTextAttributes = [.backgroundColor: colors.accent.withAlphaComponent(0.3)]
        }
        // NSTextView draws links with these instead of the renderer's own.
        timelineTextView.linkTextAttributes = [
            .foregroundColor: colors.blue,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        replyField.backgroundColor = colors.bgBase
        replyField.textColor = colors.textPrimary
        replyField.layer?.borderColor = colors.borderStrong.cgColor
        setReplyPlaceholder(replyField.placeholderAttributedString?.string)
        [openButton, stopButton, restartButton, viewButton, sendButton].forEach {
            $0.apply(theme: theme)
        }
        timelineRenderer.apply(colors: colors)
        refreshStatusColors()
        updateTimelineHint()
        updateTerminalText()
        renderTimeline()
        updateActivity()
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

    /// Redraws the selected entry's labels.
    private func refreshEntryLabels() {
        refreshTitle()
        refreshStatusColors()
        guard let entry else {
            titleLabel.toolTip = nil
            locationLabel.stringValue = "Choose an agent to follow its work."
            locationLabel.toolTip = nil
            return
        }

        titleLabel.toolTip = entry.projectName
        let path = entry.cwd.map { ($0 as NSString).abbreviatingWithTildeInPath }
        locationLabel.stringValue = [entry.profileName, entry.location, path]
            .compactMap { $0 }
            .joined(separator: "  ·  ")
        locationLabel.toolTip = locationLabel.stringValue
        setReplyPlaceholder("Reply to \(entry.profileName)…")
    }

    func updateTerminal(_ terminal: TerminalInteractionState) {
        guard entry != nil, terminal != self.terminal else { return }
        self.terminal = terminal
        if !showsTimeline {
            updateTerminalText()
        }
        updateControls()
    }

    /// Advances the elapsed time in the NOW strip.
    func tick(now: Date) {
        updateActivity(now: now)
    }

    func focusReply() {
        guard replyField.isEnabled else { return }
        window?.makeFirstResponder(replyField)
    }

    func controlTextDidChange(_ notification: Notification) {
        updateSendButton()
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
        guard hasTranscript else { return }
        prefersTerminal.toggle()
        applyMode()
        if prefersTerminal {
            onTerminalShown?()
        }
    }

    // MARK: - Layout

    private func build() {
        titleLabel.identifier = NSUserInterfaceItemIdentifier("agent-dashboard-detail-project")
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        locationLabel.font = ChromeFont.monospaced(size: 11)
        locationLabel.lineBreakMode = .byTruncatingMiddle
        locationLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(locationLabel)

        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusLabel.alignment = .right
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        configureButton(
            openButton,
            identifier: "agent-dashboard-open",
            action: #selector(openClicked)
        )
        configureButton(
            stopButton,
            identifier: "agent-dashboard-stop",
            action: #selector(stopClicked)
        )
        configureButton(
            restartButton,
            identifier: "agent-dashboard-restart",
            action: #selector(restartClicked)
        )
        configureButton(
            viewButton,
            identifier: "agent-dashboard-view",
            action: #selector(viewClicked)
        )
        viewButton.toolTip = "Switch between the timeline and the live terminal (T)"

        let actionStack = NSStackView(views: [
            openButton,
            stopButton,
            restartButton,
            viewButton,
        ])
        actionStack.orientation = .horizontal
        actionStack.alignment = .centerY
        actionStack.spacing = 8
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(actionStack)

        addSubview(separator)

        addSubview(terminalHeading)

        timelineHintLabel.alignment = .right
        timelineHintLabel.lineBreakMode = .byTruncatingHead
        timelineHintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        timelineHintLabel.setContentHuggingPriority(.required, for: .horizontal)
        timelineHintLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(timelineHintLabel)

        terminalStateLabel.alignment = .right
        terminalStateLabel.setContentHuggingPriority(.required, for: .horizontal)
        terminalStateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        terminalStateLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminalStateLabel)

        nowStrip.identifier = NSUserInterfaceItemIdentifier("agent-dashboard-now")
        nowStrip.wantsLayer = true
        nowStrip.layer?.borderWidth = Chrome.hairline
        nowStrip.layer?.cornerRadius = Chrome.Radius.control
        nowStrip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nowStrip)

        nowLabel.identifier = NSUserInterfaceItemIdentifier("agent-dashboard-now-label")
        nowLabel.font = ChromeFont.sans(size: 11, weight: .regular)
        nowLabel.lineBreakMode = .byTruncatingTail
        nowLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nowLabel.translatesAutoresizingMaskIntoConstraints = false
        nowStrip.addSubview(nowLabel)

        (terminalScrollView, terminalTextView) = Self.makeTextScrollView(
            identifier: "agent-dashboard-terminal"
        )
        addSubview(terminalScrollView)

        (timelineScrollView, timelineTextView) = Self.makeTextScrollView(
            identifier: "agent-dashboard-timeline"
        )
        addSubview(timelineScrollView)
        timelineScrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(timelineDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: timelineScrollView.contentView
        )

        replyField.cell = AgentDashboardReplyFieldCell(textCell: "")
        replyField.identifier = NSUserInterfaceItemIdentifier(
            "agent-dashboard-reply"
        )
        replyField.isEditable = true
        replyField.isSelectable = true
        replyField.isBezeled = false
        replyField.isBordered = false
        replyField.drawsBackground = true
        replyField.usesSingleLineMode = true
        replyField.cell?.isScrollable = true
        replyField.cell?.wraps = false
        replyField.font = ChromeFont.sans(size: 11, weight: .regular)
        replyField.wantsLayer = true
        replyField.layer?.borderWidth = Chrome.hairline
        replyField.layer?.cornerRadius = Chrome.Radius.control
        replyField.focusRingType = .default
        replyField.delegate = self
        replyField.target = self
        replyField.action = #selector(sendClicked)
        replyField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(replyField)

        configureButton(
            sendButton,
            identifier: "agent-dashboard-send",
            action: #selector(sendClicked)
        )
        addSubview(sendButton)

        replyHintLabel.font = ChromeFont.meta
        replyHintLabel.lineBreakMode = .byTruncatingTail
        replyHintLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(replyHintLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: statusLabel.leadingAnchor,
                constant: -16
            ),

            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            statusLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),

            locationLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            locationLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            locationLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),

            actionStack.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            actionStack.topAnchor.constraint(equalTo: locationLabel.bottomAnchor, constant: 14),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: actionStack.bottomAnchor, constant: 16),

            terminalHeading.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            terminalHeading.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 14),
            terminalHeading.trailingAnchor.constraint(
                equalTo: timelineHintLabel.leadingAnchor,
                constant: -12
            ),
            timelineHintLabel.trailingAnchor.constraint(
                equalTo: terminalStateLabel.leadingAnchor,
                constant: -12
            ),
            timelineHintLabel.centerYAnchor.constraint(equalTo: terminalHeading.centerYAnchor),
            terminalStateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            terminalStateLabel.centerYAnchor.constraint(equalTo: terminalHeading.centerYAnchor),

            nowStrip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            nowStrip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            nowStrip.topAnchor.constraint(equalTo: terminalHeading.bottomAnchor, constant: 9),
            nowStrip.heightAnchor.constraint(equalToConstant: 26),
            nowLabel.leadingAnchor.constraint(equalTo: nowStrip.leadingAnchor, constant: 10),
            nowLabel.trailingAnchor.constraint(equalTo: nowStrip.trailingAnchor, constant: -10),
            nowLabel.centerYAnchor.constraint(equalTo: nowStrip.centerYAnchor),

            terminalScrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            terminalScrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            terminalScrollView.topAnchor.constraint(
                equalTo: terminalHeading.bottomAnchor,
                constant: 9
            ),
            terminalScrollView.bottomAnchor.constraint(
                equalTo: replyField.topAnchor,
                constant: -14
            ),
            terminalScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),

            timelineScrollView.leadingAnchor.constraint(equalTo: terminalScrollView.leadingAnchor),
            timelineScrollView.trailingAnchor.constraint(equalTo: terminalScrollView.trailingAnchor),
            timelineScrollView.topAnchor.constraint(equalTo: nowStrip.bottomAnchor, constant: 8),
            timelineScrollView.bottomAnchor.constraint(equalTo: terminalScrollView.bottomAnchor),

            replyField.leadingAnchor.constraint(equalTo: terminalScrollView.leadingAnchor),
            replyField.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -8),
            replyField.heightAnchor.constraint(equalToConstant: Chrome.controlHeight),

            sendButton.trailingAnchor.constraint(equalTo: terminalScrollView.trailingAnchor),
            sendButton.centerYAnchor.constraint(equalTo: replyField.centerYAnchor),
            sendButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 70),

            replyHintLabel.leadingAnchor.constraint(equalTo: replyField.leadingAnchor),
            replyHintLabel.trailingAnchor.constraint(equalTo: sendButton.trailingAnchor),
            replyHintLabel.topAnchor.constraint(equalTo: replyField.bottomAnchor, constant: 6),
            replyHintLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -13),
        ])
    }

    /// A read-only text view in a scroll view. TextKit 1, because the timeline
    /// draws its prompt cards and code with `NSTextBlock`.
    private static func makeTextScrollView(
        identifier: String
    ) -> (NSScrollView, AgentDashboardTextView) {
        let scrollView = NSScrollView()
        scrollView.identifier = NSUserInterfaceItemIdentifier(identifier)
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.wantsLayer = true
        scrollView.layer?.borderWidth = Chrome.hairline
        scrollView.layer?.cornerRadius = Chrome.Radius.card
        scrollView.hasVerticalScroller = true
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
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.font = ChromeFont.monospaced(size: 11)
        textView.textContainerInset = NSSize(width: 10, height: 10)
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

    /// Shows the timeline or the live terminal and labels the area to match.
    private func applyMode() {
        let timelineVisible = showsTimeline
        timelineScrollView.isHidden = !timelineVisible
        nowStrip.isHidden = !timelineVisible
        terminalScrollView.isHidden = timelineVisible
        terminalHeading.title = timelineVisible ? "TIMELINE" : "LIVE TERMINAL"
        viewButton.title = prefersTerminal ? "Timeline" : "Terminal"
        updateTimelineHint()
        if timelineVisible {
            renderTimeline()
        } else {
            updateTerminalText()
        }
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
                isAgentActive: isAgentActive
            )
            timelineTextView.textStorage?.setAttributedString(output.text)
            turnStarts = output.turnStarts
        } else {
            timelineTextView.textStorage?.setAttributedString(NSAttributedString(
                string: "Waiting for the agent's first message…",
                attributes: [
                    .font: ChromeFont.monospaced(size: 11),
                    .foregroundColor: theme.colors.textMuted,
                ]
            ))
            turnStarts = []
        }
        if follows {
            scrollTimelineToEnd()
        }
        updateStateLabel()
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
        updateStateLabel()
    }

    @objc private func timelineDidScroll(_ notification: Notification) {
        let clip = timelineScrollView.contentView
        let documentHeight = timelineScrollView.documentView?.frame.height ?? 0
        let following = clip.bounds.maxY >= documentHeight - 24
        guard following != isFollowing else { return }
        isFollowing = following
        updateStateLabel()
    }

    private func scroll(_ scrollView: NSScrollView, toY y: CGFloat) {
        let clip = scrollView.contentView
        let documentHeight = scrollView.documentView?.frame.height ?? 0
        let maximum = max(0, documentHeight - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: min(max(0, y), maximum)))
        scrollView.reflectScrolledClipView(clip)
    }

    private func updateActivity(now: Date = Date()) {
        guard showsTimeline else { return }
        let colors = theme.colors
        let activity = entry.flatMap {
            AgentTimelineActivity.current(in: timeline, status: $0.status, now: now)
        }
        let text = activity?.text ?? fallbackActivity
        let color = activity?.tone.color(in: colors) ?? colors.textMuted
        if nowLabel.stringValue != text {
            nowLabel.stringValue = text
        }
        nowLabel.textColor = color
        nowStrip.layer?.borderColor = color.cgColor
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

    private func updateTimelineHint() {
        let hint: String
        if showsTimeline {
            hint = "⇧J/⇧K SCROLL  ·  [ ] TURN  ·  O DETAILS  ·  G LIVE  ·  T TERMINAL"
        } else if hasTranscript {
            hint = "T TIMELINE"
        } else {
            hint = ""
        }
        timelineHintLabel.setChromeText(hint, color: theme.colors.textMuted)
    }

    private func updateStateLabel() {
        let colors = theme.colors
        if showsTimeline {
            terminalStateLabel.setStatusText(
                isFollowing ? "LIVE" : "PAUSED",
                color: isFollowing ? colors.success : colors.yellow
            )
        } else {
            terminalStateLabel.setStatusText(
                terminal.isAvailable ? "LIVE" : "UNAVAILABLE",
                color: terminal.isAvailable ? colors.success : colors.textMuted
            )
        }
    }

    private func refreshTitle() {
        titleLabel.setChromeText(
            entry?.projectName ?? "No agent selected",
            font: ChromeFont.screen,
            color: theme.colors.textPrimary
        )
    }

    private func setReplyPlaceholder(_ placeholder: String?) {
        replyField.placeholderAttributedString = placeholder.map {
            NSAttributedString(string: $0, attributes: [
                .font: ChromeFont.sans(size: 11, weight: .regular),
                .foregroundColor: theme.colors.textMuted,
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
            attributedText = AgentOutputHighlighter.highlight(
                displayText,
                theme: theme,
                font: ChromeFont.monospaced(size: 11)
            )
        } else {
            attributedText = NSAttributedString(
                string: displayText,
                attributes: [
                    .font: ChromeFont.monospaced(size: 11),
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
        if !showsTimeline {
            updateStateLabel()
        }
    }

    private func refreshStatusColors() {
        guard let entry else {
            statusLabel.setStatusText("", color: theme.colors.textMuted)
            return
        }
        statusLabel.setStatusText(
            entry.status.displayLabel,
            color: Self.statusColor(for: entry, theme: theme)
        )
    }

    private func updateControls() {
        replyHintLabel.textColor = theme.colors.textMuted
        viewButton.isEnabled = hasTranscript
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

    @objc private func viewClicked() {
        toggleTerminal()
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

    private static func statusColor(
        for entry: AgentDashboardEntry,
        theme: AppTheme
    ) -> NSColor {
        if entry.needsAttention { return theme.colors.blue }
        switch entry.status {
        case .idle: return theme.colors.blue
        case .starting: return theme.colors.yellow
        case .running: return theme.colors.success
        case .waiting: return theme.colors.yellow
        case .error: return theme.colors.danger
        case .stopped: return theme.colors.gray
        }
    }
}

/// Read-only dashboard text that hands the keyboard back to the dashboard:
/// clicking into it selects text for copying without capturing J/K.
private final class AgentDashboardTextView: NSTextView {
    var keyHandler: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }
}

private final class AgentDashboardSummaryCard: NSView {
    private let color: NSColor
    private let theme: AppTheme
    private let valueLabel = NSTextField(labelWithString: "")
    private var value: Int?

    init(title: String, color: NSColor, theme: AppTheme) {
        self.color = color
        self.theme = theme
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier(
            "agent-dashboard-summary-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))"
        )
        wantsLayer = true
        layer?.backgroundColor = theme.colors.bgPanel.cgColor
        layer?.borderColor = theme.colors.borderStrong.cgColor
        layer?.borderWidth = Chrome.hairline
        layer?.cornerRadius = Chrome.Radius.card

        let segmentBar = NSView()
        segmentBar.wantsLayer = true
        segmentBar.layer?.backgroundColor = color.cgColor
        segmentBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(segmentBar)

        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(valueLabel)

        let titleText = title.uppercased()
        let titleLabel = NSTextField(labelWithString: titleText)
        titleLabel.setEyebrowText(titleText, color: theme.colors.textMuted)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            segmentBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            segmentBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            segmentBar.topAnchor.constraint(equalTo: topAnchor),
            segmentBar.heightAnchor.constraint(equalToConstant: 2),
            valueLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            valueLabel.topAnchor.constraint(equalTo: segmentBar.bottomAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: valueLabel.leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: 6),
        ])
    }

    func update(value: Int) {
        guard value != self.value else { return }
        self.value = value
        valueLabel.setChromeText(
            "\(value)",
            font: ChromeFont.screen,
            color: value == 0 ? theme.colors.textMuted : color
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

private final class AgentDashboardRowView: NSControl {
    private(set) var entry: AgentDashboardEntry
    var onSelect: (() -> Void)?
    var onOpen: (() -> Void)?

    private let theme: AppTheme
    private let iconContainer = NSView()
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let lamp = NSView()
    private let elapsedLabel = NSTextField(labelWithString: "")
    private let activityLabel = NSTextField(labelWithString: "")
    private var activity: AgentTimelineActivity?
    private var heightConstraint: NSLayoutConstraint!
    private var isHovered = false
    private var isKeyboardSelected = false

    init(entry: AgentDashboardEntry, theme: AppTheme) {
        self.entry = entry
        self.theme = theme
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("agent-dashboard-row")
        wantsLayer = true
        layer?.cornerRadius = Chrome.Radius.card
        translatesAutoresizingMaskIntoConstraints = false
        // A fourth line appears once the agent's transcript says what it is doing.
        heightConstraint = heightAnchor.constraint(equalToConstant: Self.height(showsActivity: false))
        heightConstraint.isActive = true
        build()
        updateBackground()
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
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateBackground()
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

    /// Shows `entry` in this row; an unchanged entry leaves the row untouched.
    func update(entry: AgentDashboardEntry) {
        guard entry != self.entry else { return }
        let previous = self.entry
        self.entry = entry
        render(previous: previous)
    }

    func updateElapsed(now: Date) {
        elapsedLabel.setChromeText(
            Self.elapsedText(
                status: entry.status,
                startedAt: entry.startedAt,
                now: now
            ),
            color: statusColor
        )
    }

    /// Shows what the agent is doing according to its transcript.
    func updateActivity(_ activity: AgentTimelineActivity?) {
        guard activity != self.activity else { return }
        let showedActivity = self.activity != nil
        self.activity = activity
        activityLabel.stringValue = activity?.text ?? ""
        activityLabel.textColor = activity?.tone.color(in: theme.colors) ?? theme.colors.textMuted
        activityLabel.isHidden = activity == nil
        if showedActivity != (activity != nil) {
            heightConstraint.constant = Self.height(showsActivity: activity != nil)
        }
    }

    private static func height(showsActivity: Bool) -> CGFloat {
        showsActivity ? 112 : 92
    }

    func setKeyboardSelected(_ isSelected: Bool) {
        guard isKeyboardSelected != isSelected else { return }
        isKeyboardSelected = isSelected
        updateBorder()
        updateBackground()
    }

    private func build() {
        iconContainer.wantsLayer = true
        iconContainer.layer?.borderWidth = Chrome.hairline
        iconContainer.layer?.cornerRadius = Chrome.Radius.control
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconContainer)

        icon.symbolConfiguration = .init(pointSize: 15, weight: .medium)
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.addSubview(icon)

        titleLabel.identifier = NSUserInterfaceItemIdentifier("agent-dashboard-project")
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        detailLabel.identifier = NSUserInterfaceItemIdentifier("agent-dashboard-agent")
        detailLabel.font = ChromeFont.sans(size: 11, weight: .regular)
        detailLabel.textColor = theme.colors.textMuted
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(detailLabel)

        pathLabel.identifier = NSUserInterfaceItemIdentifier("agent-dashboard-directory")
        pathLabel.font = ChromeFont.monospaced(size: 11)
        pathLabel.textColor = theme.colors.textMuted
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pathLabel)

        activityLabel.identifier = NSUserInterfaceItemIdentifier("agent-dashboard-activity")
        activityLabel.font = ChromeFont.sans(size: 11, weight: .regular)
        activityLabel.lineBreakMode = .byTruncatingTail
        activityLabel.isHidden = true
        activityLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        activityLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(activityLabel)

        statusLabel.identifier = NSUserInterfaceItemIdentifier("agent-dashboard-status")
        statusLabel.alignment = .right
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        lamp.wantsLayer = true
        lamp.layer?.cornerRadius = 3
        lamp.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lamp)

        elapsedLabel.alignment = .right
        elapsedLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(elapsedLabel)

        let chevron = NSImageView()
        chevron.image = NSImage(
            systemSymbolName: "chevron.right",
            accessibilityDescription: "Focus agent"
        )
        chevron.contentTintColor = theme.colors.textMuted
        chevron.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevron)

        NSLayoutConstraint.activate([
            iconContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconContainer.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            iconContainer.widthAnchor.constraint(equalToConstant: 28),
            iconContainer.heightAnchor.constraint(equalToConstant: 28),

            icon.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),

            titleLabel.leadingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -12),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),
            detailLabel.trailingAnchor.constraint(equalTo: lamp.leadingAnchor, constant: -10),

            pathLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            pathLabel.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 5),
            pathLabel.trailingAnchor.constraint(equalTo: elapsedLabel.leadingAnchor, constant: -12),

            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            chevron.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 10),
            chevron.heightAnchor.constraint(equalToConstant: 14),

            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            statusLabel.centerYAnchor.constraint(equalTo: detailLabel.centerYAnchor),

            lamp.trailingAnchor.constraint(equalTo: statusLabel.leadingAnchor, constant: -6),
            lamp.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            lamp.widthAnchor.constraint(equalToConstant: 6),
            lamp.heightAnchor.constraint(equalToConstant: 6),

            elapsedLabel.trailingAnchor.constraint(equalTo: statusLabel.trailingAnchor),
            elapsedLabel.centerYAnchor.constraint(equalTo: pathLabel.centerYAnchor),

            activityLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            activityLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            activityLabel.topAnchor.constraint(equalTo: pathLabel.bottomAnchor, constant: 5),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    /// Redraws what depends on fields that differ from `previous`, or the
    /// whole row when there is none. A busy agent mostly changes its tab
    /// title, which only feeds the location text, so that path skips the
    /// symbol image and the display-face labels.
    private func render(previous: AgentDashboardEntry?) {
        let statusChanged = previous?.status != entry.status
            || previous?.needsAttention != entry.needsAttention
        if statusChanged {
            let statusColor = self.statusColor
            updateBorder()
            iconContainer.layer?.backgroundColor = statusColor.withAlphaComponent(0.14).cgColor
            iconContainer.layer?.borderColor = statusColor.cgColor
            icon.contentTintColor = statusColor
            statusLabel.setStatusText(
                entry.status.displayLabel,
                color: statusColor
            )
            lamp.layer?.backgroundColor = (
                isStatusLit ? statusColor : statusColor.withAlphaComponent(0.35)
            ).cgColor
        }
        if statusChanged || previous?.startedAt != entry.startedAt {
            updateElapsed(now: Date())
        }
        if previous?.profileIcon != entry.profileIcon
            || previous?.profileName != entry.profileName
        {
            icon.image = NSImage(
                systemSymbolName: entry.profileIcon,
                accessibilityDescription: entry.profileName
            ) ?? NSImage(
                systemSymbolName: AgentDashboardEntry.fallbackProfileIcon,
                accessibilityDescription: entry.profileName
            )
        }
        if previous?.projectName != entry.projectName {
            titleLabel.setChromeText(entry.projectName, color: theme.colors.textPrimary)
        }

        let location = entry.location
        let path = entry.cwd.map { ($0 as NSString).abbreviatingWithTildeInPath }
        let agentDescription = [entry.profileName, entry.sessionName]
            .compactMap { $0 }.joined(separator: "  ·  ")
        detailLabel.stringValue = agentDescription
        pathLabel.stringValue = path ?? location
        toolTip = [entry.projectName, agentDescription, location, path, "Double-click to open agent"]
            .compactMap { $0 }.joined(separator: "\n")
        setAccessibilityLabel(
            "\(entry.projectName), \(entry.profileName), \(entry.status.displayLabel), \(location)"
        )
    }

    private func updateBorder() {
        layer?.borderWidth = isKeyboardSelected ? 2 : 1
        layer?.borderColor = (
            isKeyboardSelected
                ? theme.colors.accent
                : entry.needsAttention
                    ? theme.colors.blue
                    : theme.colors.borderSubtle
        ).cgColor
    }

    private func updateBackground() {
        layer?.backgroundColor = (
            isKeyboardSelected
                ? theme.colors.selectionMuted
                : isHovered
                    ? theme.colors.bgOverlay
                    : theme.colors.bgPanel
        ).cgColor
    }

    private var isStatusLit: Bool {
        if entry.needsAttention { return true }
        switch entry.status {
        case .running, .waiting, .starting, .error: return true
        case .idle, .stopped: return false
        }
    }

    private var statusColor: NSColor {
        Self.statusColor(for: entry, theme: theme)
    }

    private static func statusColor(
        for entry: AgentDashboardEntry,
        theme: AppTheme
    ) -> NSColor {
        if entry.needsAttention { return theme.colors.blue }
        switch entry.status {
        case .idle: return theme.colors.blue
        case .starting: return theme.colors.yellow
        case .running: return theme.colors.success
        case .waiting: return theme.colors.yellow
        case .error: return theme.colors.danger
        case .stopped: return theme.colors.gray
        }
    }

    private static func elapsedText(
        status: AgentStatus,
        startedAt: Date?,
        now: Date
    ) -> String {
        guard let startedAt else { return "" }
        let interval = max(0, Int(now.timeIntervalSince(startedAt)))
        if status == .stopped {
            return "stopped"
        }
        if interval < 60 {
            return "\(interval)s"
        }
        if interval < 3_600 {
            return "\(interval / 60)m \(interval % 60)s"
        }
        return "\(interval / 3_600)h \((interval % 3_600) / 60)m"
    }
}

private final class AgentDashboardFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Draws and edits the reply text centered vertically with side padding,
/// since the square console field has no bezel to inset it.
private final class AgentDashboardReplyFieldCell: NSTextFieldCell {
    private static let horizontalPadding: CGFloat = 8

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let padded = rect.insetBy(dx: Self.horizontalPadding, dy: 0)
        guard let font else { return padded }
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        guard lineHeight < padded.height else { return padded }
        return NSRect(
            x: padded.minX,
            y: padded.minY + floor((padded.height - lineHeight) / 2),
            width: padded.width,
            height: lineHeight
        )
    }
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

    override var acceptsFirstResponder: Bool { true }

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
