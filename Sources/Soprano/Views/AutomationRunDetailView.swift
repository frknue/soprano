import AppKit

/// One run's report, laid out as a Soprano Agents board: its status pill and
/// times as tiles, why it was skipped or failed (a precheck's output as a code
/// block), the worktree it worked in, and the agent's final reply rendered as
/// Markdown by the chat's renderer. Open Run shows its live tab; Resume
/// Conversation reopens a closed run's agent.
final class AutomationRunDetailView: NSView {
    var onBack: (() -> Void)?
    var onOpenRun: ((String) -> Void)?
    /// Keys the report text does not use go back to the page.
    var keyHandler: ((NSEvent) -> Bool)?

    private let stack = NSStackView()
    private var shown: (run: AutomationRun, automation: Automation?, isLive: Bool, clock: String)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("automations-run")
        let scrollView = AutomationViews.scrollingPage(stack: stack)
        stack.spacing = 20
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
        let name = automation?.name ?? run.automationId
        var views: [NSView] = []
        var spacingAfter: [NSView: CGFloat] = [:]

        let breadcrumb = AutomationViews.breadcrumb(["Automations", name, "#\(run.number)"], target: self, action: #selector(backClicked))
        views.append(breadcrumb)
        spacingAfter[breadcrumb] = 10

        var buttons: [NSView] = []
        if run.target != nil, isLive {
            buttons.append(AutomationViews.button("Open Run", variant: .primary, target: self, action: #selector(openRunClicked)))
        } else if run.conversation != nil, AgentConversation.supports(profileId: run.profileId) {
            buttons.append(AutomationViews.button("Resume Conversation", variant: .primary, target: self, action: #selector(openRunClicked)))
        }
        if let worktree = run.worktree, !worktree.removed {
            buttons.append(AutomationViews.button("Reveal Worktree", variant: .outline, target: self, action: #selector(revealWorktreeClicked)))
        }
        let titleRow = AutomationViews.titleRow(
            AutomationController.runTitle(name: name, number: run.number),
            pill: AutomationPill.run(run.status, since: run.status == .running ? run.startedAt : nil),
            now: now,
            buttons: buttons
        )
        views.append(titleRow)

        views.append(AutomationViews.tileGrid(tiles(for: run, now: now), columns: 4))

        if let message = run.message {
            views.append(messageCard(message, status: run.status))
        }
        if let worktree = run.worktree {
            views.append(worktreeCard(worktree))
        }
        views.append(reportCard(run))

        stack.setArrangedSubviews(views) { view in
            if view !== breadcrumb {
                view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
        for (view, spacing) in spacingAfter {
            stack.setCustomSpacing(spacing, after: view)
        }
    }

    private func tiles(for run: AutomationRun, now: Date) -> [NSView] {
        var tiles: [NSView] = [AutoUITileView(title: "Started", value: AutoUITileView.value(AutomationFormat.dateTime(run.startedAt)))]
        if let finishedAt = run.finishedAt {
            tiles.append(AutoUITileView(title: "Finished", value: AutoUITileView.value(AutomationFormat.dateTime(finishedAt))))
        } else {
            tiles.append(AutoUITileView(title: "Finished", value: AutoUITileView.value(run.status.isFinal ? "—" : "Not yet", muted: true)))
        }
        if let duration = run.duration {
            tiles.append(AutoUITileView(title: "Duration", value: AutoUITileView.value(AutomationFormat.duration(duration))))
        } else {
            let soFar = "\(AutomationFormat.duration(now.timeIntervalSince(run.startedAt))) so far"
            tiles.append(AutoUITileView(title: "Duration", value: AutoUITileView.value(soFar, muted: true)))
        }
        if run.trigger == .scheduled, let scheduledFor = run.scheduledFor {
            tiles.append(AutoUITileView(title: "Scheduled for", value: AutoUITileView.value(AutomationFormat.dateTime(scheduledFor))))
        }
        tiles.append(AutoUITileView(title: "Trigger", value: AutoUITileView.value(AutomationFormat.trigger(run.trigger))))
        tiles.append(AutoUITileView(title: "Agent", value: AutoUITileView.value(AutomationFormat.agentName(run.profileId))))
        let folder = AutoUITileView.value(AutomationFormat.path(run.folder), path: true)
        folder.toolTip = run.folder
        tiles.append(AutoUITileView(title: "Worked in", value: folder))
        return tiles
    }

    /// Why the run was skipped or failed, or what its agent waits for. A
    /// precheck's output follows its first paragraph and shows as a code block.
    private func messageCard(_ message: String, status: AutomationRun.Status) -> NSView {
        let title = switch status {
        case .skipped: "Why it was skipped"
        case .failed: "Why it failed"
        case .needsInput: "Waiting for"
        case .starting, .running, .completed: "Message"
        }
        var reason = message
        var output: String?
        if message.hasPrefix("The precheck"), let split = message.range(of: "\n\n") {
            reason = String(message[..<split.lowerBound])
            output = String(message[split.upperBound...])
        }
        var body: [NSView] = [textBlock(reason)]
        if let output {
            let code = AutomationMarkdownBlockView(code: output)
            code.keyHandler = { [weak self] event in self?.keyHandler?(event) ?? false }
            body.append(code)
        }
        return AutoUICardHeader.card(title, body: body)
    }

    private func worktreeCard(_ worktree: AutomationRun.Worktree) -> NSView {
        let path = textBlock(
            AutomationFormat.path(worktree.path),
            font: Typography.mono(Typography.rowSize),
            role: worktree.removed ? { $0.mutedForeground } : { $0.foreground }
        )
        let branch = textBlock(worktree.branch, font: Typography.mono(Typography.smallSize), role: { $0.mutedForeground })
        var body: [NSView] = [path, branch]
        if worktree.removed {
            body.append(AutoUIThemedLabel("Removed, the run changed nothing.", size: Typography.smallSize) { $0.mutedForeground })
        }
        let card = AutoUICardHeader.card("Worktree", body: body)
        return card
    }

    private func reportCard(_ run: AutomationRun) -> NSView {
        guard let output = run.output else {
            let empty = AutoUIThemedLabel(run.status.isFinal ? "No report" : "No report yet", size: Typography.rowSize) { $0.mutedForeground }
            return AutoUICardHeader.card("Report", body: [empty])
        }
        let report = AutomationMarkdownBlockView(markdown: output)
        report.identifier = NSUserInterfaceItemIdentifier("automations-run-report")
        report.keyHandler = { [weak self] event in self?.keyHandler?(event) ?? false }
        return AutoUICardHeader.card("Report", body: [report])
    }

    private func textBlock(
        _ text: String,
        font: NSFont = Typography.ui(Typography.bodySize),
        role: @escaping (Palette) -> NSColor = { $0.foreground }
    ) -> AutomationTextBlockView {
        let lineBreak: NSLineBreakMode = font.isFixedPitch ? .byCharWrapping : .byWordWrapping
        let block = AutomationTextBlockView(text: text, font: font, lineBreakMode: lineBreak, role: role)
        block.keyHandler = { [weak self] event in self?.keyHandler?(event) ?? false }
        return block
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
