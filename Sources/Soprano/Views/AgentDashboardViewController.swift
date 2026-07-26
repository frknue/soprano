import AppKit

/// Full-window, read-only operational view over every attached agent.
final class AgentDashboardViewController: NSViewController {
    let agentManager: AgentManager
    let themeManager: ThemeManager

    var onDismiss: (() -> Void)?
    var onAgentSelected: ((String, String) -> Void)?

    private var headerView: NSView!
    private var titleLabel: NSTextField!
    private var subtitleLabel: NSTextField!
    private var doneButton: NSButton!
    private var contentStack: NSStackView!
    private var agentRows: [AgentDashboardRowView] = []
    nonisolated(unsafe) private var elapsedTimer: Timer?
    private let observerId = "AgentDashboardViewController"

    init(agentManager: AgentManager, themeManager: ThemeManager) {
        self.agentManager = agentManager
        self.themeManager = themeManager
        super.init(nibName: nil, bundle: nil)
        agentManager.addObserver(id: observerId) { [weak self] in
            self?.refresh()
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

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrollView)

        let documentView = AgentDashboardFlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 20
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(contentStack)

        let preferredMaximumWidth = contentStack.widthAnchor.constraint(
            equalToConstant: 960
        )
        preferredMaximumWidth.priority = .defaultHigh
        let preferredFittingWidth = contentStack.widthAnchor.constraint(
            equalTo: documentView.widthAnchor,
            constant: -56
        )
        preferredFittingWidth.priority = .defaultLow

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

            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.bottomAnchor.constraint(
                greaterThanOrEqualTo: scrollView.contentView.bottomAnchor
            ),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 28),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -32),
            contentStack.centerXAnchor.constraint(equalTo: documentView.centerXAnchor),
            contentStack.widthAnchor.constraint(lessThanOrEqualToConstant: 960),
            contentStack.widthAnchor.constraint(
                lessThanOrEqualTo: documentView.widthAnchor,
                constant: -56
            ),
            preferredMaximumWidth,
            preferredFittingWidth,
            contentStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: documentView.leadingAnchor,
                constant: 28
            ),
            contentStack.trailingAnchor.constraint(
                lessThanOrEqualTo: documentView.trailingAnchor,
                constant: -28
            ),
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
        refresh()
    }

    private func refresh() {
        guard isViewLoaded else { return }
        let snapshot = agentManager.agentDashboardSnapshot()
        let theme = themeManager.currentTheme
        subtitleLabel.stringValue = monitoringSubtitle(
            agentCount: snapshot.totalCount,
            windowCount: agentManager.windowCount
        )

        for arrangedView in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(arrangedView)
            arrangedView.removeFromSuperview()
        }
        agentRows.removeAll()

        let summary = makeSummary(snapshot: snapshot, theme: theme)
        contentStack.addArrangedSubview(summary)
        summary.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true

        let sectionHeader = makeSectionHeader(
            title: "Agents",
            count: snapshot.totalCount,
            theme: theme
        )
        contentStack.addArrangedSubview(sectionHeader)
        sectionHeader.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true

        if snapshot.entries.isEmpty {
            let emptyState = makeEmptyState(theme: theme)
            contentStack.addArrangedSubview(emptyState)
            emptyState.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        } else {
            let rowsStack = NSStackView()
            rowsStack.orientation = .vertical
            rowsStack.alignment = .leading
            rowsStack.spacing = 10
            rowsStack.translatesAutoresizingMaskIntoConstraints = false
            contentStack.addArrangedSubview(rowsStack)
            rowsStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true

            for entry in snapshot.entries {
                let row = AgentDashboardRowView(entry: entry, theme: theme)
                row.onSelect = { [weak self] in
                    self?.onAgentSelected?(entry.paneId, entry.tabId)
                }
                rowsStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
                agentRows.append(row)
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

    private func makeSectionHeader(title: String, count: Int, theme: AppTheme) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.heightAnchor.constraint(equalToConstant: 22).isActive = true

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = theme.colors.textPrimary
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        let countLabel = NSTextField(labelWithString: "\(count)")
        countLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        countLabel.textColor = theme.colors.textMuted
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(countLabel)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            countLabel.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            countLabel.centerYAnchor.constraint(equalTo: label.centerYAnchor),
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

    private let theme: AppTheme
    private let elapsedLabel = NSTextField(labelWithString: "")
    private var isHovered = false

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
        onSelect?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.charactersIgnoringModifiers == " " {
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

        toolTip = "Focus \(entry.profileName) in \(location)"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(
            "\(entry.profileName), \(entry.status.displayLabel), \(location)"
        )
    }

    private func updateBackground() {
        layer?.backgroundColor = (
            isHovered ? theme.colors.bgOverlay : theme.colors.bgPanel
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

    override var acceptsFirstResponder: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard !isEscape(event) else {
            onEscape?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard !isEscape(event) else {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }

    private func isEscape(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 53 else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return !flags.contains(.command)
            && !flags.contains(.control)
            && !flags.contains(.option)
    }
}
