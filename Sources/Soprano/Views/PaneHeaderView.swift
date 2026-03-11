import AppKit

/// Header bar at the top of each pane showing title, status, and controls.
final class PaneHeaderView: NSView {
    let paneId: String
    let agentManager: AgentManager
    let themeManager: ThemeManager
    var onFocusRequested: (() -> Void)?

    private var titleLabel: NSTextField!
    private var statusDot: NSView!
    private var closeButton: NSButton!
    private var tabStackView: NSStackView!

    init(paneId: String, agentManager: AgentManager, themeManager: ThemeManager) {
        self.paneId = paneId
        self.agentManager = agentManager
        self.themeManager = themeManager
        super.init(frame: .zero)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setupViews() {
        let theme = themeManager.currentTheme
        wantsLayer = true

        let pane = agentManager.panes[paneId]
        let tab = pane?.activeTab

        // Status dot
        statusDot = NSView()
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusDot)

        let statusColor: NSColor
        if let agent = tab?.agent {
            statusColor = colorForStatus(agent.status, theme: theme)
        } else {
            statusColor = theme.colors.textMuted
        }
        statusDot.layer?.backgroundColor = statusColor.cgColor

        // Title
        titleLabel = NSTextField(labelWithString: tab?.title ?? "Pane")
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = theme.colors.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        tabStackView = NSStackView()
        tabStackView.orientation = .horizontal
        tabStackView.alignment = .centerY
        tabStackView.spacing = 2
        tabStackView.translatesAutoresizingMaskIntoConstraints = false
        tabStackView.isHidden = true
        addSubview(tabStackView)

        // Close button
        closeButton = NSButton(title: "×", target: self, action: #selector(closePaneAction))
        closeButton.isBordered = false
        closeButton.font = .systemFont(ofSize: 14, weight: .regular)
        closeButton.contentTintColor = theme.colors.textMuted
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            statusDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            statusDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 8),
            statusDot.heightAnchor.constraint(equalToConstant: 8),

            titleLabel.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -8),

            tabStackView.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 6),
            tabStackView.centerYAnchor.constraint(equalTo: centerYAnchor),
            tabStackView.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -6),
            tabStackView.heightAnchor.constraint(equalToConstant: 24),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),
        ])

        update()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isInteractiveSubview(hitTest(point)) {
            super.mouseDown(with: event)
            return
        }

        onFocusRequested?()
    }

    func update() {
        let pane = agentManager.panes[paneId]
        let tab = pane?.activeTab
        let theme = themeManager.currentTheme

        titleLabel.stringValue = tab?.title ?? "Pane"
        closeButton.contentTintColor = theme.colors.textMuted

        if let agent = tab?.agent {
            statusDot.layer?.backgroundColor = colorForStatus(agent.status, theme: theme).cgColor
        } else {
            statusDot.layer?.backgroundColor = theme.colors.textMuted.cgColor
        }

        let tabCount = pane?.tabs.count ?? 0
        let shouldShowTabs = tabCount > 1
        titleLabel.isHidden = shouldShowTabs
        tabStackView.isHidden = !shouldShowTabs
        if shouldShowTabs, let pane {
            rebuildTabButtons(for: pane, theme: theme)
        } else {
            clearTabButtons()
        }

        let isFocused = agentManager.activePaneId == paneId
        layer?.backgroundColor = isFocused
            ? theme.colors.bgRaised.cgColor
            : theme.colors.bgPanel.cgColor
    }

    @objc private func closePaneAction() {
        guard let pane = agentManager.panes[paneId],
              let activeTab = pane.activeTab
        else {
            return
        }

        agentManager.removeTabFromPane(paneId, tabId: activeTab.id)
    }

    @objc private func tabClicked(_ sender: NSButton) {
        agentManager.switchTab(paneId, index: sender.tag)
    }

    private func clearTabButtons() {
        for button in tabStackView.arrangedSubviews {
            tabStackView.removeArrangedSubview(button)
            button.removeFromSuperview()
        }
    }

    private func rebuildTabButtons(for pane: PaneState, theme: AppTheme) {
        clearTabButtons()

        let activeIndex = pane.clampedActiveIndex()
        for (index, tab) in pane.tabs.enumerated() {
            let button = NSButton(title: tab.title, target: self, action: #selector(tabClicked(_:)))
            button.tag = index
            button.isBordered = false
            button.font = .systemFont(ofSize: 11, weight: .medium)
            button.setContentHuggingPriority(.defaultLow, for: .horizontal)
            button.setButtonType(.momentaryChange)
            button.contentTintColor = index == activeIndex ? theme.colors.accent : theme.colors.textMuted
            button.translatesAutoresizingMaskIntoConstraints = false

            let underline = NSView()
            underline.wantsLayer = true
            underline.layer?.cornerRadius = 0.5
            underline.layer?.backgroundColor = (index == activeIndex ? theme.colors.accent : NSColor.clear).cgColor
            underline.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(underline)

            NSLayoutConstraint.activate([
                underline.heightAnchor.constraint(equalToConstant: 1),
                underline.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 3),
                underline.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -3),
                underline.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -1),
            ])

            tabStackView.addArrangedSubview(button)
        }
    }

    private func colorForStatus(_ status: AgentStatus, theme: AppTheme) -> NSColor {
        switch status {
        case .idle: return theme.colors.textMuted
        case .starting: return theme.colors.yellow
        case .running: return theme.colors.success
        case .error: return theme.colors.danger
        case .stopped: return theme.colors.gray
        }
    }

    private func isInteractiveSubview(_ view: NSView?) -> Bool {
        var current = view
        while let candidate = current, candidate !== self {
            if candidate is NSControl {
                return true
            }
            current = candidate.superview
        }
        return false
    }
}
