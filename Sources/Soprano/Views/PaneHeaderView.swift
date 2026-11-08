import AppKit

/// Header bar at the top of each pane, in Soprano Agents' header language:
/// the pane kind's symbol and title (or the pane tabs as Agents tabs), the
/// Agents status pill (Working / Approval / Input / Done / Failed, Running
/// for a shell running a command) and a ghost close button.
///
/// The focused pane's header sits on `card` with a medium ink title and a
/// 2 pt `primary` focus rule on its bottom edge; every other header sits on
/// `background` with a muted title. A pane that waits on a person or failed
/// is washed in its status tone. The attention frame itself belongs to
/// `PaneContainerView`.
final class PaneHeaderView: NSView {
    static let height: CGFloat = 28
    static let titleSize: CGFloat = 13

    let paneId: String
    let agentManager: AgentManager
    let themeManager: ThemeManager
    var onFocusRequested: (() -> Void)?

    private let kindIcon = NSImageView()
    private let titleLabel = NSTextField.label("", size: PaneHeaderView.titleSize)
    private let statusPill = ShellStatusPillView()
    private let tabStackView = NSStackView()
    private let bottomRule = NSView()
    private let focusRule = NSView()
    private var closeButton: ShellGhostButton!
    private var tabButtons: [(id: String, button: PaneTabButton)] = []

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
        PaletteCenter.shared.addObserver(self) { [weak self] _ in self?.update() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Whether the 2 pt focus rule shows (for tests and the harness).
    var showsFocusMark: Bool { !focusRule.isHidden }

    /// The status pill's current pill (for tests and the harness).
    var statusPillValue: ShellStatusPill? { statusPill.isHidden ? nil : statusPill.pill }

    private func setupViews() {
        wantsLayer = true

        kindIcon.imageScaling = .scaleNone
        kindIcon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(kindIcon)

        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        tabStackView.orientation = .horizontal
        tabStackView.alignment = .centerY
        tabStackView.spacing = 2
        // Like Agents' tab strip, tabs share the room and truncate their
        // titles instead of dropping off: a gravity-area stack detaches the
        // views that do not fit.
        tabStackView.distribution = .fill
        tabStackView.setClippingResistancePriority(.defaultLow, for: .horizontal)
        tabStackView.translatesAutoresizingMaskIntoConstraints = false
        tabStackView.isHidden = true
        addSubview(tabStackView)

        statusPill.label.identifier = NSUserInterfaceItemIdentifier("pane-status-label")
        statusPill.setContentHuggingPriority(.required, for: .horizontal)
        statusPill.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusPill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusPill)

        closeButton = ShellGhostButton(
            symbol: "xmark",
            label: "Close active tab",
            size: 20,
            symbolSize: 10,
            target: self,
            action: #selector(closePaneAction)
        )
        closeButton.identifier = NSUserInterfaceItemIdentifier("pane-close-button")
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        for rule in [bottomRule, focusRule] {
            rule.wantsLayer = true
            rule.translatesAutoresizingMaskIntoConstraints = false
            addSubview(rule)
        }

        // Pane containers are briefly zero-width while AppKit reparents a
        // cached split tree. Let the flexible labels collapse during that
        // transient state instead of breaking the fixed control constraints.
        let titleTrailingConstraint = titleLabel.trailingAnchor.constraint(
            lessThanOrEqualTo: statusPill.leadingAnchor,
            constant: -8
        )
        titleTrailingConstraint.priority = .defaultHigh
        let tabsTrailingConstraint = tabStackView.trailingAnchor.constraint(
            lessThanOrEqualTo: statusPill.leadingAnchor,
            constant: -8
        )
        tabsTrailingConstraint.priority = .defaultHigh

        NSLayoutConstraint.activate([
            kindIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            kindIcon.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -0.5),
            kindIcon.widthAnchor.constraint(equalToConstant: 16),

            titleLabel.leadingAnchor.constraint(equalTo: kindIcon.trailingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: kindIcon.centerYAnchor),
            titleTrailingConstraint,

            tabStackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            tabStackView.centerYAnchor.constraint(equalTo: kindIcon.centerYAnchor),
            tabStackView.heightAnchor.constraint(equalToConstant: 22),
            tabsTrailingConstraint,

            statusPill.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6),
            statusPill.centerYAnchor.constraint(equalTo: kindIcon.centerYAnchor),
            statusPill.heightAnchor.constraint(equalToConstant: 20),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: kindIcon.centerYAnchor),

            bottomRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomRule.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomRule.heightAnchor.constraint(equalToConstant: 1),

            // The focus rule covers the hairline and one point above it.
            focusRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            focusRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            focusRule.bottomAnchor.constraint(equalTo: bottomAnchor),
            focusRule.heightAnchor.constraint(equalToConstant: Chrome.focusMarkWidth),
        ])

        update()
    }

    override func mouseDown(with event: NSEvent) {
        // `hitTest` takes a point in the superview's coordinates.
        if let superview, isInteractiveSubview(hitTest(superview.convert(event.locationInWindow, from: nil))) {
            super.mouseDown(with: event)
            return
        }

        onFocusRequested?()
    }

    func update() {
        let pane = agentManager.panes[paneId]
        let tab = pane?.activeTab
        let palette = PaletteCenter.shared.palette
        let isFocused = agentManager.activePaneId == paneId
        let needsAttention = pane?.tabs.contains { $0.agent?.needsAttention == true } ?? false

        let pill = headerPill(for: tab)
        statusPill.configure(pill)
        statusPill.isHidden = pill == nil

        kindIcon.image = NSImage.symbol(Self.symbol(for: tab), size: 12.5)
        kindIcon.contentTintColor = isFocused ? palette.foreground : palette.mutedForeground
        let title = NSMutableAttributedString(string: tab?.title ?? "Pane", attributes: [
            .font: Typography.ui(Self.titleSize, weight: isFocused ? .medium : .regular),
            .foregroundColor: isFocused ? palette.foreground : palette.mutedForeground,
        ])
        if tab?.isFilePreview == true {
            title.addAttribute(.obliqueness, value: 0.22, range: NSRange(location: 0, length: title.length))
        }
        titleLabel.attributedStringValue = title

        // Pane tabs replace the symbol and title; the running or attention
        // prefix on each tab carries what the pill would say.
        let tabCount = pane?.tabs.count ?? 0
        let shouldShowTabs = tabCount > 1
        titleLabel.isHidden = shouldShowTabs
        kindIcon.isHidden = shouldShowTabs
        tabStackView.isHidden = !shouldShowTabs
        if shouldShowTabs, let pane {
            rebuildTabButtons(for: pane, palette: palette)
        } else {
            clearTabButtons()
        }

        layer?.backgroundColor = Self.background(
            tone: pill.flatMap(Self.washTone),
            isFocused: isFocused,
            needsAttention: needsAttention,
            palette: palette
        ).cgColor
        bottomRule.layer?.backgroundColor = palette.border.cgColor
        focusRule.layer?.backgroundColor = palette.primary.cgColor
        refreshFocusMark()
    }

    /// Statuses that wash the header: someone has to answer, or it failed.
    private static func washTone(_ pill: ShellStatusPill) -> ThreadStatusTone? {
        switch pill.tone {
        case .approval, .input, .failed: pill.tone
        case .working, .done, .muted: nil
        }
    }

    /// Header fill: a 10 % wash of a waiting or failed status's tone, then
    /// a 10 % warning wash for an attention pane, then `card` for focus,
    /// else `background`. Washes are composited so the header stays opaque.
    static func background(
        tone: ThreadStatusTone?,
        isFocused: Bool,
        needsAttention: Bool,
        palette: Palette
    ) -> NSColor {
        let base = isFocused ? palette.card : palette.background
        if let tone {
            return base.mixed(with: palette.color(for: tone), fraction: 0.10)
        }
        if needsAttention {
            return base.mixed(with: palette.color(for: .approval), fraction: 0.10)
        }
        return base
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

    /// The header's pill: an agent's own status, Running for a shell running
    /// a command, otherwise none.
    private func headerPill(for tab: PaneTab?) -> ShellStatusPill? {
        guard let tab else { return nil }
        return ShellStatusPill.of(agent: tab.agent, runsCommand: agentManager.isRunningCommand(tab, in: paneId))
    }

    /// The pane kind's SF Symbol. Documents are browser-type tabs, so a diff
    /// (`plus.forwardslash.minus`) and a file or Markdown file (`doc.text`)
    /// are told apart before the browser's globe, as the sidebar rows do.
    static func symbol(for tab: PaneTab?) -> String {
        guard let tab else { return Icon.terminal }
        if tab.isChat { return "bubble.left.and.text.bubble.right" }
        if tab.agent != nil { return Icon.subagent }
        if tab.isDiff { return "plus.forwardslash.minus" }
        if tab.isMarkdown || tab.isEditor || tab.isFilePreview { return Icon.fileText }
        if tab.type == .browser { return Icon.globe }
        return Icon.terminal
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
        for entry in tabButtons {
            tabStackView.removeArrangedSubview(entry.button)
            entry.button.removeFromSuperview()
        }
        tabButtons = []
    }

    /// Reuses each tab's button while its tab lives: agents notify throughout
    /// a run, and a rebuild on every update would drop the hovered tab's
    /// close button under the pointer.
    private func rebuildTabButtons(for pane: PaneState, palette: Palette) {
        let tabIds = pane.tabs.map(\.id)
        if tabButtons.map(\.id) != tabIds {
            clearTabButtons()
            tabButtons = pane.tabs.map { tab in
                let button = PaneTabButton(
                    tabId: tab.id,
                    target: self,
                    action: #selector(tabClicked(_:)),
                    onClose: { [weak self] in
                        guard let self else { return }
                        self.agentManager.removeTabFromPane(self.paneId, tabId: tab.id)
                    }
                )
                tabStackView.addArrangedSubview(button)
                button.heightAnchor.constraint(equalTo: tabStackView.heightAnchor).isActive = true
                // A tab never shrinks below its close button and a few letters.
                button.widthAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
                return (tab.id, button)
            }
        }

        let activeTabId = pane.activeTab?.id
        for (index, tab) in pane.tabs.enumerated() where index < tabButtons.count {
            let button = tabButtons[index].button
            let isActive = tab.id == activeTabId
            // Attention wins over a running command; either is a dot before
            // the title, which keeps its active or muted ink.
            let prefixColor: NSColor? = if tab.agent?.needsAttention == true {
                palette.color(for: .approval)
            } else if agentManager.isRunningCommand(tab, in: pane.id) {
                palette.color(for: .working)
            } else {
                nil
            }
            button.tag = index
            button.configure(
                title: tab.title,
                prefixColor: prefixColor,
                isActive: isActive,
                slanted: tab.isFilePreview
            )
            if tab.agent?.needsAttention == true {
                button.toolTip = "Needs attention"
            } else if prefixColor != nil {
                button.toolTip = "Running a command"
            } else {
                button.toolTip = tab.title
            }
        }
    }

    private func isInteractiveSubview(_ view: NSView?) -> Bool {
        var current = view
        while let candidate = current, candidate !== self {
            // A control that acts on clicks; labels (also `NSControl`s) pass
            // theirs on and still focus the pane.
            if let control = candidate as? NSControl, control.action != nil {
                return true
            }
            current = candidate.superview
        }
        return false
    }
}

/// One pane tab, an Agents tab (`rounded-md`, `accent` when active,
/// `accent/60` under the pointer): the title with 8 pt side padding and its
/// own close button. The close button reserves its place on every tab so
/// widths never jump, and shows on the active tab and under the pointer.
private final class PaneTabButton: NSButton {
    static let padding: CGFloat = 8
    static let closeSize: CGFloat = 14
    static let closeGap: CGFloat = 4

    private let closeButton = ShellGhostButton(
        symbol: "xmark",
        label: "Close Tab",
        size: PaneTabButton.closeSize,
        symbolSize: 8,
        weight: .semibold
    )
    private let onClose: () -> Void
    private var trackingArea: NSTrackingArea?
    private var tabTitle = ""
    private var prefixColor: NSColor?
    private var slanted = false

    private(set) var isSelectedTab = false
    private(set) var isHovered = false

    init(tabId: String, target: AnyObject, action: Selector, onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init(frame: .zero)
        // The title sits in a rect that leaves the close button its corner.
        // Swapping the cell drops target and action, so it goes first.
        cell = TabPillButtonCell()
        self.target = target
        self.action = action
        identifier = NSUserInterfaceItemIdentifier("pane-tab-\(tabId)")
        isBordered = false
        refusesFirstResponder = true
        setButtonType(.momentaryChange)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        translatesAutoresizingMaskIntoConstraints = false

        closeButton.identifier = NSUserInterfaceItemIdentifier("close-pane-tab-\(tabId)")
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.translatesAutoresizingMaskIntoConstraints = true
        addSubview(closeButton)
        updateCloseButton()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(title: String, prefixColor: NSColor?, isActive: Bool, slanted: Bool) {
        tabTitle = title
        self.prefixColor = prefixColor
        self.slanted = slanted
        isSelectedTab = isActive
        render()
        updateCloseButton()
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    private func render() {
        let label = NSMutableAttributedString()
        if let prefixColor {
            label.append(NSAttributedString(string: "● ", attributes: [
                .font: Typography.ui(Typography.tinySize), .foregroundColor: prefixColor,
            ]))
        }
        label.append(NSAttributedString(string: tabTitle, attributes: [
            .font: Typography.ui(Typography.smallSize, weight: isSelectedTab ? .medium : .regular),
            .foregroundColor: ShellTabStyle.textColor(isActive: isSelectedTab, isHovered: isHovered),
        ]))
        // A long title truncates before it reaches the close button.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        label.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: label.length))
        if slanted {
            label.addAttribute(.obliqueness, value: 0.22, range: NSRange(location: 0, length: label.length))
        }
        attributedTitle = label
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: ceil(attributedTitle.size().width) + Self.padding * 2
                + Self.closeGap + Self.closeSize,
            height: NSView.noIntrinsicMetric
        )
    }

    override func layout() {
        super.layout()
        closeButton.frame = NSRect(
            x: bounds.maxX - 4 - Self.closeSize,
            y: floor(bounds.midY - Self.closeSize / 2),
            width: Self.closeSize,
            height: Self.closeSize
        )
        (cell as? TabPillButtonCell)?.titleFrame = NSRect(
            x: Self.padding,
            y: 0,
            width: max(0, closeButton.frame.minX - Self.closeGap - Self.padding),
            height: bounds.height
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        ShellTabStyle.draw(isActive: isSelectedTab, isHovered: isHovered, in: bounds)
        super.draw(dirtyRect)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { setHovered(false) }
    }

    private func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        render()
        updateCloseButton()
        needsDisplay = true
    }

    private func updateCloseButton() {
        closeButton.isHidden = !(isSelectedTab || isHovered)
    }

    @objc private func closeClicked() {
        onClose()
    }
}
