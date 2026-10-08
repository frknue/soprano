import AppKit

/// Bottom status bar showing keybinding mode, pane list, notification count,
/// and the mission clock.
final class StatusBarView: NSView {
    /// A 28 pt content strip under the double rule along the top edge.
    static let height: CGFloat = 28 + Retro.doubleRule

    /// When the mission clock reads T+00:00:00.
    private static let missionStart = NSRunningApplication.current.launchDate ?? Date()

    let agentManager: AgentManager
    let themeManager: ThemeManager

    private let topRule = RetroRuleView(axis: .horizontal, style: .double)
    private let stripeView = RetroStripeView(layout: .slanted)
    private var brandLabel: NSTextField!
    private let modeChip = NSView()
    private var modeLabel: NSTextField!
    private var locationLabel: NSTextField!
    private var paneCountLabel: NSTextField!
    private var clockSeparatorLabel: NSTextField!
    private var clockLabel: NSTextField!
    private var mode: KeybindingState = .normal
    private var clockTimer: Timer?

    init(agentManager: AgentManager, themeManager: ThemeManager) {
        self.agentManager = agentManager
        self.themeManager = themeManager
        super.init(frame: .zero)
        wantsLayer = true
        setupViews()

        agentManager.addObserver(id: "StatusBarView") { [weak self] change in
            self?.handleAgentChange(change)
        }
        refreshTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// `T+HH:MM:SS` for an elapsed interval; hours keep growing past 99.
    static func missionElapsedText(_ elapsed: TimeInterval) -> String {
        let total = max(0, Int(elapsed))
        return String(format: "T+%02ld:%02ld:%02ld", total / 3600, total / 60 % 60, total % 60)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        clockTimer?.invalidate()
        clockTimer = nil
        guard window != nil else { return }
        updateClock()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated {
                self.updateClock()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    private func setupViews() {
        addSubview(topRule)
        addSubview(stripeView)

        brandLabel = NSTextField(labelWithString: "SOPRANO")
        brandLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(brandLabel)

        modeChip.wantsLayer = true
        modeChip.layer?.cornerRadius = Retro.cornerRadius
        modeChip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(modeChip)

        modeLabel = NSTextField(labelWithString: "NORMAL")
        modeLabel.translatesAutoresizingMaskIntoConstraints = false
        modeChip.addSubview(modeLabel)

        // Active session ▸ window ▸ pane breadcrumb
        locationLabel = NSTextField(labelWithString: "")
        locationLabel.identifier = NSUserInterfaceItemIdentifier("status-location")
        locationLabel.lineBreakMode = .byTruncatingTail
        locationLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        locationLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(locationLabel)

        paneCountLabel = NSTextField(labelWithString: "1 pane")
        paneCountLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(paneCountLabel)

        clockSeparatorLabel = NSTextField(labelWithString: "▪")
        clockSeparatorLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clockSeparatorLabel)

        clockLabel = NSTextField(labelWithString: Self.missionElapsedText(0))
        clockLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clockLabel)

        let content = NSLayoutGuide()
        addLayoutGuide(content)

        NSLayoutConstraint.activate([
            topRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            topRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            topRule.topAnchor.constraint(equalTo: topAnchor),

            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topRule.bottomAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),

            stripeView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stripeView.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stripeView.widthAnchor.constraint(equalToConstant: 22),
            stripeView.heightAnchor.constraint(equalToConstant: 12),

            brandLabel.leadingAnchor.constraint(equalTo: stripeView.trailingAnchor, constant: 8),
            brandLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),

            modeChip.leadingAnchor.constraint(equalTo: brandLabel.trailingAnchor, constant: 14),
            modeChip.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            modeChip.heightAnchor.constraint(equalToConstant: 18),
            modeLabel.leadingAnchor.constraint(equalTo: modeChip.leadingAnchor, constant: 6),
            modeLabel.trailingAnchor.constraint(equalTo: modeChip.trailingAnchor, constant: -6),
            modeLabel.centerYAnchor.constraint(equalTo: modeChip.centerYAnchor),

            locationLabel.leadingAnchor.constraint(equalTo: modeChip.trailingAnchor, constant: 14),
            locationLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            locationLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: paneCountLabel.leadingAnchor,
                constant: -16
            ),

            paneCountLabel.trailingAnchor.constraint(equalTo: clockSeparatorLabel.leadingAnchor, constant: -8),
            paneCountLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),

            clockSeparatorLabel.trailingAnchor.constraint(equalTo: clockLabel.leadingAnchor, constant: -8),
            clockSeparatorLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),

            clockLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            clockLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
    }

    func setKeybindingMode(_ mode: KeybindingState) {
        self.mode = mode
        applyMode(theme: themeManager.currentTheme)
    }

    func refreshTheme() {
        let theme = themeManager.currentTheme
        layer?.backgroundColor = theme.colors.bgPanel.cgColor
        topRule.color = theme.colors.borderStrong
        stripeView.colors = theme.colors.stripe
        brandLabel.setRetroText("SOPRANO", color: theme.colors.accent, glow: true)
        clockSeparatorLabel.setRetroText("▪", color: theme.colors.textMuted)
        applyMode(theme: theme)
        updateClock()
        refresh()
    }

    private func applyMode(theme: AppTheme) {
        let text: String
        let litColor: NSColor?
        switch mode {
        case .normal:
            text = "NORMAL"
            litColor = nil
        case .prefix:
            text = "PREFIX"
            litColor = theme.colors.accent
        case .copy:
            text = "COPY"
            litColor = theme.colors.accent
        case .copySelection:
            text = "SELECT"
            litColor = theme.colors.blue
        }
        if let litColor {
            modeLabel.setRetroText(text, color: theme.colors.bgPanel)
            modeChip.layer?.backgroundColor = litColor.cgColor
            modeChip.layer?.borderWidth = 0
        } else {
            modeLabel.setRetroText(text, color: theme.colors.textMuted)
            modeChip.layer?.backgroundColor = NSColor.clear.cgColor
            modeChip.layer?.borderWidth = Retro.hairline
            modeChip.layer?.borderColor = theme.colors.borderStrong.cgColor
        }
    }

    private func updateClock() {
        clockLabel.setRetroText(
            Self.missionElapsedText(Date().timeIntervalSince(Self.missionStart)),
            color: themeManager.currentTheme.colors.textMuted
        )
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

    /// `session ▸ window ▸ pane` for the focused location, with the depth layer appended
    /// when the window has any inner workspace. Nil when nothing is open.
    private func locationText(theme: AppTheme) -> NSAttributedString? {
        guard let terminalWindow = agentManager.windows[agentManager.activeWindowId] else {
            return nil
        }

        let text = NSMutableAttributedString()
        func append(_ string: String, _ color: NSColor) {
            text.append(RetroText.display(string, color: color))
        }

        append(agentManager.activeSession?.name ?? "Session", theme.colors.accent)
        append(" ▸ ", theme.colors.textMuted)
        append(terminalWindow.title, theme.colors.textPrimary)

        let paneId = agentManager.activePaneId
        if let title = agentManager.panes[paneId]?.activeTab?.title {
            append(" ▸ ", theme.colors.textMuted)
            append(title, theme.colors.textPrimary)
        }

        if terminalWindow.maximumDepth > 0 {
            let depth = terminalWindow.depth(containingPane: paneId) ?? 0
            append(" · DEPTH \(depth)", theme.colors.accent)
        }

        return text
    }

    private func refresh() {
        let theme = themeManager.currentTheme
        locationLabel.attributedStringValue = locationText(theme: theme)
            ?? NSAttributedString(string: "")
        let sessionCount = agentManager.terminalSessions.count
        let paneCount = agentManager.paneCount
        let windowCount = agentManager.windowCount
        let sessions = "\(sessionCount) session\(sessionCount == 1 ? "" : "s")"
        let panes = "\(paneCount) pane\(paneCount == 1 ? "" : "s")"
        let windows = "\(windowCount) window\(windowCount == 1 ? "" : "s")"
        var components = [sessions, windows, panes]
        if agentManager.readyAgentCount > 0 {
            components.append("\(agentManager.readyAgentCount) READY")
        }
        if agentManager.attentionCount > 0 {
            components.append("\(agentManager.attentionCount) NEEDS ATTENTION")
        }
        let base = components.joined(separator: " · ")
        if agentManager.maximizedPaneId != nil {
            paneCountLabel.setRetroText("\(base) · MAXIMIZED", color: theme.colors.accent)
        } else if agentManager.attentionCount > 0 {
            paneCountLabel.setRetroText(base, color: theme.colors.blue)
        } else {
            paneCountLabel.setRetroText(base, color: theme.colors.textMuted)
        }
    }
}
