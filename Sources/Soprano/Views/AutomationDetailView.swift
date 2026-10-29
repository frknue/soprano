import AppKit

/// One automation: its name and state with Run Now, Edit, Pause/Resume and
/// Delete; a banner when the last run failed; its settings as a grid; the
/// prompt; and its run history, newest first. Choosing a run opens its report.
final class AutomationDetailView: NSView {
    var onBack: (() -> Void)?
    var onAction: ((AutomationAction) -> Void)?
    var onOpenRun: ((String) -> Void)?
    /// A run row was clicked; the page takes the keyboard.
    var onRowClicked: (() -> Void)?
    /// Keys the prompt text does not use, so J/K keep driving the runs.
    var keyHandler: ((NSEvent) -> Bool)?
    /// Whether the page has the keyboard; the selected run then carries the
    /// pencil tick.
    var isListFocused = false {
        didSet {
            guard isListFocused != oldValue else { return }
            updateRunSelection(scrollIntoView: false)
        }
    }
    /// The run to select once the runs are shown, coming back from its report.
    var pendingRunSelection: String?

    private var theme: AppTheme
    private let stack = NSStackView()
    private var runRows: [AutomationRunRowView] = []
    private var selectedRunId: String?
    private var shown: (automation: Automation, runs: [AutomationRun], nextRun: Date?, clock: String)?

    init(theme: AppTheme) {
        self.theme = theme
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("automations-detail")
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
        update(automation: shown.automation, runs: shown.runs, nextRun: shown.nextRun, now: Date())
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
        let colors = theme.colors
        var views: [NSView] = []
        var spacingAfter: [NSView: CGFloat] = [:]

        let breadcrumb = AutomationViews.breadcrumb(
            ["Automations", automation.name],
            theme: theme,
            target: self,
            action: #selector(backClicked)
        )
        views.append(breadcrumb)
        spacingAfter[breadcrumb] = Chrome.Space.s12

        // Title, state chip and the actions.
        let title = AutomationViews.label(automation.name, font: ChromeFont.title, color: colors.textPrimary)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let chip = ChromeChip(
            text: automation.enabled ? "Enabled" : "Paused",
            theme: theme,
            style: automation.enabled ? .filled : .outline
        )
        let buttons: [NSView] = [
            button("Run Now", kind: .ink, action: #selector(runNowClicked)),
            button("Edit…", kind: .standard, action: #selector(editClicked)),
            button(automation.enabled ? "Pause" : "Resume", kind: .standard, action: #selector(toggleClicked)),
            button("Delete…", kind: .danger, action: #selector(deleteClicked)),
        ]
        let titleRow = AutomationViews.spreadRow(leading: [title, chip], trailing: buttons)
        views.append(titleRow)
        spacingAfter[titleRow] = Chrome.Space.s4

        // `~/git/shop · Claude Code`
        let meta = NSMutableAttributedString(attributedString: ChromeText.attributed(
            AutomationFormat.path(automation.folder),
            font: ChromeFont.mono,
            color: colors.textMuted,
            lineBreakMode: .byTruncatingHead
        ))
        meta.append(ChromeText.attributed(
            " · \(AutomationFormat.agentName(automation.agentId))",
            font: ChromeFont.label,
            color: colors.textMuted
        ))
        let metaLabel = NSTextField(labelWithAttributedString: meta)
        metaLabel.lineBreakMode = .byTruncatingHead
        metaLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        metaLabel.toolTip = automation.folder
        views.append(metaLabel)
        spacingAfter[metaLabel] = Chrome.Space.s24

        if let lastRun = runs.first, lastRun.status == .failed {
            let text = NSMutableAttributedString(attributedString: ChromeText.attributed(
                "Last run failed.",
                font: ChromeFont.labelStrong,
                color: colors.textPrimary,
                lineBreakMode: .byWordWrapping
            ))
            if let message = lastRun.message.map({ AutomationFormat.firstParagraph(of: $0) }) {
                text.append(ChromeText.attributed(
                    " \(message)",
                    font: ChromeFont.label,
                    color: colors.textPrimary,
                    lineBreakMode: .byWordWrapping
                ))
            }
            let viewButton = ChromeButton(title: "View Run", theme: theme, target: self, action: #selector(viewFailedRunClicked))
            let banner = AutomationViews.notice(text, theme: theme, button: viewButton)
            views.append(banner)
            spacingAfter[banner] = Chrome.Space.s24
        }

        let grid = AutomationViews.metricsGrid(metrics(for: automation, nextRun: nextRun, now: now), columns: 4, theme: theme)
        views.append(grid)
        spacingAfter[grid] = Chrome.Space.s32

        let promptHeading = ChromeEyebrowView(title: "Prompt", theme: theme)
        views.append(promptHeading)
        spacingAfter[promptHeading] = Chrome.Space.s8
        let prompt = AutomationTextBlockView(
            text: ChromeText.attributed(automation.prompt, font: ChromeFont.row, color: colors.textPrimary, lineBreakMode: .byWordWrapping),
            theme: theme,
            boxed: true
        )
        prompt.keyHandler = { [weak self] event in self?.keyHandler?(event) ?? false }
        views.append(prompt)
        spacingAfter[prompt] = Chrome.Space.s32

        views.append(contentsOf: runSection(automation: automation, runs: runs, now: now, spacingAfter: &spacingAfter))

        stack.setArrangedSubviews(views) { view in
            if view !== breadcrumb {
                view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
        for (view, spacing) in spacingAfter {
            stack.setCustomSpacing(spacing, after: view)
        }
    }

    private func metrics(for automation: Automation, nextRun: Date?, now: Date) -> [(String, NSView)] {
        let colors = theme.colors
        func value(_ text: String, mono: Bool = false, muted: Bool = false) -> NSView {
            AutomationViews.wrappingLabel(ChromeText.attributed(
                text,
                font: mono ? ChromeFont.mono : ChromeFont.row,
                color: muted ? colors.textMuted : colors.textPrimary,
                lineBreakMode: .byWordWrapping
            ))
        }

        let schedule: NSView
        if case .custom(let expression) = automation.cadence {
            schedule = value(expression, mono: true)
        } else {
            schedule = value(automation.cadence.summary())
        }

        let next: NSView
        if let nextRun {
            let text = NSMutableAttributedString(attributedString: ChromeText.attributed(
                AutomationFormat.dateTime(nextRun),
                font: ChromeFont.row,
                color: colors.textPrimary,
                lineBreakMode: .byWordWrapping
            ))
            text.append(ChromeText.attributed(
                "  \(AutomationFormat.relative(nextRun, now: now))",
                font: ChromeFont.label,
                color: colors.textMuted,
                lineBreakMode: .byWordWrapping
            ))
            next = AutomationViews.wrappingLabel(text)
        } else {
            next = value("Paused", muted: true)
        }

        let precheck: NSView
        if let command = automation.precheck {
            let text = NSMutableAttributedString(attributedString: ChromeText.attributed(
                command,
                font: ChromeFont.mono,
                color: colors.textPrimary,
                lineBreakMode: .byWordWrapping
            ))
            text.append(ChromeText.attributed(
                " · \(AutomationFormat.timeout(automation.precheckTimeoutSeconds)) timeout",
                font: ChromeFont.label,
                color: colors.textMuted,
                lineBreakMode: .byWordWrapping
            ))
            precheck = AutomationViews.wrappingLabel(text)
        } else {
            precheck = value("None", muted: true)
        }

        return [
            ("Schedule", schedule),
            ("Next run", next),
            ("Runs in", value(AutomationFormat.workspace(automation.workspace))),
            ("Session", value(AutomationFormat.session(automation.session))),
            ("Grace", value(AutomationFormat.grace(automation.graceMinutes))),
            ("Precheck", precheck),
            ("Agent", value(AutomationFormat.agentName(automation.agentId))),
            ("Model", automation.model.map { value($0, mono: true) } ?? value("CLI default", muted: true)),
        ]
    }

    /// `RUNS  12 runs · 9 completed`, the column eyebrows and one row per run.
    private func runSection(
        automation: Automation,
        runs: [AutomationRun],
        now: Date,
        spacingAfter: inout [NSView: CGFloat]
    ) -> [NSView] {
        let colors = theme.colors
        let heading = ChromeEyebrowView(title: "Runs", theme: theme)
        let completed = runs.filter { $0.status == .completed }.count
        let count = AutomationViews.label(
            runs.isEmpty ? "" : "\(AutomationFormat.count(runs.count, "run")) · \(completed) completed",
            font: ChromeFont.count,
            color: colors.textMuted
        )
        let headingRow = AutomationViews.spreadRow(leading: [heading, count], trailing: [])
        spacingAfter[headingRow] = Chrome.Space.s8

        guard !runs.isEmpty else {
            runRows = []
            let empty = AutomationViews.label("No runs yet", font: ChromeFont.label, color: colors.textMuted)
            return [headingRow, empty]
        }

        let header = AutomationRunHeaderView(theme: theme)
        spacingAfter[header] = 0
        let rule = ChromeRuleView(axis: .horizontal, color: colors.borderSubtle)
        spacingAfter[rule] = Chrome.Space.s2

        runRows = runs.map { run in
            let row = AutomationRunRowView(run: run, theme: theme, now: now)
            row.onOpen = { [weak self] in
                guard let self else { return }
                self.selectedRunId = run.id
                self.updateRunSelection(scrollIntoView: false)
                self.onRowClicked?()
                self.onOpenRun?(run.id)
            }
            spacingAfter[row] = 0
            return row
        }
        return [headingRow, header, rule] + runRows
    }

    private func button(_ title: String, kind: ChromeButton.Kind, action: Selector) -> ChromeButton {
        let button = ChromeButton(title: title, theme: theme, kind: kind, target: self, action: action)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
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

/// Where the run history's columns sit: Run, Trigger, Started, Duration and
/// Status, starting where the selection pill's content does.
enum AutomationRunColumns {
    static let leading: CGFloat = Chrome.pillInset + 8
    static let gap: CGFloat = 16
    private static let widths: [CGFloat] = [56, 100, 190, 120]

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

/// The run history's column eyebrows.
final class AutomationRunHeaderView: NSView {
    private let labels: [NSTextField]
    private static let titles = ["Run", "Trigger", "Started", "Duration", "Status"]

    init(theme: AppTheme) {
        labels = Self.titles.map { title in
            let label = NSTextField(labelWithString: "")
            label.setEyebrowText(title, color: theme.colors.textMuted)
            return label
        }
        super.init(frame: .zero)
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

/// One run: `#3  Scheduled  Oct 29, 9:00 AM  4m 12s  ● DONE`, 32 pt.
final class AutomationRunRowView: NSView {
    static let height: CGFloat = 32

    let runId: String
    var onOpen: (() -> Void)?

    private let background: ChromeRowBackgroundView
    private let numberLabel = NSTextField(labelWithString: "")
    private let triggerLabel = NSTextField(labelWithString: "")
    private let startedLabel = NSTextField(labelWithString: "")
    private let durationLabel = NSTextField(labelWithString: "")
    private let statusMark: ChromeStatusMark
    private let statusLabel = NSTextField(labelWithString: "")
    private var isSelected = false
    private var isFocused = false
    private var isHovered = false

    init(run: AutomationRun, theme: AppTheme, now: Date) {
        runId = run.id
        background = ChromeRowBackgroundView(theme: theme)
        let colors = theme.colors
        let statusColor = AutomationStatusStyle.color(for: run.status, in: colors)
        statusMark = ChromeStatusMark(shape: AutomationStatusStyle.shape(for: run.status), color: statusColor)
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("automations-run-row")
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true

        background.translatesAutoresizingMaskIntoConstraints = true
        addSubview(background)
        statusMark.translatesAutoresizingMaskIntoConstraints = true
        addSubview(statusMark)
        for label in [numberLabel, triggerLabel, startedLabel, durationLabel, statusLabel] {
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }

        numberLabel.setChromeText("#\(run.number)", font: ChromeFont.sans(size: 12, weight: .medium, tabular: true), color: colors.textPrimary)
        triggerLabel.setChromeText(AutomationFormat.trigger(run.trigger), font: ChromeFont.label, color: colors.textPrimary)
        startedLabel.setChromeText(AutomationFormat.dateTime(run.startedAt), font: ChromeFont.label, color: colors.textPrimary)
        if let duration = run.duration {
            durationLabel.setChromeText(AutomationFormat.duration(duration), font: ChromeFont.count, color: colors.textPrimary)
        } else if run.status.isFinal {
            durationLabel.setChromeText("—", font: ChromeFont.count, color: colors.textMuted)
        } else {
            durationLabel.setChromeText(
                "\(AutomationFormat.duration(now.timeIntervalSince(run.startedAt))) so far",
                font: ChromeFont.count,
                color: colors.textMuted
            )
        }
        statusLabel.setStatusText(run.status.label, color: statusColor)
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
            place(label, x: column.lowerBound, width: column.upperBound - column.lowerBound, centerY: middle)
        }
        let status = columns[4]
        let side = statusMark.size
        statusMark.frame = NSRect(x: status.lowerBound, y: floor(middle - side / 2), width: side, height: side)
        place(statusLabel, x: status.lowerBound + side + 6, width: status.upperBound - status.lowerBound - side - 6, centerY: middle)
    }

    private func place(_ label: NSTextField, x: CGFloat, width: CGFloat, centerY: CGFloat) {
        let height = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: x, y: floor(centerY - height / 2), width: max(0, width), height: height)
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
