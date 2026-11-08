import AppKit

/// Header bar at the top of each pane, in Soprano Agents' header language:
/// the pane kind's symbol and title (or the pane tabs as Agents tabs), a
/// ghost `+` that opens a terminal tab in this pane, the Agents status pill
/// (Working / Approval / Input / Done / Failed, Running for a shell running
/// a command) and a ghost close button.
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
    /// Scrolls the tab strip sideways once its tabs are at their narrowest.
    private let tabScrollView = NSScrollView()
    private var revealActiveTab = false
    private var revealedActiveTabId: String?
    private var previousTabViewportWidth: CGFloat = 0
    private let bottomRule = NSView()
    private let focusRule = NSView()
    private var closeButton: ShellGhostButton!
    private var addTabButton: ShellGhostButton!
    /// The `+` follows the title, or the tab strip when the pane has tabs.
    private var addTabAfterTitle: NSLayoutConstraint!
    private var addTabAfterTabs: NSLayoutConstraint!
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
        // titles in proportion to their length instead of running under the
        // `+` and the close button. Each tab still keeps its close button and
        // a letter or two (`PaneTabButton.minWidth`); when even that does not
        // fit, the strip scrolls and keeps the active tab in view.
        tabStackView.distribution = .fillProportionally
        tabStackView.translatesAutoresizingMaskIntoConstraints = false

        tabScrollView.drawsBackground = false
        tabScrollView.borderType = .noBorder
        // Too short for a scroller; still scrolls by trackpad or wheel.
        tabScrollView.hasHorizontalScroller = false
        tabScrollView.hasVerticalScroller = false
        tabScrollView.horizontalScrollElasticity = .allowed
        tabScrollView.verticalScrollElasticity = .none
        tabScrollView.documentView = tabStackView
        tabScrollView.translatesAutoresizingMaskIntoConstraints = false
        tabScrollView.isHidden = true
        addSubview(tabScrollView)

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

        addTabButton = ShellGhostButton(
            symbol: "plus",
            label: "New Pane Tab",
            size: 20,
            symbolSize: 10,
            target: self,
            action: #selector(addTabAction)
        )
        addTabButton.identifier = NSUserInterfaceItemIdentifier("pane-add-tab-button")
        addTabButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(addTabButton)

        for rule in [bottomRule, focusRule] {
            rule.wantsLayer = true
            rule.translatesAutoresizingMaskIntoConstraints = false
            addSubview(rule)
        }

        // Pane containers are briefly zero-width while AppKit reparents a
        // cached split tree. Let the flexible title or tabs collapse during
        // that transient state instead of breaking the fixed control
        // constraints.
        let addTabTrailingConstraint = addTabButton.trailingAnchor.constraint(
            lessThanOrEqualTo: statusPill.leadingAnchor,
            constant: -8
        )
        addTabTrailingConstraint.priority = .defaultHigh
        addTabAfterTitle = addTabButton.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 4)
        addTabAfterTabs = addTabButton.leadingAnchor.constraint(equalTo: tabScrollView.trailingAnchor, constant: 4)
        // The strip hugs its tabs (748), the tabs shrink to the strip (749)
        // and the strip stops at the `+`'s trailing limit (750): tabs shrink
        // before the strip runs out of room, then it scrolls.
        let clipView = tabScrollView.contentView
        let stackFitsViewport = tabStackView.widthAnchor.constraint(lessThanOrEqualTo: clipView.widthAnchor)
        stackFitsViewport.priority = NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.defaultHigh.rawValue - 1)
        let stripHugsTabs = tabScrollView.widthAnchor.constraint(equalTo: tabStackView.widthAnchor)
        stripHugsTabs.priority = NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.defaultHigh.rawValue - 2)

        NSLayoutConstraint.activate([
            kindIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            kindIcon.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -0.5),
            kindIcon.widthAnchor.constraint(equalToConstant: 16),

            titleLabel.leadingAnchor.constraint(equalTo: kindIcon.trailingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: kindIcon.centerYAnchor),

            tabScrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            tabScrollView.centerYAnchor.constraint(equalTo: kindIcon.centerYAnchor),
            tabScrollView.heightAnchor.constraint(equalToConstant: 22),
            tabStackView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            tabStackView.topAnchor.constraint(equalTo: clipView.topAnchor),
            tabStackView.bottomAnchor.constraint(equalTo: clipView.bottomAnchor),
            stackFitsViewport,
            stripHugsTabs,

            addTabButton.centerYAnchor.constraint(equalTo: kindIcon.centerYAnchor),
            addTabTrailingConstraint,
            addTabAfterTitle,

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
        tabScrollView.isHidden = !shouldShowTabs
        // Deactivate before activating so the button never holds both.
        addTabAfterTitle.isActive = false
        addTabAfterTabs.isActive = false
        (shouldShowTabs ? addTabAfterTabs : addTabAfterTitle).isActive = true
        addTabButton.isEnabled = tabCount < PaneState.maxTabsPerPane
        addTabButton.toolTip = addTabButton.isEnabled
            ? "New Pane Tab"
            : "A pane holds at most \(PaneState.maxTabsPerPane) tabs"
        if shouldShowTabs, let pane {
            rebuildTabButtons(for: pane, palette: palette)
        } else {
            clearTabButtons()
        }
        let activeTabId = shouldShowTabs ? pane?.activeTab?.id : nil
        if activeTabId != revealedActiveTabId {
            revealedActiveTabId = activeTabId
            revealActiveTab = true
            needsLayout = true
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

    /// Scrolls the tab strip so the active tab shows whenever it changes, the
    /// tabs change, or the strip resizes.
    override func layout() {
        super.layout()
        guard !tabScrollView.isHidden else { return }
        let viewportWidth = tabScrollView.contentView.bounds.width
        if viewportWidth != previousTabViewportWidth {
            previousTabViewportWidth = viewportWidth
            revealActiveTab = true
        }
        guard revealActiveTab, viewportWidth > 0,
              let activeTabId = revealedActiveTabId,
              let button = tabButtons.first(where: { $0.id == activeTabId })?.button
        else { return }
        tabScrollView.layoutSubtreeIfNeeded()
        button.scrollToVisible(button.bounds)
        revealActiveTab = false
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

    /// Shows what a tab in this pane can hold, like the sidebar's `+`: a
    /// terminal, a browser, each agent as a terminal or a chat, or a
    /// Markdown file. `⌃⌘T` (`⌃A` then `⇧T`) is the terminal without the menu.
    @objc private func addTabAction() {
        addTabMenu().popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: addTabButton.bounds.maxY + 4),
            in: addTabButton
        )
    }

    /// The `+` menu; each item opens its tab in this pane and focuses it.
    func addTabMenu() -> NSMenu {
        let menu = NSMenu(title: "New Tab in This Pane")
        menu.autoenablesItems = false
        func add(_ title: String, symbol: String, id: String, action: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(addTabMenuItemClicked(_:)), keyEquivalent: "")
            item.target = self
            item.identifier = NSUserInterfaceItemIdentifier("pane-add-tab-\(id)")
            item.image = NSImage.symbol(symbol, size: 13)
            item.representedObject = AddTabMenuAction(action)
            menu.addItem(item)
        }
        let paneId = paneId
        add("Terminal", symbol: Icon.terminal, id: "terminal") { [weak self] in
            _ = self?.agentManager.addTabToPane(paneId, type: .terminal)
        }
        add("Browser", symbol: Icon.globe, id: "browser") { [weak self] in
            _ = self?.agentManager.addTabToPane(paneId, type: .browser)
        }
        menu.addItem(.separator())
        for profile in AgentCatalog.all where profile.id != "terminal" {
            add(profile.name, symbol: Icon.subagent, id: "agent-\(profile.id)") { [weak self] in
                _ = self?.agentManager.addTabToPane(paneId, type: .agent, profileId: profile.id)
            }
        }
        for profile in AgentChatLaunch.chatProfiles {
            add("\(profile.name) Chat", symbol: "bubble.left.and.text.bubble.right", id: "chat-\(profile.id)") { [weak self] in
                _ = self?.agentManager.addTabToPane(
                    paneId,
                    type: .agent,
                    profileId: profile.id,
                    contentKind: PaneContentKind.chat
                )
            }
        }
        menu.addItem(.separator())
        add("Markdown File…", symbol: Icon.fileText, id: "markdown") { [weak self] in
            guard let self, let window = self.window else { return }
            MarkdownFilePicker.begin(relativeTo: window) { [weak self] fileURL in
                _ = self?.agentManager.openMarkdown(fileURL: fileURL, in: paneId)
            }
        }
        return menu
    }

    @objc private func addTabMenuItemClicked(_ sender: NSMenuItem) {
        (sender.representedObject as? AddTabMenuAction)?.run()
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
            revealActiveTab = true
            needsLayout = true
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
                button.widthAnchor.constraint(greaterThanOrEqualToConstant: PaneTabButton.minWidth).isActive = true
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
    /// Narrowest a tab gets: its padding, the close button (inset 4 pt from
    /// the trailing edge) and 26 pt of title, enough for a letter or two and
    /// an ellipsis.
    static let minWidth: CGFloat = padding + 26 + closeGap + closeSize + 4

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

/// What one item of the pane header's `+` menu does.
private final class AddTabMenuAction: NSObject {
    let run: () -> Void

    init(_ run: @escaping () -> Void) {
        self.run = run
    }
}
