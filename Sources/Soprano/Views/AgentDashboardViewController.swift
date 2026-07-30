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
    private var headerView: NSView!
    private var titleLabel: NSTextField!
    private var subtitleLabel: NSTextField!
    private var doneButton: NSButton!
    private var summaryContainer: NSView!
    private var leftPanel: NSView!
    private var agentListTitleLabel: NSTextField!
    private var keyboardHintLabel: NSTextField!
    private var rowsStack: NSStackView!
    private var detailView: AgentDashboardDetailView!
    private var agentRows: [AgentDashboardRowView] = []
    private var entriesById: [String: AgentDashboardEntry] = [:]
    private var selectedEntryId: String?
    nonisolated(unsafe) private var elapsedTimer: Timer?
    private let observerId = "AgentDashboardViewController"

    init(
        agentManager: AgentManager,
        themeManager: ThemeManager,
        terminalStateProvider: @escaping TerminalStateProvider = { _ in .unavailable },
        promptSender: @escaping PromptSender = { _, _ in false }
    ) {
        self.agentManager = agentManager
        self.themeManager = themeManager
        self.terminalStateProvider = terminalStateProvider
        self.promptSender = promptSender
        super.init(nibName: nil, bundle: nil)
        agentManager.addObserver(id: observerId) { [weak self] change in
            switch change {
            case .model, .tabTitle:
                self?.refresh()
            case .tabWorkingDirectory, .browserURL, .markdownDocument:
                break
            }
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
        root.wantsLayer = true
        root.layer?.backgroundColor = theme.colors.bgBase.cgColor

        headerView = NSView()
        headerView.wantsLayer = true
        headerView.layer?.backgroundColor = theme.colors.bgPanel.cgColor
        headerView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(headerView)

        titleLabel = NSTextField(labelWithString: "Agent Dashboard")
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.textColor = theme.colors.textPrimary
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(titleLabel)

        subtitleLabel = NSTextField(labelWithString: "")
        subtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = theme.colors.textMuted
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(subtitleLabel)

        doneButton = NSButton(
            title: "Done",
            target: self,
            action: #selector(doneClicked)
        )
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\u{1b}"
        doneButton.keyEquivalentModifierMask = []
        doneButton.contentTintColor = theme.colors.textPrimary
        doneButton.toolTip = "Return to the workspace (Esc)"
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(doneButton)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(separator)

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
        workspaceStack.addArrangedSubview(detailView)
        detailView.widthAnchor.constraint(greaterThanOrEqualToConstant: 400).isActive = true

        NSLayoutConstraint.activate([
            headerView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            headerView.topAnchor.constraint(equalTo: root.topAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 68),

            titleLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 28),
            titleLabel.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 13),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),

            doneButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -28),
            doneButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

            separator.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: headerView.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: headerView.bottomAnchor),

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
                self.agentRows.forEach { $0.updateElapsed(now: now) }
                self.refreshDetailTerminal()
            }
        }
    }

    func apply(theme: AppTheme) {
        guard isViewLoaded else { return }
        view.layer?.backgroundColor = theme.colors.bgBase.cgColor
        headerView.layer?.backgroundColor = theme.colors.bgPanel.cgColor
        titleLabel.textColor = theme.colors.textPrimary
        subtitleLabel.textColor = theme.colors.textMuted
        doneButton.contentTintColor = theme.colors.textPrimary
        leftPanel.layer?.backgroundColor = theme.colors.bgPanel.cgColor
        leftPanel.layer?.borderColor = theme.colors.borderSubtle.cgColor
        agentListTitleLabel.textColor = theme.colors.textPrimary
        keyboardHintLabel.textColor = theme.colors.textMuted
        detailView.apply(theme: theme)
        refresh()
    }

    private func refresh() {
        guard isViewLoaded else { return }
        let snapshot = agentManager.agentDashboardSnapshot()
        let theme = themeManager.currentTheme
        let previousSelection = selectedEntryId
        entriesById = Dictionary(
            uniqueKeysWithValues: snapshot.entries.map { ($0.id, $0) }
        )
        selectedEntryId = snapshot.entries.contains {
            $0.id == previousSelection
        } ? previousSelection : snapshot.entries.first?.id
        subtitleLabel.stringValue = monitoringSubtitle(
            agentCount: snapshot.totalCount,
            windowCount: agentManager.windowCount
        )

        replaceContents(
            of: summaryContainer,
            with: makeSummary(snapshot: snapshot, theme: theme)
        )
        for arrangedView in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(arrangedView)
            arrangedView.removeFromSuperview()
        }
        agentRows.removeAll()

        if snapshot.entries.isEmpty {
            let emptyState = makeEmptyState(theme: theme)
            rowsStack.addArrangedSubview(emptyState)
            emptyState.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        } else {
            for entry in snapshot.entries {
                let row = AgentDashboardRowView(entry: entry, theme: theme)
                row.onSelect = { [weak self] in
                    self?.selectEntry(entry.id)
                }
                row.onOpen = { [weak self] in
                    self?.onAgentSelected?(entry.paneId, entry.tabId)
                }
                rowsStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
                agentRows.append(row)
            }
        }
        updateRowSelection(scrollIntoView: previousSelection != nil)
        updateDetail()
    }

    private func makeAgentListPanel(theme: AppTheme) -> NSView {
        let panel = NSView()
        panel.wantsLayer = true
        panel.layer?.backgroundColor = theme.colors.bgPanel.cgColor
        panel.layer?.borderColor = theme.colors.borderSubtle.cgColor
        panel.layer?.borderWidth = 1
        panel.layer?.cornerRadius = 10
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
            detailView.update(entry: nil, terminal: .unavailable)
            return
        }
        let target = TerminalTarget(paneId: entry.paneId, tabId: entry.tabId)
        detailView.update(
            entry: entry,
            terminal: terminalStateProvider(target)
        )
    }

    private func refreshDetailTerminal() {
        guard let selectedEntryId,
              let entry = entriesById[selectedEntryId]
        else { return }
        let target = TerminalTarget(paneId: entry.paneId, tabId: entry.tabId)
        detailView.updateTerminal(terminalStateProvider(target))
    }

    private func updateRowSelection(scrollIntoView: Bool) {
        for row in agentRows {
            let isSelected = row.entry.id == selectedEntryId
            row.setKeyboardSelected(isSelected)
            if isSelected, scrollIntoView {
                row.scrollToVisible(row.bounds)
            }
        }
    }

    private func monitoringSubtitle(agentCount: Int, windowCount: Int) -> String {
        let agentNoun = agentCount == 1 ? "agent" : "agents"
        let windowNoun = windowCount == 1 ? "window" : "windows"
        return "Monitoring \(agentCount) \(agentNoun) across \(windowCount) \(windowNoun)"
    }

    private func makeSummary(
        snapshot: AgentDashboardSnapshot,
        theme: AppTheme
    ) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fillEqually
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.heightAnchor.constraint(equalToConstant: 92).isActive = true

        let cards = [
            ("Total", snapshot.totalCount, theme.colors.accent),
            ("Working", snapshot.workingCount, theme.colors.success),
            ("Needs Input", snapshot.needsInputCount, theme.colors.yellow),
            ("Errors", snapshot.errorCount, theme.colors.danger),
        ]
        for (title, value, color) in cards {
            let card = AgentDashboardSummaryCard(
                title: title,
                value: value,
                color: color,
                theme: theme
            )
            stack.addArrangedSubview(card)
            card.heightAnchor.constraint(equalTo: stack.heightAnchor).isActive = true
        }
        return stack
    }

    private func makeSectionHeader(theme: AppTheme) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        agentListTitleLabel = NSTextField(labelWithString: "AGENTS")
        agentListTitleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        agentListTitleLabel.textColor = theme.colors.textPrimary
        agentListTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(agentListTitleLabel)

        keyboardHintLabel = NSTextField(
            labelWithString: "J/K  ·  R REPLY  ·  ↩ OPEN"
        )
        keyboardHintLabel.font = .monospacedSystemFont(ofSize: 9, weight: .medium)
        keyboardHintLabel.textColor = theme.colors.textMuted
        keyboardHintLabel.alignment = .right
        keyboardHintLabel.lineBreakMode = .byTruncatingHead
        keyboardHintLabel.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        keyboardHintLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(keyboardHintLabel)

        NSLayoutConstraint.activate([
            agentListTitleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            agentListTitleLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            keyboardHintLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: agentListTitleLabel.trailingAnchor,
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
        card.layer?.cornerRadius = 10
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

        let title = NSTextField(labelWithString: "No agents to monitor")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = theme.colors.textPrimary
        title.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(title)

        let detail = NSTextField(
            labelWithString: "Launch an agent from the sidebar or command palette."
        )
        detail.font = .systemFont(ofSize: 12)
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

private final class AgentDashboardDetailView: NSView, NSTextFieldDelegate {
    var onOpen: ((TerminalTarget) -> Void)?
    var onStop: ((TerminalTarget) -> Void)?
    var onRestart: ((TerminalTarget) -> Void)?
    var onSend: ((TerminalTarget, String) -> Bool)?

    private var theme: AppTheme
    private var entry: AgentDashboardEntry?
    private var terminal = TerminalInteractionState.unavailable

    private let titleLabel = NSTextField(labelWithString: "No agent selected")
    private let locationLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let terminalTitleLabel = NSTextField(labelWithString: "LIVE TERMINAL")
    private let terminalStateLabel = NSTextField(labelWithString: "UNAVAILABLE")
    private let replyHintLabel = NSTextField(labelWithString: "")
    private let openButton = NSButton()
    private let stopButton = NSButton()
    private let restartButton = NSButton()
    private let sendButton = NSButton()
    private let replyField = NSTextField()
    private var terminalTextView: NSTextView!

    init(theme: AppTheme) {
        self.theme = theme
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("agent-dashboard-detail")
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        build()
        apply(theme: theme)
        update(entry: nil, terminal: .unavailable)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        layer?.backgroundColor = theme.colors.bgPanel.cgColor
        layer?.borderColor = theme.colors.borderSubtle.cgColor
        titleLabel.textColor = theme.colors.textPrimary
        locationLabel.textColor = theme.colors.textMuted
        terminalTitleLabel.textColor = theme.colors.textPrimary
        replyHintLabel.textColor = theme.colors.textMuted
        terminalTextView.backgroundColor = theme.colors.bgBase
        terminalTextView.insertionPointColor = theme.colors.textPrimary
        replyField.backgroundColor = theme.colors.bgBase
        replyField.textColor = theme.colors.textPrimary
        [openButton, stopButton, restartButton, sendButton].forEach {
            $0.contentTintColor = theme.colors.textPrimary
        }
        refreshStatusColors()
        updateTerminalText()
    }

    func update(
        entry: AgentDashboardEntry?,
        terminal: TerminalInteractionState
    ) {
        let previousId = self.entry?.id
        self.entry = entry
        self.terminal = terminal
        if entry?.id != previousId {
            replyField.stringValue = ""
        }

        guard let entry else {
            titleLabel.stringValue = "No agent selected"
            locationLabel.stringValue = "Choose an agent to inspect its terminal."
            statusLabel.stringValue = ""
            updateTerminalText()
            updateControls()
            return
        }

        titleLabel.stringValue = entry.profileName
        let location = "\(entry.windowTitle) ▸ \(entry.tabTitle)"
        let path = entry.cwd.map { ($0 as NSString).abbreviatingWithTildeInPath }
        locationLabel.stringValue = [location, path]
            .compactMap { $0 }
            .joined(separator: "  ·  ")
        statusLabel.stringValue = entry.status.displayLabel
        replyField.placeholderString = "Reply to \(entry.profileName)…"
        refreshStatusColors()
        updateTerminalText()
        updateControls()
    }

    func updateTerminal(_ terminal: TerminalInteractionState) {
        guard entry != nil, terminal != self.terminal else { return }
        self.terminal = terminal
        updateTerminalText()
        updateControls()
    }

    func focusReply() {
        guard replyField.isEnabled else { return }
        window?.makeFirstResponder(replyField)
    }

    func controlTextDidChange(_ notification: Notification) {
        updateSendButton()
    }

    private func build() {
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        locationLabel.font = .systemFont(ofSize: 11)
        locationLabel.lineBreakMode = .byTruncatingMiddle
        locationLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(locationLabel)

        statusLabel.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        statusLabel.alignment = .right
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        configureButton(
            openButton,
            title: "Open",
            identifier: "agent-dashboard-open",
            action: #selector(openClicked)
        )
        configureButton(
            stopButton,
            title: "Stop",
            identifier: "agent-dashboard-stop",
            action: #selector(stopClicked)
        )
        configureButton(
            restartButton,
            title: "Restart",
            identifier: "agent-dashboard-restart",
            action: #selector(restartClicked)
        )

        let actionStack = NSStackView(views: [
            openButton,
            stopButton,
            restartButton,
        ])
        actionStack.orientation = .horizontal
        actionStack.alignment = .centerY
        actionStack.spacing = 8
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(actionStack)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        terminalTitleLabel.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        terminalTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminalTitleLabel)

        terminalStateLabel.font = .monospacedSystemFont(ofSize: 9, weight: .semibold)
        terminalStateLabel.alignment = .right
        terminalStateLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminalStateLabel)

        let terminalScrollView = NSTextView.scrollableTextView()
        terminalScrollView.identifier = NSUserInterfaceItemIdentifier(
            "agent-dashboard-terminal"
        )
        terminalScrollView.borderType = .noBorder
        terminalScrollView.drawsBackground = true
        terminalScrollView.hasVerticalScroller = true
        terminalScrollView.hasHorizontalScroller = false
        terminalScrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminalScrollView)

        terminalTextView = terminalScrollView.documentView as? NSTextView
        terminalTextView.isEditable = false
        terminalTextView.isSelectable = true
        terminalTextView.isRichText = true
        terminalTextView.importsGraphics = false
        terminalTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        terminalTextView.textContainerInset = NSSize(width: 10, height: 10)
        terminalTextView.textContainer?.widthTracksTextView = true

        replyField.identifier = NSUserInterfaceItemIdentifier(
            "agent-dashboard-reply"
        )
        replyField.font = .systemFont(ofSize: 12)
        replyField.focusRingType = .default
        replyField.delegate = self
        replyField.target = self
        replyField.action = #selector(sendClicked)
        replyField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(replyField)

        configureButton(
            sendButton,
            title: "Send",
            identifier: "agent-dashboard-send",
            action: #selector(sendClicked)
        )
        addSubview(sendButton)

        replyHintLabel.font = .systemFont(ofSize: 10)
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
            locationLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),

            actionStack.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            actionStack.topAnchor.constraint(equalTo: locationLabel.bottomAnchor, constant: 14),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: actionStack.bottomAnchor, constant: 16),

            terminalTitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            terminalTitleLabel.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 14),
            terminalStateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            terminalStateLabel.centerYAnchor.constraint(equalTo: terminalTitleLabel.centerYAnchor),

            terminalScrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            terminalScrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            terminalScrollView.topAnchor.constraint(
                equalTo: terminalTitleLabel.bottomAnchor,
                constant: 9
            ),
            terminalScrollView.bottomAnchor.constraint(
                equalTo: replyField.topAnchor,
                constant: -14
            ),
            terminalScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),

            replyField.leadingAnchor.constraint(equalTo: terminalScrollView.leadingAnchor),
            replyField.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -8),
            replyField.heightAnchor.constraint(equalToConstant: 30),

            sendButton.trailingAnchor.constraint(equalTo: terminalScrollView.trailingAnchor),
            sendButton.centerYAnchor.constraint(equalTo: replyField.centerYAnchor),
            sendButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 70),

            replyHintLabel.leadingAnchor.constraint(equalTo: replyField.leadingAnchor),
            replyHintLabel.trailingAnchor.constraint(equalTo: sendButton.trailingAnchor),
            replyHintLabel.topAnchor.constraint(equalTo: replyField.bottomAnchor, constant: 6),
            replyHintLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -13),
        ])
    }

    private func configureButton(
        _ button: NSButton,
        title: String,
        identifier: String,
        action: Selector
    ) {
        button.title = title
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.translatesAutoresizingMaskIntoConstraints = false
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
                font: .monospacedSystemFont(ofSize: 11, weight: .regular)
            )
        } else {
            attributedText = NSAttributedString(
                string: displayText,
                attributes: [
                    .font: NSFont.monospacedSystemFont(
                        ofSize: 11,
                        weight: .regular
                    ),
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
        terminalStateLabel.stringValue = terminal.isAvailable ? "LIVE" : "UNAVAILABLE"
        terminalStateLabel.textColor = terminal.isAvailable
            ? theme.colors.success
            : theme.colors.textMuted
    }

    private func refreshStatusColors() {
        guard let entry else {
            statusLabel.textColor = theme.colors.textMuted
            return
        }
        statusLabel.textColor = Self.statusColor(for: entry, theme: theme)
    }

    private func updateControls() {
        replyHintLabel.textColor = theme.colors.textMuted
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

private final class AgentDashboardSummaryCard: NSView {
    init(title: String, value: Int, color: NSColor, theme: AppTheme) {
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier(
            "agent-dashboard-summary-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))"
        )
        wantsLayer = true
        layer?.backgroundColor = theme.colors.bgPanel.cgColor
        layer?.borderColor = theme.colors.borderSubtle.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 10

        let valueLabel = NSTextField(labelWithString: "\(value)")
        valueLabel.font = .monospacedSystemFont(ofSize: 25, weight: .semibold)
        valueLabel.textColor = value == 0 ? theme.colors.textMuted : color
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(valueLabel)

        let titleLabel = NSTextField(labelWithString: title.uppercased())
        titleLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        titleLabel.textColor = theme.colors.textMuted
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            valueLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            valueLabel.topAnchor.constraint(equalTo: topAnchor, constant: 15),
            titleLabel.leadingAnchor.constraint(equalTo: valueLabel.leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: 5),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

private final class AgentDashboardRowView: NSControl {
    let entry: AgentDashboardEntry
    var onSelect: (() -> Void)?
    var onOpen: (() -> Void)?

    private let theme: AppTheme
    private let elapsedLabel = NSTextField(labelWithString: "")
    private var isHovered = false
    private var isKeyboardSelected = false

    init(entry: AgentDashboardEntry, theme: AppTheme) {
        self.entry = entry
        self.theme = theme
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("agent-dashboard-row")
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 72).isActive = true
        setup()
        updateElapsed(now: Date())
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

    func updateElapsed(now: Date) {
        elapsedLabel.stringValue = Self.elapsedText(
            status: entry.status,
            startedAt: entry.startedAt,
            now: now
        )
    }

    func setKeyboardSelected(_ isSelected: Bool) {
        guard isKeyboardSelected != isSelected else { return }
        isKeyboardSelected = isSelected
        layer?.borderWidth = isSelected ? 2 : 1
        layer?.borderColor = (
            isSelected
                ? theme.colors.accent
                : entry.needsAttention
                    ? theme.colors.blue
                    : theme.colors.borderSubtle
        ).cgColor
        updateBackground()
    }

    private func setup() {
        let statusColor = Self.statusColor(for: entry, theme: theme)
        layer?.borderColor = (
            entry.needsAttention
                ? theme.colors.blue
                : theme.colors.borderSubtle
        ).cgColor
        updateBackground()

        let iconContainer = NSView()
        iconContainer.wantsLayer = true
        iconContainer.layer?.backgroundColor = statusColor.withAlphaComponent(0.13).cgColor
        iconContainer.layer?.cornerRadius = 8
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconContainer)

        let icon = NSImageView()
        let profileIcon = AgentCatalog.profile(for: entry.profileId)?.icon ?? "command.square"
        icon.image = NSImage(
            systemSymbolName: profileIcon,
            accessibilityDescription: entry.profileName
        ) ?? NSImage(
            systemSymbolName: "command.square",
            accessibilityDescription: entry.profileName
        )
        icon.contentTintColor = statusColor
        icon.symbolConfiguration = .init(pointSize: 15, weight: .medium)
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.addSubview(icon)

        let titleLabel = NSTextField(labelWithString: entry.profileName)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = theme.colors.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        let location = "\(entry.windowTitle) ▸ \(entry.tabTitle)"
        let path = entry.cwd.map { ($0 as NSString).abbreviatingWithTildeInPath }
        let details = [location, path].compactMap { $0 }.joined(separator: "  ·  ")
        let detailLabel = NSTextField(labelWithString: details)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = theme.colors.textMuted
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(detailLabel)

        let statusLabel = NSTextField(labelWithString: entry.status.displayLabel)
        statusLabel.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        statusLabel.textColor = statusColor
        statusLabel.alignment = .right
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        elapsedLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        elapsedLabel.textColor = theme.colors.textMuted
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
            iconContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconContainer.widthAnchor.constraint(equalToConstant: 36),
            iconContainer.heightAnchor.constraint(equalToConstant: 36),

            icon.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),

            titleLabel.leadingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 17),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusLabel.leadingAnchor, constant: -16),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusLabel.leadingAnchor, constant: -16),

            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 10),
            chevron.heightAnchor.constraint(equalToConstant: 14),

            statusLabel.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -14),
            statusLabel.topAnchor.constraint(equalTo: topAnchor, constant: 17),
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 82),

            elapsedLabel.trailingAnchor.constraint(equalTo: statusLabel.trailingAnchor),
            elapsedLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 5),
        ])

        toolTip = "Select \(entry.profileName); double-click to open it"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(
            "\(entry.profileName), \(entry.status.displayLabel), \(location)"
        )
    }

    private func updateBackground() {
        layer?.backgroundColor = (
            isKeyboardSelected
                ? theme.colors.bgSelected
                : isHovered
                    ? theme.colors.bgOverlay
                    : theme.colors.bgPanel
        ).cgColor
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

private final class AgentDashboardRootView: NSView {
    var onEscape: (() -> Void)?
    var onMoveSelection: ((Int) -> Void)?
    var onActivateSelection: (() -> Void)?
    var onFocusReply: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let action = keyboardAction(for: event) {
            perform(action)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard let action = keyboardAction(for: event) else {
            super.keyDown(with: event)
            return
        }
        perform(action)
    }

    private enum KeyboardAction {
        case dismiss
        case move(Int)
        case activate
        case focusReply
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
        default:
            break
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "j":
            return .move(1)
        case "k":
            return .move(-1)
        case "r":
            return .focusReply
        case " ":
            return .activate
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
        }
    }
}
