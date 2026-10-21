import AppKit

/// Bottom status bar. Left: the keybinding mode chip and the
/// `session › window › pane · Tab 1` breadcrumb. Right: muted counts with the
/// panes that need you in the attention color, account usage, the ⌘P and
/// Prefix hints, and the opt-in `Up h:mm:ss` readout.
final class StatusBarView: NSView, NSPopoverDelegate {
    /// 26 pt including the hairline along the top edge.
    static let height: CGFloat = 26

    /// When the uptime readout reads `Up 0:00:00`.
    private static let launchDate = NSRunningApplication.current.launchDate ?? Date()
    private static let accountsObserverId = "StatusBarView"
    private static let gap: CGFloat = 12

    let agentManager: AgentManager
    let themeManager: ThemeManager

    private let topRule = ChromeRuleView(axis: .horizontal)
    private let modeChip: ChromeModeChip
    private let locationLabel = NSTextField(labelWithString: "")
    private let countsLabel = NSTextField(labelWithString: "")
    private let usageLabel = NSTextField(labelWithString: "")
    private let paletteHint: StatusHintView
    private let prefixHint: StatusHintView
    private let uptimeLabel = NSTextField(labelWithString: "")
    /// Counts, usage, hints and uptime. Segments that do not apply are left
    /// out of the stack rather than hidden: a detaching stack rearranges its
    /// subviews during layout.
    private let trailingStack = NSStackView()
    private var showsUsage = false
    private var showsPaletteHint = true
    /// Countdowns in the usage segment are in minutes; the clock tick
    /// re-renders it when this minute number changes.
    private var usageRenderedMinute = 0
    private var usagePopover: NSPopover?
    /// When the usage popover last closed. A transient popover closes on the
    /// mouse-down of the very click that would toggle it, so a click right
    /// after a close is that toggle and must not reopen it.
    private var usagePopoverClosedAt: Date?
    /// Opens Settings on the Accounts tab.
    var onManageAccounts: (() -> Void)?
    private var mode: KeybindingState = .normal
    private var clockTimer: Timer?

    /// Shows `Up h:mm:ss` at the trailing end (`statusBar.uptime`).
    var showsUptime = false {
        didSet {
            updateTrailingViews()
            updateUptime()
        }
    }

    init(agentManager: AgentManager, themeManager: ThemeManager) {
        self.agentManager = agentManager
        self.themeManager = themeManager
        let theme = themeManager.currentTheme
        modeChip = ChromeModeChip(theme: theme)
        paletteHint = StatusHintView(title: "Commands", theme: theme)
        prefixHint = StatusHintView(title: "Prefix", theme: theme)
        super.init(frame: .zero)
        wantsLayer = true
        setupViews()

        agentManager.addObserver(id: "StatusBarView") { [weak self] change in
            self?.handleAgentChange(change)
        }
        refreshKeyHints()
        refreshTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// `Up h:mm:ss` for an elapsed interval; hours keep growing past 99.
    static func uptimeText(_ elapsed: TimeInterval) -> String {
        let total = max(0, Int(elapsed))
        return String(format: "Up %ld:%02ld:%02ld", total / 3600, total / 60 % 60, total % 60)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        clockTimer?.invalidate()
        clockTimer = nil
        AccountsController.shared.removeObserver(id: Self.accountsObserverId)
        guard window != nil else {
            usagePopover?.close()
            return
        }
        AccountsController.shared.addObserver(id: Self.accountsObserverId) { [weak self] _ in
            self?.refreshUsage()
        }
        AccountsController.shared.refresh()
        refreshUsage()
        updateUptime()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated {
                self.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    private func setupViews() {
        topRule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topRule)
        addSubview(modeChip)

        locationLabel.identifier = NSUserInterfaceItemIdentifier("status-location")
        locationLabel.lineBreakMode = .byTruncatingTail
        locationLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        locationLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(locationLabel)

        countsLabel.identifier = NSUserInterfaceItemIdentifier("status-counts")
        // Like the hints, the counts keep their width (it also sets the
        // window's minimum); only the breadcrumb truncates.
        countsLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        // Account usage: the tightest limit per provider; click for details
        usageLabel.identifier = NSUserInterfaceItemIdentifier("status-usage")
        usageLabel.toolTip = "Account usage — click for details"
        usageLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        usageLabel.addGestureRecognizer(
            NSClickGestureRecognizer(target: self, action: #selector(usageClicked))
        )

        uptimeLabel.identifier = NSUserInterfaceItemIdentifier("status-uptime")
        uptimeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        for hint in [paletteHint, prefixHint] {
            hint.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        }

        trailingStack.orientation = .horizontal
        trailingStack.alignment = .centerY
        trailingStack.spacing = Self.gap
        trailingStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(trailingStack)

        let content = NSLayoutGuide()
        addLayoutGuide(content)
        NSLayoutConstraint.activate([
            topRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            topRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            topRule.topAnchor.constraint(equalTo: topAnchor),
            topRule.heightAnchor.constraint(equalToConstant: Chrome.hairline),

            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topRule.bottomAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),

            modeChip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Chrome.Space.bar),
            modeChip.centerYAnchor.constraint(equalTo: content.centerYAnchor),

            locationLabel.leadingAnchor.constraint(equalTo: modeChip.trailingAnchor, constant: Self.gap + 2),
            locationLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            locationLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingStack.leadingAnchor,
                constant: -Self.gap
            ),

            trailingStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Chrome.Space.bar),
            trailingStack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
    }

    func setKeybindingMode(_ mode: KeybindingState) {
        self.mode = mode
        applyMode()
    }

    /// Reads the palette chord and the prefix key from `settings.json`, so the
    /// hints follow a rebound key. A disabled palette binding drops its hint.
    func refreshKeyHints(_ keybindings: KeyBindingConfig = ConfigStore.shared.keybindings) {
        let paletteCaps = keybindings.bindings.first { $0.id == "command-palette" }
            .map { MainWindowController.keycaps(for: $0, prefixKey: keybindings.prefixKey) } ?? []
        paletteHint.caps = paletteCaps
        showsPaletteHint = !paletteCaps.isEmpty
        prefixHint.caps = ["⌃" + keybindings.prefixKey.uppercased()]
        updateTrailingViews()
    }

    private func updateTrailingViews() {
        var views: [NSView] = [countsLabel]
        if showsUsage { views.append(usageLabel) }
        if showsPaletteHint { views.append(paletteHint) }
        views.append(prefixHint)
        if showsUptime { views.append(uptimeLabel) }
        guard trailingStack.arrangedSubviews != views else { return }
        trailingStack.setViews(views, in: .leading)
    }

    func refreshTheme() {
        let theme = themeManager.currentTheme
        layer?.backgroundColor = theme.colors.bgPanel.cgColor
        topRule.color = theme.colors.borderSubtle
        usagePopover?.appearance = theme.appearance.nsAppearance
        // An open popover re-renders in the new palette rather than waiting
        // for the next account change.
        (usagePopover?.contentViewController as? AccountUsagePopoverViewController)?
            .render(AccountsController.shared.snapshot)
        modeChip.apply(theme: theme)
        paletteHint.apply(theme: theme)
        prefixHint.apply(theme: theme)
        applyMode()
        updateUptime()
        refresh()
        refreshUsage()
    }

    private func applyMode() {
        switch mode {
        case .normal: modeChip.set(mode: .normal, text: "Normal")
        case .prefix: modeChip.set(mode: .prefix, text: "Prefix")
        case .copy: modeChip.set(mode: .copy, text: "Copy")
        case .copySelection: modeChip.set(mode: .select, text: "Select")
        }
    }

    private func updateUptime() {
        guard showsUptime else { return }
        uptimeLabel.setChromeText(
            Self.uptimeText(Date().timeIntervalSince(Self.launchDate)),
            font: ChromeFont.count,
            color: themeManager.currentTheme.colors.textMuted
        )
    }

    private func tick() {
        updateUptime()
        if Self.minuteNumber(Date()) != usageRenderedMinute {
            refreshUsage()
        }
    }

    private static func minuteNumber(_ date: Date) -> Int {
        Int(date.timeIntervalSinceReferenceDate / 60)
    }

    /// `Claude 9% · 4h 12m | Codex 75% · 5d 8h`: each provider's tightest
    /// window, the percentage in ink, yellow from 70 % and danger from 90 %.
    /// Nil when no provider has usage yet.
    private func usageText(theme: AppTheme, now: Date) -> NSAttributedString? {
        let colors = theme.colors
        let font = ChromeFont.count
        let snapshot = AccountsController.shared.snapshot
        let text = NSMutableAttributedString()
        for provider in AccountProvider.allCases {
            guard let window = snapshot.headline(for: provider)?.usage.tightest else { continue }
            if text.length > 0 {
                text.append(ChromeText.attributed("  |  ", font: font, color: colors.borderStrong))
            }
            text.append(ChromeText.attributed("\(provider.displayName) ", font: font, color: colors.textMuted))
            text.append(ChromeText.attributed(
                UsageFormat.percent(window.usedFraction),
                font: font,
                color: UsageSeverity.color(for: window.usedFraction, colors: colors)
            ))
            if let reset = UsageFormat.timeUntil(window.resetsAt, now: now) {
                text.append(ChromeText.attributed(" · \(reset)", font: font, color: colors.textMuted))
            }
        }
        return text.length > 0 ? text : nil
    }

    private func refreshUsage() {
        let now = Date()
        usageRenderedMinute = Self.minuteNumber(now)
        let text = usageText(theme: themeManager.currentTheme, now: now)
        usageLabel.attributedStringValue = text ?? NSAttributedString(string: "")
        if showsUsage != (text != nil) {
            showsUsage = text != nil
            updateTrailingViews()
        }
    }

    @objc private func usageClicked() {
        if let usagePopover, usagePopover.isShown {
            usagePopover.performClose(nil)
            return
        }
        if let closedAt = usagePopoverClosedAt, Date().timeIntervalSince(closedAt) < 0.3 {
            return
        }
        let controller = AccountUsagePopoverViewController(themeManager: themeManager)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.appearance = themeManager.currentTheme.appearance.nsAppearance
        popover.contentViewController = controller
        popover.delegate = self
        controller.onManageAccounts = { [weak self, weak popover] in
            popover?.performClose(nil)
            self?.onManageAccounts?()
        }
        usagePopover = popover
        AccountsController.shared.refresh()
        popover.show(relativeTo: usageLabel.bounds, of: usageLabel, preferredEdge: .maxY)
    }

    func popoverDidClose(_ notification: Notification) {
        usagePopover = nil
        usagePopoverClosedAt = Date()
    }

    private func handleAgentChange(_ change: AgentManagerChange) {
        switch change {
        case .model:
            refresh()

        case .tabTitle(let target):
            guard target.paneId == agentManager.activePaneId,
                  agentManager.panes[target.paneId]?.activeTab?.id == target.tabId
            else { return }
            refresh()

        case .tabWorkingDirectory, .browserURL:
            break

        case .document(let target):
            guard target.paneId == agentManager.activePaneId,
                  agentManager.panes[target.paneId]?.activeTab?.id == target.tabId
            else { return }
            refresh()
        }
    }

    /// `session › window › pane` for the focused location, the pane in ink,
    /// with the active tab appended when the window has more than one. Nil
    /// when nothing is open.
    private func locationText(theme: AppTheme) -> NSAttributedString? {
        guard let terminalWindow = agentManager.windows[agentManager.activeWindowId] else {
            return nil
        }
        let colors = theme.colors
        let text = NSMutableAttributedString()
        func append(_ string: String, _ color: NSColor, font: NSFont = ChromeFont.label) {
            text.append(ChromeText.attributed(string, font: font, color: color))
        }
        func separator() {
            append(" › ", colors.borderStrong)
        }

        append(agentManager.activeSession?.name ?? "Session", colors.textMuted)
        separator()
        let paneTitle = agentManager.panes[agentManager.activePaneId]?.activeTab?.title
        append(
            terminalWindow.title,
            paneTitle == nil ? colors.textPrimary : colors.textMuted,
            font: paneTitle == nil ? ChromeFont.labelStrong : ChromeFont.label
        )
        if let paneTitle {
            separator()
            append(paneTitle, colors.textPrimary, font: ChromeFont.labelStrong)
        }
        if terminalWindow.tabs.count > 1 {
            append(" · Tab \(terminalWindow.activeTabIndex + 1)", colors.textMuted)
        }
        return text
    }

    private func refresh() {
        let theme = themeManager.currentTheme
        let colors = theme.colors
        locationLabel.attributedStringValue = locationText(theme: theme)
            ?? NSAttributedString(string: "")

        func plural(_ count: Int, _ noun: String) -> String {
            "\(count) \(noun)\(count == 1 ? "" : "s")"
        }
        var parts = [
            plural(agentManager.terminalSessions.count, "session"),
            plural(agentManager.windowCount, "window"),
            plural(agentManager.paneCount, "pane"),
        ]
        if agentManager.maximizedPaneId != nil {
            parts.append("maximized")
        }
        let text = NSMutableAttributedString(attributedString: ChromeText.attributed(
            parts.joined(separator: " · "),
            font: ChromeFont.count,
            color: colors.textMuted
        ))
        if agentManager.attentionCount > 0 {
            text.append(ChromeText.attributed(" · ", font: ChromeFont.count, color: colors.textMuted))
            text.append(ChromeText.attributed(
                "\(agentManager.attentionCount) needs you",
                font: ChromeFont.count,
                color: colors.attention
            ))
        }
        countsLabel.attributedStringValue = text
    }
}

/// `⌘P Commands` or `⌃A` `P` `Commands`: muted 16 pt keycaps, one per chord
/// step, and a muted label.
private final class StatusHintView: NSStackView {
    let keycaps: ChromeKeycapGroupView
    private let label = NSTextField(labelWithString: "")
    private let title: String

    var caps: [String] {
        get { keycaps.caps }
        set {
            keycaps.caps = newValue
            setAccessibilityLabel("\(newValue.joined(separator: " ")) \(title)")
        }
    }

    init(title: String, theme: AppTheme) {
        self.title = title
        keycaps = ChromeKeycapGroupView(caps: [], theme: theme, style: .small, tone: .muted)
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 5
        addArrangedSubview(keycaps)
        addArrangedSubview(label)
        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        keycaps.apply(theme: theme)
        label.setChromeText(title, font: ChromeFont.meta, color: theme.colors.textMuted)
    }
}
