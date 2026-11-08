import AppKit

/// Bottom status bar in Soprano Agents' footer language. Left: the keybinding
/// mode as a quiet pill (`Normal`, or `Prefix` / `Copy` / `Select` in a status
/// tone) and the `session / window / pane · Tab 1` breadcrumb. Right: muted
/// counts with the panes that need you in the attention color, account usage,
/// the ⌘P and Prefix hints as `KbdView` caps, and the opt-in `Up h:mm:ss`
/// readout. Every text is the 12 pt system font.
final class StatusBarView: NSView {
    /// 26 pt including the hairline along the top edge.
    static let height: CGFloat = 26

    /// When the uptime readout reads `Up 0:00:00`.
    private static let launchDate = NSRunningApplication.current.launchDate ?? Date()
    private static let accountsObserverId = "StatusBarView"
    private static let gap: CGFloat = 12
    /// Horizontal inset of the bar's content.
    private static let inset: CGFloat = 12

    let agentManager: AgentManager
    let themeManager: ThemeManager

    private let topRule = NSView()
    private let modeView = DashStatusModeView()
    private let locationLabel = NSTextField(labelWithString: "")
    private let countsLabel = NSTextField(labelWithString: "")
    private let usageLabel = NSTextField(labelWithString: "")
    private let paletteHint = DashStatusHintView(title: "Commands")
    private let prefixHint = DashStatusHintView(title: "Prefix")
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
    /// The usage card above the usage segment, while it is open.
    private(set) var usageCard: ComposerPopover?
    private var usageCardContent: DashUsageCardContent?
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
            usageCard?.close()
            return
        }
        AccountsController.shared.addObserver(id: Self.accountsObserverId) { [weak self] snapshot in
            self?.refreshUsage()
            self?.usageCardContent?.render(snapshot)
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
        topRule.wantsLayer = true
        topRule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topRule)
        modeView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(modeView)
        for label in [locationLabel, countsLabel, usageLabel, uptimeLabel] {
            label.font = Typography.ui(Typography.smallSize)
        }

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
            topRule.heightAnchor.constraint(equalToConstant: 1),

            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topRule.bottomAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),

            modeView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset - 4),
            modeView.centerYAnchor.constraint(equalTo: content.centerYAnchor),

            locationLabel.leadingAnchor.constraint(equalTo: modeView.trailingAnchor, constant: Self.gap - 2),
            locationLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            locationLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingStack.leadingAnchor,
                constant: -Self.gap
            ),

            trailingStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
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
        let palette = PaletteCenter.shared.palette
        layer?.backgroundColor = palette.sidebar.cgColor
        topRule.layer?.backgroundColor = palette.border.cgColor
        // An open card re-renders in the new palette rather than waiting for
        // the next account change.
        usageCard?.window.appearance = palette.appearance
        usageCardContent?.render(AccountsController.shared.snapshot)
        modeView.applyPalette(palette)
        paletteHint.applyPalette(palette)
        prefixHint.applyPalette(palette)
        updateUptime()
        refresh()
        refreshUsage()
    }

    private func applyMode() {
        modeView.mode = mode
    }

    private func updateUptime() {
        guard showsUptime else { return }
        uptimeLabel.attributedStringValue = NSAttributedString(
            string: Self.uptimeText(Date().timeIntervalSince(Self.launchDate)),
            attributes: [
                .font: Typography.tabular(Typography.smallSize),
                .foregroundColor: PaletteCenter.shared.palette.mutedForeground,
            ]
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
    /// window, the percentage in ink, the warning tone from 70 % and the error
    /// tone from 90 %. Nil when no provider has usage yet.
    private func usageText(now: Date) -> NSAttributedString? {
        let palette = PaletteCenter.shared.palette
        let font = Typography.tabular(Typography.smallSize)
        let snapshot = AccountsController.shared.snapshot
        let text = NSMutableAttributedString()
        func append(_ string: String, _ color: NSColor) {
            text.append(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color]))
        }
        for provider in AccountProvider.allCases {
            guard let window = snapshot.headline(for: provider)?.usage.tightest else { continue }
            if text.length > 0 {
                append("  |  ", palette.border)
            }
            append("\(provider.displayName) ", palette.mutedForeground)
            let fraction = window.usedFraction
            append(
                UsageFormat.percent(fraction),
                fraction >= 0.9 ? palette.errorForeground : fraction >= 0.7 ? palette.warningForeground : palette.foreground
            )
            if let reset = UsageFormat.timeUntil(window.resetsAt, now: now) {
                append(" · \(reset)", palette.mutedForeground)
            }
        }
        return text.length > 0 ? text : nil
    }

    private func refreshUsage() {
        let now = Date()
        usageRenderedMinute = Self.minuteNumber(now)
        let text = usageText(now: now)
        usageLabel.attributedStringValue = text ?? NSAttributedString(string: "")
        if showsUsage != (text != nil) {
            showsUsage = text != nil
            updateTrailingViews()
        }
    }

    /// Opens Soprano Agents' usage card (`UsageCardPresenter`): a borderless
    /// child-window card above the usage segment that closes on Escape, on a
    /// click outside it, and on a second click on the segment.
    @objc private func usageClicked() {
        toggleUsageCard()
    }

    func toggleUsageCard() {
        if let usageCard, usageCard.window.isVisible {
            usageCard.close()
            return
        }
        guard usageLabel.window != nil else { return }
        let content = DashUsageCardContent(themeManager: themeManager)
        let card = ComposerPopover(content: content)
        content.onManageAccounts = { [weak self] in
            self?.usageCard?.close()
            self?.onManageAccounts?()
        }
        card.onClose = { [weak self] in
            self?.usageCard = nil
            self?.usageCardContent = nil
        }
        usageCard = card
        usageCardContent = content
        card.show(anchoredTo: usageLabel, side: .above, alignment: .trailing)
        AccountsController.shared.refresh()
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

    /// `session / window / pane` for the focused location, the pane in ink,
    /// with the active tab appended when the window has more than one. Nil
    /// when nothing is open.
    private func locationText() -> NSAttributedString? {
        guard let terminalWindow = agentManager.windows[agentManager.activeWindowId] else {
            return nil
        }
        let palette = PaletteCenter.shared.palette
        let text = NSMutableAttributedString()
        let regular = Typography.ui(Typography.smallSize)
        let medium = Typography.ui(Typography.smallSize, weight: .medium)
        func append(_ string: String, _ color: NSColor, font: NSFont = regular) {
            text.append(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color]))
        }
        func separator() {
            append("  /  ", palette.mutedForeground.shellScaled(by: 0.6))
        }

        append(agentManager.activeSession?.name ?? "Session", palette.mutedForeground)
        separator()
        let paneTitle = agentManager.panes[agentManager.activePaneId]?.activeTab?.title
        append(
            terminalWindow.title,
            paneTitle == nil ? palette.foreground : palette.mutedForeground,
            font: paneTitle == nil ? medium : regular
        )
        if let paneTitle {
            separator()
            append(paneTitle, palette.foreground, font: medium)
        }
        if terminalWindow.tabs.count > 1 {
            append(" · Tab \(terminalWindow.activeTabIndex + 1)", palette.mutedForeground)
        }
        return text
    }

    private func refresh() {
        let palette = PaletteCenter.shared.palette
        let countFont = Typography.tabular(Typography.smallSize)
        locationLabel.attributedStringValue = locationText()
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
        let text = NSMutableAttributedString(string: parts.joined(separator: " · "), attributes: [
            .font: countFont, .foregroundColor: palette.mutedForeground,
        ])
        if agentManager.attentionCount > 0 {
            text.append(NSAttributedString(string: " · ", attributes: [
                .font: countFont, .foregroundColor: palette.mutedForeground,
            ]))
            text.append(NSAttributedString(string: "\(agentManager.attentionCount) needs you", attributes: [
                .font: Typography.tabular(Typography.smallSize, weight: .medium),
                .foregroundColor: palette.color(for: .approval),
            ]))
        }
        countsLabel.attributedStringValue = text
    }
}

/// The account usage card (`AccountUsagePopoverViewController`) as the
/// content of an Agents popover card, like Soprano Agents' `UsageCardContent`.
final class DashUsageCardContent: ComposerPopoverContent {
    let controller: AccountUsagePopoverViewController
    var onManageAccounts: (() -> Void)?

    init(themeManager: ThemeManager) {
        controller = AccountUsagePopoverViewController(themeManager: themeManager)
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("status-usage-card")
        controller.onManageAccounts = { [weak self] in self?.onManageAccounts?() }
        let card = controller.view
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Rebuilds the card for `snapshot` and refits the popover to it.
    func render(_ snapshot: AccountsSnapshot) {
        controller.render(snapshot)
        requestResize?()
    }
}

/// The keybinding mode as a quiet pill: `Normal` muted on the faint kbd
/// plate, `Prefix`, `Copy` and `Select` in the approval, working and input
/// tones on a wash of the same tone.
final class DashStatusModeView: PaletteView {
    private static let height: CGFloat = 18

    private let label = NSTextField(labelWithString: "")

    var mode: KeybindingState = .normal {
        didSet {
            guard mode != oldValue else { return }
            applyPalette(palette)
        }
    }

    /// The word the pill shows: `Normal`, `Prefix`, `Copy`, `Select`.
    var displayedText: String { label.stringValue }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("status-mode")
        layer?.cornerRadius = Radius.sm
        label.font = Typography.ui(Typography.smallSize, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        applyPalette(palette)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func applyPalette(_ palette: Palette) {
        let (text, tone): (String, ThreadStatusTone?) = switch mode {
        case .normal: ("Normal", nil)
        case .prefix: ("Prefix", .approval)
        case .copy: ("Copy", .working)
        case .copySelection: ("Select", .input)
        }
        label.stringValue = text
        if let tone {
            let color = palette.color(for: tone)
            label.textColor = color
            layer?.backgroundColor = color.withAlphaComponent(palette.isDark ? 0.16 : 0.12).cgColor
        } else {
            label.textColor = palette.mutedForeground
            layer?.backgroundColor = palette.foreground.withAlphaComponent(0.07).cgColor
        }
        setAccessibilityLabel("\(text) mode")
    }
}

/// `⌘P Commands` or `⌃A` `P` `Prefix`: Soprano Agents' `KbdView` caps, one
/// per chord step, then a muted 12 pt label.
final class DashStatusHintView: NSStackView {
    private let capsStack = NSStackView()
    private let label = NSTextField(labelWithString: "")
    private let title: String

    var caps: [String] = [] {
        didSet {
            guard caps != oldValue else { return }
            capsStack.setViews(caps.map { KbdView($0) }, in: .leading)
            setAccessibilityLabel("\(caps.joined(separator: " ")) \(title)")
        }
    }

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 6
        capsStack.orientation = .horizontal
        capsStack.alignment = .centerY
        capsStack.spacing = 3
        label.stringValue = title
        label.font = Typography.ui(Typography.smallSize)
        addArrangedSubview(capsStack)
        addArrangedSubview(label)
        applyPalette(PaletteCenter.shared.palette)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The caps re-color themselves (`KbdView` is a palette view).
    func applyPalette(_ palette: Palette) {
        label.textColor = palette.mutedForeground
    }
}
