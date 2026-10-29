import AppKit

/// One run's report: its status and times, why it was skipped or failed (a
/// precheck's output in mono), the worktree it worked in, and the agent's
/// final reply rendered as Markdown. Open Run shows its live tab; Resume
/// Conversation reopens a closed run's agent.
final class AutomationRunDetailView: NSView {
    var onBack: (() -> Void)?
    var onOpenRun: ((String) -> Void)?
    /// Keys the report text does not use go back to the page.
    var keyHandler: ((NSEvent) -> Bool)?

    private var theme: AppTheme
    private let stack = NSStackView()
    private var shown: (run: AutomationRun, automation: Automation?, isLive: Bool, clock: String)?

    init(theme: AppTheme) {
        self.theme = theme
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("automations-run")
        let scrollView = AutomationViews.scrollingPage(stack: stack)
        stack.spacing = Chrome.Space.s16
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        guard let shown else { return }
        self.shown = nil
        update(run: shown.run, automation: shown.automation, isLive: shown.isLive, now: Date())
    }

    /// `isLive`: the run's tab is still open in this Soprano. The report is
    /// rebuilt only when what it shows changed, so text selected in it
    /// survives notifications about other runs and the half-minute refresh.
    func update(run: AutomationRun, automation: Automation?, isLive: Bool, now: Date) {
        // An unfinished run states how long it has been going.
        let clock = run.finishedAt == nil ? AutomationFormat.duration(now.timeIntervalSince(run.startedAt)) : ""
        if let shown,
           shown.run == run,
           shown.automation == automation,
           shown.isLive == isLive,
           shown.clock == clock {
            return
        }
        shown = (run, automation, isLive, clock)
        rebuild(run: run, automation: automation, isLive: isLive, now: now)
    }

    // MARK: - Content

    private func rebuild(run: AutomationRun, automation: Automation?, isLive: Bool, now: Date) {
        let colors = theme.colors
        let name = automation?.name ?? run.automationId
        var views: [NSView] = []
        var spacingAfter: [NSView: CGFloat] = [:]

        let breadcrumb = AutomationViews.breadcrumb(
            ["Automations", name, "#\(run.number)"],
            theme: theme,
            target: self,
            action: #selector(backClicked)
        )
        views.append(breadcrumb)
        spacingAfter[breadcrumb] = Chrome.Space.s12

        let title = AutomationViews.label(
            AutomationController.runTitle(name: name, number: run.number),
            font: ChromeFont.screen,
            color: colors.textPrimary
        )
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let status = AutomationViews.statusView(run.status, theme: theme)
        var buttons: [NSView] = []
        if run.target != nil, isLive {
            buttons.append(button("Open Run", kind: .ink, action: #selector(openRunClicked)))
        } else if run.conversation != nil, AgentConversation.supports(profileId: run.profileId) {
            buttons.append(button("Resume Conversation", kind: .ink, action: #selector(openRunClicked)))
        }
        if let worktree = run.worktree, !worktree.removed {
            buttons.append(button("Reveal Worktree", kind: .standard, action: #selector(revealWorktreeClicked)))
        }
        let titleRow = AutomationViews.spreadRow(leading: [title, status], trailing: buttons, spacing: Chrome.Space.s12)
        views.append(titleRow)
        spacingAfter[titleRow] = Chrome.Space.s24

        let grid = AutomationViews.metricsGrid(facts(for: run, now: now), columns: 4, theme: theme)
        views.append(grid)
        spacingAfter[grid] = Chrome.Space.s32

        if let message = run.message {
            views.append(contentsOf: messageSection(message, status: run.status, spacingAfter: &spacingAfter))
        }
        if let worktree = run.worktree {
            views.append(contentsOf: worktreeSection(worktree, spacingAfter: &spacingAfter))
        }
        views.append(contentsOf: reportSection(run, spacingAfter: &spacingAfter))

        stack.setArrangedSubviews(views) { view in
            if view !== breadcrumb {
                view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
        for (view, spacing) in spacingAfter {
            stack.setCustomSpacing(spacing, after: view)
        }
    }

    private func facts(for run: AutomationRun, now: Date) -> [(String, NSView)] {
        let colors = theme.colors
        func value(_ text: String, font: NSFont = ChromeFont.row, muted: Bool = false) -> NSView {
            AutomationViews.wrappingLabel(ChromeText.attributed(
                text,
                font: font,
                color: muted ? colors.textMuted : colors.textPrimary,
                lineBreakMode: .byWordWrapping
            ))
        }

        var facts: [(String, NSView)] = [("Started", value(AutomationFormat.dateTime(run.startedAt)))]
        if let finishedAt = run.finishedAt {
            facts.append(("Finished", value(AutomationFormat.dateTime(finishedAt))))
        } else {
            facts.append(("Finished", value(run.status.isFinal ? "—" : "Not yet", muted: true)))
        }
        if let duration = run.duration {
            facts.append(("Duration", value(AutomationFormat.duration(duration))))
        } else {
            facts.append(("Duration", value("\(AutomationFormat.duration(now.timeIntervalSince(run.startedAt))) so far", muted: true)))
        }
        if run.trigger == .scheduled, let scheduledFor = run.scheduledFor {
            facts.append(("Scheduled for", value(AutomationFormat.dateTime(scheduledFor))))
        }
        facts.append(("Trigger", value(AutomationFormat.trigger(run.trigger))))
        facts.append(("Agent", value(AutomationFormat.agentName(run.profileId))))
        facts.append(("Worked in", value(AutomationFormat.path(run.folder), font: ChromeFont.mono)))
        return facts
    }

    /// Why the run was skipped or failed, or what its agent waits for. A
    /// precheck's output follows its first paragraph and is shown in mono.
    private func messageSection(
        _ message: String,
        status: AutomationRun.Status,
        spacingAfter: inout [NSView: CGFloat]
    ) -> [NSView] {
        let colors = theme.colors
        let title = switch status {
        case .skipped: "Why it was skipped"
        case .failed: "Why it failed"
        case .needsInput: "Waiting for"
        case .starting, .running, .completed: "Message"
        }
        let heading = ChromeEyebrowView(title: title, theme: theme)
        spacingAfter[heading] = Chrome.Space.s8

        var reason = message
        var output: String?
        if message.hasPrefix("The precheck"), let split = message.range(of: "\n\n") {
            reason = String(message[..<split.lowerBound])
            output = String(message[split.upperBound...])
        }
        let reasonView = textBlock(
            ChromeText.attributed(reason, font: ChromeFont.row, color: colors.textPrimary, lineBreakMode: .byWordWrapping),
            boxed: false
        )
        guard let output else {
            spacingAfter[reasonView] = Chrome.Space.s32
            return [heading, reasonView]
        }
        spacingAfter[reasonView] = Chrome.Space.s8
        let outputView = textBlock(
            ChromeText.attributed(output, font: ChromeFont.mono, color: colors.textPrimary, lineBreakMode: .byCharWrapping),
            boxed: true
        )
        spacingAfter[outputView] = Chrome.Space.s32
        return [heading, reasonView, outputView]
    }

    private func worktreeSection(_ worktree: AutomationRun.Worktree, spacingAfter: inout [NSView: CGFloat]) -> [NSView] {
        let colors = theme.colors
        let heading = ChromeEyebrowView(title: "Worktree", theme: theme)
        spacingAfter[heading] = Chrome.Space.s8
        let text = NSMutableAttributedString(attributedString: ChromeText.attributed(
            AutomationFormat.path(worktree.path),
            font: ChromeFont.mono,
            color: worktree.removed ? colors.textMuted : colors.textPrimary,
            lineBreakMode: .byCharWrapping
        ))
        text.append(ChromeText.attributed("\n", font: ChromeFont.mono, color: colors.textPrimary))
        text.append(ChromeText.attributed(
            worktree.branch,
            font: ChromeFont.mono,
            color: colors.textMuted,
            lineBreakMode: .byCharWrapping
        ))
        let paths = textBlock(text, boxed: false)
        guard worktree.removed else {
            spacingAfter[paths] = Chrome.Space.s32
            return [heading, paths]
        }
        spacingAfter[paths] = Chrome.Space.s4
        let removed = AutomationViews.label("Removed, the run changed nothing.", font: ChromeFont.label, color: colors.textMuted)
        spacingAfter[removed] = Chrome.Space.s32
        return [heading, paths, removed]
    }

    private func reportSection(_ run: AutomationRun, spacingAfter: inout [NSView: CGFloat]) -> [NSView] {
        let colors = theme.colors
        let heading = ChromeEyebrowView(title: "Report", theme: theme)
        spacingAfter[heading] = Chrome.Space.s8
        guard let output = run.output else {
            let empty = AutomationViews.label(
                run.status.isFinal ? "No report" : "No report yet",
                font: ChromeFont.label,
                color: colors.textMuted
            )
            return [heading, empty]
        }
        let report = textBlock(AgentMarkdownRenderer.render(output, colors: colors, fontSize: 13), boxed: true)
        return [heading, report]
    }

    private func textBlock(_ text: NSAttributedString, boxed: Bool) -> AutomationTextBlockView {
        let block = AutomationTextBlockView(text: text, theme: theme, boxed: boxed)
        block.keyHandler = { [weak self] event in self?.keyHandler?(event) ?? false }
        return block
    }

    private func button(_ title: String, kind: ChromeButton.Kind, action: Selector) -> ChromeButton {
        let button = ChromeButton(title: title, theme: theme, kind: kind, target: self, action: action)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    // MARK: - Actions

    @objc private func backClicked() {
        onBack?()
    }

    @objc private func openRunClicked() {
        guard let run = shown?.run else { return }
        onOpenRun?(run.id)
    }

    @objc private func revealWorktreeClicked() {
        guard let worktree = shown?.run.worktree, !worktree.removed else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: worktree.path, isDirectory: true)])
    }
}
