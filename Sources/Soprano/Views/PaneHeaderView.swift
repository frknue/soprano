import AppKit

/// Header bar at the top of each pane showing title, status, and controls.
final class PaneHeaderView: NSView {
    let paneId: String
    let agentManager: AgentManager
    let themeManager: ThemeManager
    var onFocusRequested: (() -> Void)?

    private var titleLabel: NSTextField!
    private var statusDot: NSView!
    private var statusLabel: NSTextField!
    private var closeButton: NSButton!
    private var tabStackView: NSStackView!
    private var focusBar: NSView!

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
        wantsLayer = true

        let pane = agentManager.panes[paneId]
        let tab = pane?.activeTab

        focusBar = NSView()
        focusBar.wantsLayer = true
        focusBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(focusBar)

        // Status lamp
        statusDot = NSView()
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusDot)

        // Title
        titleLabel = NSTextField(labelWithString: tab?.title ?? "Pane")
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        tabStackView = NSStackView()
        tabStackView.orientation = .horizontal
        tabStackView.alignment = .centerY
        tabStackView.spacing = 2
        tabStackView.translatesAutoresizingMaskIntoConstraints = false
        tabStackView.isHidden = true
        addSubview(tabStackView)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.alignment = .right
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        // Close button
        closeButton = makeGlyphButton(
            title: "×",
            action: #selector(closePaneAction),
            toolTip: "Close active tab"
        )
        closeButton.identifier = NSUserInterfaceItemIdentifier("pane-close-button")
        addSubview(closeButton)

        // Pane containers are briefly zero-width while AppKit reparents a
        // cached split tree. Let the flexible labels collapse during that
        // transient state instead of breaking the fixed control constraints.
        let titleTrailingConstraint = titleLabel.trailingAnchor.constraint(
            lessThanOrEqualTo: statusLabel.leadingAnchor,
            constant: -8
        )
        titleTrailingConstraint.priority = .defaultHigh
        let tabsTrailingConstraint = tabStackView.trailingAnchor.constraint(
            lessThanOrEqualTo: statusLabel.leadingAnchor,
            constant: -6
        )
        tabsTrailingConstraint.priority = .defaultHigh

        NSLayoutConstraint.activate([
            // The pane frame covers the outer 2 pt when focused; the bar
            // shows as a lit segment just inside it.
            focusBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            focusBar.topAnchor.constraint(equalTo: topAnchor),
            focusBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            focusBar.widthAnchor.constraint(equalToConstant: 4),

            statusDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            statusDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 8),
            statusDot.heightAnchor.constraint(equalToConstant: 8),

            titleLabel.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleTrailingConstraint,

            tabStackView.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 6),
            tabStackView.centerYAnchor.constraint(equalTo: centerYAnchor),
            tabsTrailingConstraint,
            tabStackView.heightAnchor.constraint(equalToConstant: 24),

            statusLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -2),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 38),

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
        let isFocused = agentManager.activePaneId == paneId

        titleLabel.textColor = theme.colors.textPrimary
        titleLabel.setRetroText(tab?.title ?? "Pane", color: theme.colors.textPrimary)
        if tab?.isFilePreview == true {
            titleLabel.attributedStringValue = Self.slanted(titleLabel.attributedStringValue)
        }
        styleGlyphButton(closeButton, theme: theme)

        if let agent = tab?.agent {
            let statusColor = colorForStatus(agent.status, theme: theme)
            RetroLamp.light(statusDot, color: statusColor, lit: isLit(agent.status))
            statusLabel.textColor = statusColor
            statusLabel.setRetroText(
                agent.status.displayLabel,
                color: statusColor,
                tracking: 0,
                glow: agent.status == .running
            )
            statusLabel.isHidden = false
        } else {
            RetroLamp.light(statusDot, color: theme.colors.textMuted, lit: false)
            statusLabel.stringValue = ""
            statusLabel.isHidden = true
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

        layer?.backgroundColor = isFocused
            ? theme.colors.bgRaised.cgColor
            : theme.colors.bgPanel.cgColor
        focusBar.isHidden = !isFocused
        focusBar.layer?.backgroundColor = theme.colors.accent.cgColor
    }

    /// Closes only this pane's active tab. The last tab closes the pane, and
    /// the last pane of a layout tab takes that tab with it, so split
    /// siblings stay open.
    @objc private func closePaneAction() {
        guard let activeTab = agentManager.panes[paneId]?.activeTab else { return }
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

        let activeTabId = pane.activeTab?.id
        for (index, tab) in pane.tabs.enumerated() {
            let needsAttention = tab.agent?.needsAttention == true
            let isActive = tab.id == activeTabId
            let attentionPrefix = needsAttention ? "● " : ""
            let title = "\(attentionPrefix)\(tab.title)"
            let color = if needsAttention {
                theme.colors.blue
            } else if isActive {
                theme.colors.accent
            } else {
                theme.colors.textMuted
            }
            let button = NSButton(
                title: title,
                target: self,
                action: #selector(tabClicked(_:))
            )
            button.tag = index
            button.isBordered = false
            button.setContentHuggingPriority(.defaultLow, for: .horizontal)
            button.setButtonType(.momentaryChange)
            button.contentTintColor = color
            button.attributedTitle = tab.isFilePreview
                ? Self.slanted(RetroText.display(title, color: color))
                : RetroText.display(title, color: color)
            button.translatesAutoresizingMaskIntoConstraints = false

            let underline = NSView()
            underline.wantsLayer = true
            underline.layer?.backgroundColor = (isActive ? color : NSColor.clear).cgColor
            underline.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(underline)

            NSLayoutConstraint.activate([
                underline.heightAnchor.constraint(equalToConstant: 2),
                underline.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 3),
                underline.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -3),
                underline.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])

            tabStackView.addArrangedSubview(button)
        }
    }

    /// Preview tabs are set in italics, like Orca's; the pixel face has no
    /// italic, so the glyphs are slanted.
    private static func slanted(_ string: NSAttributedString) -> NSAttributedString {
        let slanted = NSMutableAttributedString(attributedString: string)
        slanted.addAttribute(.obliqueness, value: 0.22, range: NSRange(location: 0, length: slanted.length))
        return slanted
    }

    private func makeGlyphButton(
        title: String,
        action: Selector,
        toolTip: String
    ) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.toolTip = toolTip
        button.translatesAutoresizingMaskIntoConstraints = false
        styleGlyphButton(button, theme: themeManager.currentTheme)
        return button
    }

    /// Bakes the muted display-face glyph into the title; a disabled key
    /// dims because attributed titles ignore the control's enabled state.
    private func styleGlyphButton(_ button: NSButton, theme: AppTheme) {
        let color = button.isEnabled
            ? theme.colors.textMuted
            : theme.colors.textMuted.withAlphaComponent(0.35)
        button.contentTintColor = color
        button.attributedTitle = RetroText.display(
            button.title,
            color: color,
            size: 22,
            tracking: 0,
            alignment: .center
        )
    }

    private func isLit(_ status: AgentStatus) -> Bool {
        switch status {
        case .running, .waiting, .starting, .error: true
        case .idle, .stopped: false
        }
    }

    private func colorForStatus(_ status: AgentStatus, theme: AppTheme) -> NSColor {
        switch status {
        case .idle: return theme.colors.blue
        case .starting: return theme.colors.yellow
        case .running: return theme.colors.success
        case .waiting: return theme.colors.yellow
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
