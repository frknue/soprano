import AppKit

/// One automation, laid out as a Soprano Agents board: its name and state
/// pill with Run Now, Edit, Pause/Resume and Delete; a notice when the last
/// run failed; its settings as tiles; the prompt on a card; and its run
/// history, newest first, as a card of rows. Choosing a run opens its report.
final class AutomationDetailView: NSView {
    var onBack: (() -> Void)?
    var onAction: ((AutomationAction) -> Void)?
    var onOpenRun: ((String) -> Void)?
    /// A run row was clicked; the page takes the keyboard.
    var onRowClicked: (() -> Void)?
    /// Keys the prompt text does not use, so J/K keep driving the runs.
    var keyHandler: ((NSEvent) -> Bool)?
    /// Whether the page has the keyboard; the selected run then shows the
    /// active row fill.
    var isListFocused = false {
        didSet {
            guard isListFocused != oldValue else { return }
            updateRunSelection(scrollIntoView: false)
        }
    }
    /// The run to select once the runs are shown, coming back from its report.
    var pendingRunSelection: String?

    private let stack = NSStackView()
    private var runRows: [AutomationRunRowView] = []
    private var selectedRunId: String?
    private var shown: (automation: Automation, runs: [AutomationRun], nextRun: Date?, clock: String)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("automations-detail")
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

    /// Rebuilds the page only when what it shows changed: the automation,
    /// its runs, or a time it states (`in 3 hr`, `4m so far`). Rebuilding
    /// replaces every view, which would take a text selection and the
    /// keyboard with it on each half-minute refresh.
    func update(automation: Automation, runs: [AutomationRun], nextRun: Date?, now: Date) {
        let clock = Self.clockText(runs: runs, nextRun: nextRun, now: now)
        if let shown,
           shown.automation == automation,
           shown.runs == runs,
           shown.nextRun == nextRun,
           shown.clock == clock {
            return
        }
        shown = (automation, runs, nextRun, clock)
        if let pendingRunSelection, runs.contains(where: { $0.id == pendingRunSelection }) {
            selectedRunId = pendingRunSelection
            self.pendingRunSelection = nil
        }
        if !runs.contains(where: { $0.id == selectedRunId }) {
            selectedRunId = runs.first?.id
        }
        rebuild(automation: automation, runs: runs, nextRun: nextRun, now: now)
        updateRunSelection(scrollIntoView: selectedRunId != runs.first?.id)
    }

    /// The page's times as it states them, which change with the clock alone.
    private static func clockText(runs: [AutomationRun], nextRun: Date?, now: Date) -> String {
        var parts = [nextRun.map { AutomationFormat.relative($0, now: now) } ?? ""]
        for run in runs where run.finishedAt == nil {
            parts.append(AutomationFormat.duration(now.timeIntervalSince(run.startedAt)))
        }
        return parts.joined(separator: "|")
    }

    // MARK: - Content

    private func rebuild(automation: Automation, runs: [AutomationRun], nextRun: Date?, now: Date) {
        var views: [NSView] = []
        var spacingAfter: [NSView: CGFloat] = [:]

        let breadcrumb = AutomationViews.breadcrumb(["Automations", automation.name], target: self, action: #selector(backClicked))
        views.append(breadcrumb)
        spacingAfter[breadcrumb] = 10

        let titleRow = AutomationViews.titleRow(
            automation.name,
            pill: AutomationPill.state(of: automation, lastRun: runs.first),
            now: now,
            buttons: [
                AutomationViews.button("Run Now", variant: .primary, target: self, action: #selector(runNowClicked)),
                AutomationViews.button("Edit…", variant: .outline, target: self, action: #selector(editClicked)),
                AutomationViews.button(automation.enabled ? "Pause" : "Resume", variant: .outline, target: self, action: #selector(toggleClicked)),
                AutomationViews.button("Delete…", variant: .destructive, target: self, action: #selector(deleteClicked)),
            ]
        )
        views.append(titleRow)
        spacingAfter[titleRow] = 4

        // `~/git/shop · Claude Code`
        let folder = AutoUIThemedLabel(AutomationFormat.path(automation.folder), size: Typography.smallSize) { $0.mutedForeground }
        folder.font = Typography.mono(Typography.smallSize)
        folder.lineBreakMode = .byTruncatingHead
        folder.toolTip = automation.folder
        folder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let agent = AutoUIThemedLabel("· \(AutomationFormat.agentName(automation.agentId))", size: Typography.rowSize) { $0.mutedForeground }
        agent.setContentCompressionResistancePriority(.required, for: .horizontal)
        let meta = NSStackView(views: [folder, agent])
        meta.orientation = .horizontal
        meta.alignment = .firstBaseline
        meta.spacing = 6
        views.append(meta)

        if let lastRun = runs.first, lastRun.status == .failed {
            let viewButton = AutomationViews.button("View Run", variant: .outline, target: self, action: #selector(viewFailedRunClicked))
            let notice = AutoUINotice.make(
                title: "Last run failed.",
                message: lastRun.message.map { AutomationFormat.firstParagraph(of: $0) },
                button: viewButton
            )
            views.append(notice)
        }

        views.append(AutomationViews.tileGrid(tiles(for: automation, nextRun: nextRun, now: now), columns: 4))

        let prompt = AutomationTextBlockView(text: automation.prompt)
        prompt.keyHandler = { [weak self] event in self?.keyHandler?(event) ?? false }
        views.append(AutoUICardHeader.card("Prompt", body: [prompt]))

        views.append(runsCard(runs: runs, now: now))

        stack.setArrangedSubviews(views) { view in
            if view !== breadcrumb {
                view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
        for (view, spacing) in spacingAfter {
            stack.setCustomSpacing(spacing, after: view)
        }
    }

    private func tiles(for automation: Automation, nextRun: Date?, now: Date) -> [NSView] {
        let schedule: AutoUITileView
        if case .custom(let expression) = automation.cadence {
            schedule = AutoUITileView(title: "Schedule", value: AutoUITileView.value(expression, mono: true), detail: "Custom cron")
        } else {
            schedule = AutoUITileView(title: "Schedule", value: AutoUITileView.value(automation.cadence.summary()))
        }

        let next: AutoUITileView = if let nextRun {
            AutoUITileView(
                title: "Next run",
                value: AutoUITileView.value(AutomationFormat.dateTime(nextRun)),
                detail: AutomationFormat.relative(nextRun, now: now)
            )
        } else {
            AutoUITileView(title: "Next run", value: AutoUITileView.value("Paused", muted: true))
        }

        let precheck: AutoUITileView = if let command = automation.precheck {
            AutoUITileView(
                title: "Precheck",
                value: AutoUITileView.value(command, mono: true),
                detail: "\(AutomationFormat.timeout(automation.precheckTimeoutSeconds)) timeout"
            )
        } else {
            AutoUITileView(title: "Precheck", value: AutoUITileView.value("None", muted: true))
        }

        return [
            schedule,
            next,
            AutoUITileView(title: "Runs in", value: AutoUITileView.value(AutomationFormat.workspace(automation.workspace))),
            AutoUITileView(title: "Session", value: AutoUITileView.value(AutomationFormat.session(automation.session))),
            AutoUITileView(title: "Grace", value: AutoUITileView.value(AutomationFormat.grace(automation.graceMinutes))),
            precheck,
            AutoUITileView(title: "Agent", value: AutoUITileView.value(AutomationFormat.agentName(automation.agentId))),
            AutoUITileView(
                title: "Model",
                value: automation.model.map { AutoUITileView.value($0, mono: true) } ?? AutoUITileView.value("CLI default", muted: true)
            ),
        ]
    }

    /// `Runs  12 runs · 9 completed`, the column titles and one row per run,
    /// on a card (the Statistics board's breakdown card).
    private func runsCard(runs: [AutomationRun], now: Date) -> NSView {
        let completed = runs.filter { $0.status == .completed }.count
        let header = AutoUICardHeader.make(
            "Runs",
            hint: runs.isEmpty ? nil : "\(AutomationFormat.count(runs.count, "run")) · \(completed) completed"
        )
        var views: [NSView] = [header]
        if runs.isEmpty {
            runRows = []
            let empty = NSStackView(views: [AutoUIThemedLabel("No runs yet.", size: Typography.rowSize) { $0.mutedForeground }])
            empty.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 8, right: 8)
            views.append(empty)
        } else {
            views.append(AutomationRunHeaderView())
            runRows = runs.map { run in
                let row = AutomationRunRowView(run: run, now: now)
                row.onOpen = { [weak self] in
                    guard let self else { return }
                    self.selectedRunId = run.id
                    self.updateRunSelection(scrollIntoView: false)
                    self.onRowClicked?()
                    self.onOpenRun?(run.id)
                }
                return row
            }
            views += runRows
        }
        let column = NSStackView(views: views)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.setCustomSpacing(8, after: header)
        for view in views.dropFirst() {
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        return AutoUICardView(content: column, inset: 8)
    }

    // MARK: - Selection

    func moveSelection(by delta: Int) {
        guard !runRows.isEmpty else { return }
        let current = runRows.firstIndex { $0.runId == selectedRunId } ?? 0
        let next = min(max(0, current + delta), runRows.count - 1)
        selectedRunId = runRows[next].runId
        updateRunSelection(scrollIntoView: true)
    }

    func activateSelection() {
        guard let selectedRunId, runRows.contains(where: { $0.runId == selectedRunId }) else { return }
        onOpenRun?(selectedRunId)
    }

    private func updateRunSelection(scrollIntoView: Bool) {
        for row in runRows {
            row.setSelected(row.runId == selectedRunId, focused: isListFocused)
        }
        guard scrollIntoView, let row = runRows.first(where: { $0.runId == selectedRunId }) else { return }
        layoutSubtreeIfNeeded()
        row.scrollToVisible(row.bounds)
    }

    // MARK: - Actions

    @objc private func backClicked() { onBack?() }
    @objc private func runNowClicked() { onAction?(.runNow) }
    @objc private func editClicked() { onAction?(.edit) }
    @objc private func toggleClicked() { onAction?(.toggleEnabled) }
    @objc private func deleteClicked() { onAction?(.delete) }

    @objc private func viewFailedRunClicked() {
        guard let run = shown?.runs.first else { return }
        onOpenRun?(run.id)
    }
}

// MARK: - Run rows

/// Where the run history's columns sit inside a row: Run, Trigger, Started,
/// Duration and Status, after the row's 8 pt padding.
enum AutomationRunColumns {
    static let leading: CGFloat = 8
    static let gap: CGFloat = 16
    private static let widths: [CGFloat] = [56, 110, 190, 130]

    static func frames(width: CGFloat) -> [ClosedRange<CGFloat>] {
        var x = leading
        var ranges: [ClosedRange<CGFloat>] = []
        for columnWidth in widths {
            ranges.append(x...(x + columnWidth))
            x += columnWidth + gap
        }
        ranges.append(x...max(x, width - leading))
        return ranges
    }
}

/// The run history's column titles.
final class AutomationRunHeaderView: NSView {
    private let labels: [NSTextField]
    private static let titles = ["Run", "Trigger", "Started", "Duration", "Status"]

    override init(frame frameRect: NSRect) {
        labels = Self.titles.map(AutomationViews.columnTitle)
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 26).isActive = true
        labels.forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        for (label, column) in zip(labels, AutomationRunColumns.frames(width: bounds.width)) {
            let height = label.intrinsicContentSize.height
            label.frame = NSRect(
                x: column.lowerBound,
                y: floor((bounds.height - height) / 2),
                width: column.upperBound - column.lowerBound,
                height: height
            )
        }
    }
}

/// One run: `#3  Scheduled  Oct 29, 9:00 AM  4m 12s  ✓ Done`, 34 pt, a
/// rounded row fill on hover and selection.
final class AutomationRunRowView: NSView {
    static let height: CGFloat = 34

    let runId: String
    var onOpen: (() -> Void)?

    private let background = ShellRowSurfaceView()
    private let numberLabel = AutoUIThemedLabel("", size: Typography.rowSize, weight: .medium)
    private let triggerLabel = AutoUIThemedLabel("", size: Typography.rowSize)
    private let startedLabel = AutoUIThemedLabel("", size: Typography.rowSize)
    private let durationLabel: AutoUIThemedLabel
    private let statusView: AutoUIPillView
    private var isSelected = false
    private var isFocused = false
    private var isHovered = false

    init(run: AutomationRun, now: Date) {
        runId = run.id
        let durationText: String
        let durationMuted: Bool
        if let duration = run.duration {
            (durationText, durationMuted) = (AutomationFormat.duration(duration), false)
        } else if run.status.isFinal {
            (durationText, durationMuted) = ("—", true)
        } else {
            (durationText, durationMuted) = ("\(AutomationFormat.duration(now.timeIntervalSince(run.startedAt))) so far", true)
        }
        durationLabel = AutoUIThemedLabel(durationText, size: Typography.rowSize) { durationMuted ? $0.mutedForeground : $0.foreground }
        statusView = AutoUIPillView(AutomationPill.run(run.status), now: now)
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("automations-run-row")
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true

        background.translatesAutoresizingMaskIntoConstraints = true
        background.horizontalInset = 0
        addSubview(background)
        numberLabel.font = Typography.tabular(Typography.rowSize, weight: .medium)
        durationLabel.font = Typography.tabular(Typography.rowSize)
        for view in [numberLabel, triggerLabel, startedLabel, durationLabel, statusView] as [NSView] {
            addSubview(view)
        }

        numberLabel.stringValue = "#\(run.number)"
        triggerLabel.stringValue = AutomationFormat.trigger(run.trigger)
        startedLabel.stringValue = AutomationFormat.dateTime(run.startedAt)
        toolTip = run.message

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Run \(run.number), \(run.status.label), started \(AutomationFormat.dateTime(run.startedAt))")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    func setSelected(_ selected: Bool, focused: Bool) {
        guard selected != isSelected || focused != isFocused else { return }
        isSelected = selected
        isFocused = focused
        setAccessibilitySelected(selected)
        updateBackground()
    }

    private func updateBackground() {
        if isSelected {
            background.style = isFocused ? .selected : .selectedUnfocused
        } else {
            background.style = isHovered ? .hover : .none
        }
    }

    override func layout() {
        super.layout()
        background.frame = bounds
        let columns = AutomationRunColumns.frames(width: bounds.width)
        let middle = bounds.height / 2
        for (label, column) in zip([numberLabel, triggerLabel, startedLabel, durationLabel], columns) {
            let height = ceil(label.intrinsicContentSize.height)
            label.frame = NSRect(x: column.lowerBound, y: floor(middle - height / 2), width: column.upperBound - column.lowerBound, height: height)
        }
        let status = columns[4]
        statusView.frame = NSRect(
            x: status.lowerBound,
            y: floor(middle - 10),
            width: min(statusView.intrinsicContentSize.width, status.upperBound - status.lowerBound),
            height: 20
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateBackground()
    }

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0 else { return }
        onOpen?()
    }

    override func accessibilityPerformPress() -> Bool {
        onOpen?()
        return true
    }
}
