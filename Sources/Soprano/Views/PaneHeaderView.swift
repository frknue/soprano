import AppKit

/// Header bar at the top of each pane: status mark, title (or the pane tabs),
/// the UPPERCASE status word and the close button.
///
/// Folio (direction §6): the focused pane's header is `raised` with an ink
/// Medium title and a 2 pt `focusMark` rule on its bottom edge; every other
/// header sits on `bgPanel` with a muted title. NEEDS INPUT and ERROR wash
/// the header in their status color, an attention pane in `attentionWash`.
/// The attention frame itself belongs to `PaneContainerView`.
final class PaneHeaderView: NSView {
    static let height: CGFloat = 28

    let paneId: String
    let agentManager: AgentManager
    let themeManager: ThemeManager
    var onFocusRequested: (() -> Void)?

    private let statusMark = ChromeStatusMark(shape: .idle)
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let tabStackView = NSStackView()
    private let bottomRule = ChromeRuleView(axis: .horizontal)
    private let focusRule = ChromeRuleView(axis: .horizontal, thickness: Chrome.focusMarkWidth)
    private var closeButton: ChromeIconButton!

    init(paneId: String, agentManager: AgentManager, themeManager: ThemeManager) {
        self.paneId = paneId
        self.agentManager = agentManager
        self.themeManager = themeManager
        super.init(frame: .zero)
        setupViews()
        // The focus rule leaves while another of the app's windows (the
        // command palette, an alert) is key, the same moment the terminal
        // cursor turns hollow.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(keyWindowDidChange(_:)),
                name: name,
                object: nil
            )
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Whether the 2 pt focus rule shows (for tests and the harness).
    var showsFocusMark: Bool { !focusRule.isHidden }

    private func setupViews() {
        wantsLayer = true

        addSubview(statusMark)

        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        tabStackView.orientation = .horizontal
        tabStackView.alignment = .top
        tabStackView.spacing = 2
        tabStackView.translatesAutoresizingMaskIntoConstraints = false
        tabStackView.isHidden = true
        addSubview(tabStackView)

        statusLabel.alignment = .right
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        closeButton = ChromeIconButton(
            symbolName: "xmark",
            accessibilityLabel: "Close active tab",
            pointSize: 11,
            size: 20,
            target: self,
            action: #selector(closePaneAction)
        )
        closeButton.identifier = NSUserInterfaceItemIdentifier("pane-close-button")
        addSubview(closeButton)

        addSubview(bottomRule)
        addSubview(focusRule)

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
            constant: -8
        )
        tabsTrailingConstraint.priority = .defaultHigh

        NSLayoutConstraint.activate([
            statusMark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            statusMark.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -Chrome.hairline / 2),

            titleLabel.leadingAnchor.constraint(equalTo: statusMark.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: statusMark.centerYAnchor),
            titleTrailingConstraint,

            // Pane tabs fill the header above its bottom rule, so the active
            // tab's ink underline sits on that rule.
            tabStackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            tabStackView.topAnchor.constraint(equalTo: topAnchor),
            tabStackView.bottomAnchor.constraint(equalTo: bottomRule.topAnchor),
            tabsTrailingConstraint,

            statusLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),
            statusLabel.centerYAnchor.constraint(equalTo: statusMark.centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: statusMark.centerYAnchor),

            bottomRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomRule.bottomAnchor.constraint(equalTo: bottomAnchor),

            // The focus rule covers the hairline and one point above it.
            focusRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            focusRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            focusRule.bottomAnchor.constraint(equalTo: bottomAnchor),
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
        let colors = themeManager.currentTheme.colors
        let isFocused = agentManager.activePaneId == paneId
        let needsAttention = pane?.tabs.contains { $0.agent?.needsAttention == true } ?? false

        let status = headerStatus(for: tab)
        statusMark.set(status: status, colors: colors)
        if status.label.isEmpty {
            statusLabel.stringValue = ""
            statusLabel.isHidden = true
        } else {
            statusLabel.setStatusText(status.label, color: status.color(in: colors))
            statusLabel.isHidden = false
        }

        titleLabel.setChromeText(
            tab?.title ?? "Pane",
            font: isFocused ? ChromeFont.labelStrong : ChromeFont.label,
            color: isFocused ? colors.textPrimary : colors.textMuted
        )
        if tab?.isFilePreview == true {
            titleLabel.attributedStringValue = Self.slanted(titleLabel.attributedStringValue)
        }
        closeButton.apply(theme: themeManager.currentTheme)

        // Pane tabs replace the mark and title; the running or attention
        // prefix on each tab carries what the mark would say.
        let tabCount = pane?.tabs.count ?? 0
        let shouldShowTabs = tabCount > 1
        titleLabel.isHidden = shouldShowTabs
        statusMark.isHidden = shouldShowTabs
        tabStackView.isHidden = !shouldShowTabs
        if shouldShowTabs, let pane {
            rebuildTabButtons(for: pane, colors: colors)
        } else {
            clearTabButtons()
        }

        layer?.backgroundColor = Self.background(
            status: status,
            isFocused: isFocused,
            needsAttention: needsAttention,
            colors: colors
        ).cgColor
        bottomRule.color = colors.borderSubtle
        focusRule.color = colors.focusMark
        refreshFocusMark()
    }

    /// Header fill, in components.css precedence: a NEEDS INPUT or ERROR
    /// wash, then the attention wash, then `raised` for focus, else bgPanel.
    /// Washes are composited onto bgPanel so the header stays opaque.
    static func background(
        status: ChromeStatus,
        isFocused: Bool,
        needsAttention: Bool,
        colors: ThemeColors
    ) -> NSColor {
        let wash = status.headerWash(in: colors) ?? (needsAttention ? colors.attentionWash : nil)
        if let wash {
            return colors.bgPanel.mixed(
                with: wash.withAlphaComponent(1),
                fraction: wash.alphaComponent
            )
        }
        return isFocused ? colors.raised : colors.bgPanel
    }

    private func refreshFocusMark() {
        focusRule.isHidden = agentManager.activePaneId != paneId || isBehindOverlay
    }

    /// Another of the app's windows is key: the palette, an alert or a
    /// sheet sits in front of this pane's window.
    private var isBehindOverlay: Bool {
        guard let window, let keyWindow = NSApplication.shared.keyWindow else { return false }
        return keyWindow !== window
    }

    @objc private func keyWindowDidChange(_ notification: Notification) {
        refreshFocusMark()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshFocusMark()
    }

    /// The header's status: an agent's own status, a cyan RUNNING for a
    /// shell running a command, otherwise the idle shell mark.
    private func headerStatus(for tab: PaneTab?) -> ChromeStatus {
        if let agent = tab?.agent {
            return agent.status.chromeStatus
        }
        if let tab, agentManager.isRunningCommand(tab, in: paneId) {
            return .running
        }
        return .idle
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

    private func rebuildTabButtons(for pane: PaneState, colors: ThemeColors) {
        clearTabButtons()

        let activeTabId = pane.activeTab?.id
        for (index, tab) in pane.tabs.enumerated() {
            let isActive = tab.id == activeTabId
            // Attention wins over a running command; either is a dot before
            // the title, which keeps its active or muted ink.
            let prefixColor: NSColor? = if tab.agent?.needsAttention == true {
                colors.attention
            } else if agentManager.isRunningCommand(tab, in: pane.id) {
                colors.runningCommand
            } else {
                nil
            }
            let label = NSMutableAttributedString()
            if let prefixColor {
                label.append(ChromeText.attributed("● ", font: ChromeFont.meta, color: prefixColor))
            }
            label.append(ChromeText.attributed(
                tab.title,
                font: isActive ? ChromeFont.labelStrong : ChromeFont.label,
                color: isActive ? colors.textPrimary : colors.textMuted
            ))

            let button = PaneTabButton(
                title: tab.isFilePreview ? Self.slanted(label) : label,
                underline: isActive ? colors.textPrimary : nil,
                target: self,
                action: #selector(tabClicked(_:))
            )
            button.tag = index
            if tab.agent?.needsAttention == true {
                button.toolTip = "Needs attention"
            } else if prefixColor != nil {
                button.toolTip = "Running a command"
            }
            tabStackView.addArrangedSubview(button)
            button.heightAnchor.constraint(equalTo: tabStackView.heightAnchor).isActive = true
        }
    }

    /// Preview tabs are set in italics, like Orca's.
    private static func slanted(_ string: NSAttributedString) -> NSAttributedString {
        let slanted = NSMutableAttributedString(attributedString: string)
        slanted.addAttribute(.obliqueness, value: 0.22, range: NSRange(location: 0, length: slanted.length))
        return slanted
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

/// One pane tab: 8 pt side padding, and for the active tab a 2 pt ink
/// underline inset by that padding on the tab's bottom edge.
private final class PaneTabButton: NSButton {
    static let padding: CGFloat = 8

    private let underlineColor: NSColor?

    init(title: NSAttributedString, underline: NSColor?, target: AnyObject, action: Selector) {
        underlineColor = underline
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        setButtonType(.momentaryChange)
        attributedTitle = title
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: ceil(attributedTitle.size().width) + Self.padding * 2,
            height: NSView.noIntrinsicMetric
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let underlineColor else { return }
        underlineColor.setFill()
        let rect = NSRect(
            x: bounds.minX + Self.padding,
            y: isFlipped ? bounds.maxY - Chrome.focusMarkWidth : bounds.minY,
            width: max(0, bounds.width - Self.padding * 2),
            height: Chrome.focusMarkWidth
        )
        NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
    }
}
