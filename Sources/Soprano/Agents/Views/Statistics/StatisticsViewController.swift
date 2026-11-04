import AppKit
import SopranoAgentsCore

/// The statistics board (as T3 Code's Usage page): omp's recorded requests, tokens and estimated
/// API-equivalent cost over 24h / 7d / 30d / 90d / All, as Cost or Tokens, with a stacked chart
/// per hour, day, week or month, the models (click one to filter the board to it), projects and
/// agent kinds. It covers the chat column and the right panel while
/// `WorkspaceState.isStatisticsVisible`; opening it and Refresh first sync omp's history.
///
/// Keys while it has focus: Esc closes, C / T switch Cost / Tokens, 1–5 pick the period.
@MainActor
final class StatisticsViewController: NSViewController {
    let engine: AgentEngine
    let state: WorkspaceState

    private(set) var period: UsagePeriod = .week
    private(set) var metric: UsageMetric = .cost
    private(set) var modelFilter: UsageModelKey?
    private(set) var history: UsageHistory?
    private var loadError: String?
    private var isLoading = false
    private var loadGeneration = 0
    /// The running load syncs omp's history first.
    private var pendingSync = false
    private var updatedAt: Date?

    private let header = StatisticsHeaderView()
    private let scrollView = NSScrollView()
    private let document = StatisticsDocumentView()
    private weak var readout: ThemedLabel?
    private var lastSummary: UsageSummary?

    static let contentMaxWidth: CGFloat = 960

    init(engine: AgentEngine, state: WorkspaceState) {
        self.engine = engine
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = StatisticsRootView(frame: NSRect(x: 0, y: 0, width: 800, height: 700))
        root.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        view = root

        header.periodControl.onSelect = { [weak self] index in self?.select(period: UsagePeriod.allCases[index]) }
        header.onRefresh = { [weak self] in self?.load(sync: true) }
        header.onClose = { [weak self] in self?.state.setStatisticsVisible(false) }
        header.onToggleSidebar = { [weak self] in
            (self?.view.window?.windowController as? AgentsWindowController)?.perform("view.toggleSidebar")
        }

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false

        for subview in [scrollView, header] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        let clip = scrollView.contentView
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.heightAnchor.constraint(equalToConstant: Metrics.topbarHeight),

            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
        ])

        state.addObserver(self) { [weak self] change in
            guard let self, change == .panels else { return }
            header.showsSidebarToggle = !state.isSidebarVisible
        }
        header.showsSidebarToggle = !state.isSidebarVisible
        render()
    }

    // MARK: Focus

    var hasFocus: Bool {
        guard let responder = view.window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: view)
    }

    func takeFocus() {
        view.window?.makeFirstResponder(view)
    }

    // MARK: Opening

    /// Called when the board becomes visible: syncs omp's history and reloads.
    func didOpen() {
        load(sync: true)
    }

    // MARK: Loading

    func select(period: UsagePeriod) {
        guard period != self.period || history == nil else { return }
        self.period = period
        header.periodControl.selectedIndex = UsagePeriod.allCases.firstIndex(of: period) ?? 0
        load(sync: false)
    }

    func select(metric: UsageMetric) {
        guard metric != self.metric else { return }
        self.metric = metric
        render()
    }

    func select(model: UsageModelKey?) {
        modelFilter = model == modelFilter ? nil : model
        render()
    }

    /// Reads the period's history; `sync` first lets omp ingest new session files. A newer load
    /// supersedes a running one and takes over its sync, so a period switch during the opening
    /// sync still shows fresh data.
    func load(sync: Bool) {
        loadGeneration += 1
        let generation = loadGeneration
        let period = period
        let sync = sync || pendingSync
        pendingSync = sync
        isLoading = true
        header.isRefreshing = true
        render()
        Task { [weak self] in
            guard let self else { return }
            do {
                let history = try await engine.usageHistory(period, sync: sync)
                guard generation == loadGeneration else { return }
                self.history = history
                loadError = nil
                updatedAt = Date()
                if let filter = modelFilter, !history.groups.contains(where: { $0.provider == filter.provider && $0.model == filter.model }) {
                    modelFilter = nil
                }
            } catch {
                guard generation == loadGeneration else { return }
                loadError = error.localizedDescription
                // Never show another period's numbers under this period's label.
                if self.history?.period != period { self.history = nil }
            }
            pendingSync = false
            isLoading = false
            header.isRefreshing = false
            render()
        }
    }

    // MARK: Keys

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        if event.keyCode == 53, modifiers.isEmpty {
            state.setStatisticsVisible(false)
            return true
        }
        guard modifiers.isEmpty, let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch key {
        case "c": select(metric: .cost)
        case "t": select(metric: .tokens)
        case "1", "2", "3", "4", "5":
            guard let index = Int(key), UsagePeriod.allCases.indices.contains(index - 1) else { return false }
            select(period: UsagePeriod.allCases[index - 1])
        default: return false
        }
        return true
    }

    // MARK: Rendering

    private func render() {
        guard isViewLoaded else { return }
        header.periodControl.selectedIndex = UsagePeriod.allCases.firstIndex(of: period) ?? 0
        guard let history else {
            lastSummary = nil
            document.setSections(firstLoadSections(), maxWidth: Self.contentMaxWidth)
            return
        }
        let summary = history.summary(model: modelFilter)
        lastSummary = summary
        var sections: [NSView] = [toolbar()]
        if let loadError { sections.append(notice(loadError, retry: true)) }
        if let syncError = history.syncError {
            sections.append(notice("Couldn’t update from omp, showing what was recorded before: \(syncError)", retry: true))
        }
        sections.append(tiles(summary))
        sections.append(chartCard(summary, history: history))
        sections.append(modelsCard(summary))
        sections.append(splitRow([projectsCard(summary), agentsCard(summary)]))
        sections.append(footnote())
        document.setSections(sections, maxWidth: Self.contentMaxWidth)
        document.alphaValue = isLoading ? 0.6 : 1
    }

    private func firstLoadSections() -> [NSView] {
        document.alphaValue = 1
        if let loadError, !isLoading {
            return [notice(loadError, retry: true)]
        }
        let label = ThemedLabel("Loading usage…", size: Typography.bodySize) { $0.mutedForeground }
        return [label]
    }

    private func toolbar() -> NSView {
        let metrics = StatisticsSegmentedControl(
            titles: ["Cost", "Tokens"],
            selectedIndex: metric == .cost ? 0 : 1
        )
        metrics.onSelect = { [weak self] index in self?.select(metric: index == 0 ? .cost : .tokens) }
        var views: [NSView] = [metrics]
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        views.append(spacer)
        if let modelFilter {
            let chip = TextButton(modelFilter.model, symbol: "xmark", variant: .secondary, size: .xs)
            chip.toolTip = "Show every model"
            chip.setAccessibilityLabel("Clear model filter")
            chip.onClick = { [weak self] in self?.select(model: nil) }
            views.append(chip)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func tiles(_ summary: UsageSummary) -> NSView {
        let totals = summary.totals
        let failures = totals.failedRequests == 0 ? "No failed requests" : "\(StatisticsFormat.count(totals.failedRequests)) failed"
        let tiles: [StatisticsTileView]
        switch metric {
        case .cost:
            let costDetail = totals.unpricedRequests > 0
                ? "\(StatisticsFormat.count(totals.unpricedRequests)) requests unpriced"
                : "At API rates"
            let hit = totals.cacheHitRate.map { "\(StatisticsFormat.percent($0)) of prompt tokens cached" } ?? "No prompt tokens"
            let perRequest = totals.requests > 0 ? totals.cost / Double(totals.requests) : 0
            let tokensPerRequest = totals.requests > 0 ? totals.tokens / totals.requests : 0
            tiles = [
                StatisticsTileView(title: "Estimated cost", value: StatisticsFormat.cost(totals.cost), detail: costDetail),
                StatisticsTileView(title: "Cache savings", value: StatisticsFormat.cost(totals.cacheSavings), detail: hit),
                StatisticsTileView(title: "Requests", value: StatisticsFormat.count(totals.requests), detail: failures),
                StatisticsTileView(title: "Per request", value: StatisticsFormat.cost(perRequest), detail: "\(StatisticsFormat.tokens(tokensPerRequest)) tokens each"),
            ]
        case .tokens:
            let hit = totals.cacheHitRate.map { "\(StatisticsFormat.percent($0)) hit rate" } ?? "No prompt tokens"
            tiles = [
                StatisticsTileView(title: "Total tokens", value: StatisticsFormat.tokens(totals.tokens), detail: "\(StatisticsFormat.count(totals.requests)) requests"),
                StatisticsTileView(title: "Input", value: StatisticsFormat.tokens(totals.inputTokens), detail: "Uncached prompt"),
                StatisticsTileView(title: "Output", value: StatisticsFormat.tokens(totals.outputTokens), detail: "Including reasoning"),
                StatisticsTileView(title: "Cache read", value: StatisticsFormat.tokens(totals.cacheReadTokens), detail: "\(StatisticsFormat.tokens(totals.cacheWriteTokens)) written · \(hit)"),
            ]
        }
        let row = NSStackView(views: tiles)
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.alignment = .top
        row.spacing = 12
        return row
    }

    private func chartCard(_ summary: UsageSummary, history: UsageHistory) -> NSView {
        let title = ThemedLabel(metric == .cost ? "Cost over time" : "Tokens over time", size: Typography.bodySize, weight: .semibold)
        let readout = ThemedLabel("", size: Typography.smallSize) { $0.mutedForeground }
        readout.font = Typography.tabular(Typography.smallSize)
        readout.alignment = .right
        readout.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.readout = readout
        let titleRow = NSStackView(views: [title, readout])
        titleRow.orientation = .horizontal
        titleRow.alignment = .firstBaseline
        titleRow.distribution = .fill
        title.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let chart = UsageChartView()
        chart.configure(buckets: summary.buckets, metric: metric, unit: history.bucketUnit)
        chart.onHover = { [weak self] index in self?.updateReadout(hovered: index) }

        let stack = NSStackView(views: [titleRow, chart, UsageLegendView()])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        for view in [titleRow, chart] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        updateReadout(hovered: nil)
        return StatisticsCardView(content: stack)
    }

    /// The chart's title line: the hovered bar, else the period's total.
    private func updateReadout(hovered index: Int?) {
        guard let readout, let summary = lastSummary, let history else { return }
        if let index, summary.buckets.indices.contains(index) {
            let bucket = summary.buckets[index]
            let requests = "\(StatisticsFormat.count(bucket.totals.requests)) requests"
            readout.stringValue = "\(StatisticsFormat.bucketTitle(bucket.start, unit: history.bucketUnit)) · \(StatisticsFormat.value(bucket.totals, metric)) · \(requests)"
        } else {
            let scope = modelFilter.map { " · \($0.model)" } ?? ""
            readout.stringValue = "\(history.period.title) total · \(StatisticsFormat.value(summary.totals, metric))\(scope)"
        }
    }

    private func modelsCard(_ summary: UsageSummary) -> NSView {
        let models = summary.models.sorted { $0.totals.value(metric) > $1.totals.value(metric) }
        let total = models.reduce(0) { $0 + $1.totals.value(metric) }
        let rows: [NSView] = models.enumerated().map { index, row in
            let unpriced = metric == .cost && row.totals.cost == 0 && row.totals.unpricedRequests > 0
            let cached = row.totals.cacheHitRate.map { "\(StatisticsFormat.percent($0)) cached" } ?? "—"
            let view = StatisticsBreakdownRow(
                title: row.key.model,
                subtitle: row.key.provider,
                colorIndex: index,
                share: total > 0 ? row.totals.value(metric) / total : 0,
                barWidth: 96,
                columns: [
                    .init(text: "\(StatisticsFormat.count(row.totals.requests)) req", width: 72),
                    .init(text: cached, width: 84),
                ],
                value: unpriced ? "Unpriced" : StatisticsFormat.value(row.totals, metric),
                valueMuted: unpriced,
                clickable: true
            )
            view.isSelected = row.key == modelFilter
            view.toolTip = row.key == modelFilter ? "Show every model" : "Show only \(row.key.model)"
            view.onClick = { [weak self] in self?.select(model: row.key) }
            return view
        }
        return breakdownCard(title: "Models", hint: models.isEmpty ? nil : "Click a model to filter", rows: rows)
    }

    private func projectsCard(_ summary: UsageSummary) -> NSView {
        let titles = engine.usageFolderTitles()
        var merged: [String: UsageTotals] = [:]
        for row in summary.folders {
            merged[titles[row.key] ?? UsageFolderName.fallbackTitle(row.key), default: UsageTotals()].add(row.totals)
        }
        let ranked = merged.sorted { $0.value.value(metric) > $1.value.value(metric) }
        let total = ranked.reduce(0) { $0 + $1.value.value(metric) }
        let limit = 8
        var rows = ranked.prefix(limit).map { (title: $0.key, totals: $0.value) }
        if ranked.count > limit {
            var rest = UsageTotals()
            for entry in ranked.dropFirst(limit) { rest.add(entry.value) }
            rows.append((title: "\(ranked.count - limit) more", totals: rest))
        }
        return breakdownCard(title: "Projects", hint: nil, rows: rows.map { entry in
            StatisticsBreakdownRow(
                title: entry.title,
                share: total > 0 ? entry.totals.value(metric) / total : 0,
                barWidth: 56,
                columns: [],
                value: StatisticsFormat.value(entry.totals, metric)
            )
        })
    }

    private func agentsCard(_ summary: UsageSummary) -> NSView {
        let agents = summary.agents.sorted { $0.totals.value(metric) > $1.totals.value(metric) }
        let total = agents.reduce(0) { $0 + $1.totals.value(metric) }
        return breakdownCard(title: "Agents", hint: nil, rows: agents.map { row in
            StatisticsBreakdownRow(
                title: StatisticsFormat.agentTitle(row.key),
                share: total > 0 ? row.totals.value(metric) / total : 0,
                barWidth: 56,
                columns: [],
                value: StatisticsFormat.value(row.totals, metric)
            )
        })
    }

    private func breakdownCard(title: String, hint: String?, rows: [NSView]) -> NSView {
        let titleLabel = ThemedLabel(title, size: Typography.bodySize, weight: .semibold)
        var headerViews: [NSView] = [titleLabel]
        if let hint {
            let hintLabel = ThemedLabel(hint, size: Typography.smallSize) { $0.mutedForeground }
            headerViews.append(hintLabel)
        }
        // The card pads 8 pt so the rows' hover fill reaches near its edge; the title and the
        // empty note add 8 pt more, lining up with the rows' text.
        let headerRow = NSStackView(views: headerViews)
        headerRow.orientation = .horizontal
        headerRow.alignment = .firstBaseline
        headerRow.spacing = 10
        headerRow.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 0, right: 8)
        var content = rows
        if rows.isEmpty {
            let empty = NSStackView(views: [ThemedLabel("No requests in this period.", size: Typography.rowSize) { $0.mutedForeground }])
            empty.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 8, right: 8)
            content = [empty]
        }
        let stack = NSStackView(views: [headerRow] + content)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.setCustomSpacing(8, after: headerRow)
        for row in rows {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return StatisticsCardView(content: stack, inset: 8)
    }

    private func splitRow(_ views: [NSView]) -> NSView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.alignment = .top
        row.spacing = 12
        return row
    }

    private func notice(_ message: String, retry: Bool) -> NSView {
        let label = ThemedLabel(message, size: Typography.rowSize, wrapping: true) { $0.errorForeground }
        label.preferredMaxLayoutWidth = Self.contentMaxWidth - 160
        var views: [NSView] = [label]
        if retry {
            let button = TextButton("Retry", variant: .outline, size: .xs)
            button.onClick = { [weak self] in self?.load(sync: true) }
            views.append(button)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return StatisticsCardView(content: row)
    }

    private func footnote() -> NSView {
        var text = "Estimated from omp's usage records at API prices, not your subscription bill. Counts every omp session on this Mac, not only these threads."
        if let updatedAt {
            text += " Updated \(StatisticsFormat.time(updatedAt))."
        }
        let label = ThemedLabel(text, size: Typography.smallSize, wrapping: true) { $0.mutedForeground }
        label.preferredMaxLayoutWidth = Self.contentMaxWidth
        return label
    }
}

/// Background of the board; takes key focus so Esc, C / T and 1–5 reach the board.
final class StatisticsRootView: PaletteView {
    var onKey: ((NSEvent) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        applyPalette(palette)
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.background.cgColor
    }
}

/// The board's 52 pt header: "Statistics", the period control, Refresh and Close; a sidebar
/// toggle clears the traffic lights while the sidebar is hidden.
final class StatisticsHeaderView: PaletteView {
    let periodControl = StatisticsSegmentedControl(
        titles: UsagePeriod.allCases.map(\.title),
        accessibilityLabels: UsagePeriod.allCases.map { "Period \($0.title)" },
        selectedIndex: 1
    )
    var onRefresh: (() -> Void)?
    var onClose: (() -> Void)?
    var onToggleSidebar: (() -> Void)?

    private let sidebarButton = GhostIconButton(symbol: Icon.sidebarLeft, symbolSize: 14, toolTip: "Toggle sidebar (⌘E)")
    private let titleLabel = NSTextField.label("Statistics", size: Typography.bodySize, weight: .medium)
    private let refreshButton = GhostIconButton(symbol: "arrow.clockwise", symbolSize: 14, toolTip: "Refresh")
    private let closeButton = GhostIconButton(symbol: "xmark", symbolSize: 13, toolTip: "Close statistics (Esc)")
    private let border = CALayer()
    private var titleAfterSidebarButton: NSLayoutConstraint?
    private var titleAtEdge: NSLayoutConstraint?

    var showsSidebarToggle = false {
        didSet {
            sidebarButton.isHidden = !showsSidebarToggle
            titleAfterSidebarButton?.isActive = showsSidebarToggle
            titleAtEdge?.isActive = !showsSidebarToggle
        }
    }

    var isRefreshing = false {
        didSet { refreshButton.isEnabled = !isRefreshing }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.addSublayer(border)
        sidebarButton.onClick = { [weak self] in self?.onToggleSidebar?() }
        refreshButton.onClick = { [weak self] in
            guard let self, !isRefreshing else { return }
            onRefresh?()
        }
        closeButton.onClick = { [weak self] in self?.onClose?() }
        for view in [sidebarButton, titleLabel, periodControl, refreshButton, closeButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let titleAfterSidebarButton = titleLabel.leadingAnchor.constraint(equalTo: sidebarButton.trailingAnchor, constant: 8)
        let titleAtEdge = titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.gutter)
        self.titleAfterSidebarButton = titleAfterSidebarButton
        self.titleAtEdge = titleAtEdge
        NSLayoutConstraint.activate([
            sidebarButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.windowControlsInset + 1),
            sidebarButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleAtEdge,
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: periodControl.leadingAnchor, constant: -12),

            periodControl.centerYAnchor.constraint(equalTo: centerYAnchor),
            periodControl.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -8),
            refreshButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            refreshButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -2),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
        sidebarButton.isHidden = true
        titleLabel.setAccessibilityLabel("Statistics")
        applyPalette(palette)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        border.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
        CATransaction.commit()
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.background.cgColor
        border.backgroundColor = palette.border.cgColor
        titleLabel.textColor = palette.foreground
    }
}

/// The scrolling column: sections stacked `gap-6`, centered at up to `maxWidth`, `px-6 py-6`.
final class StatisticsDocumentView: NSView {
    private let stack = NSStackView()
    private var widthConstraints: [NSLayoutConstraint] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        // Below the window's own size priorities, so the capped column never limits how wide the
        // window can grow (zoom, resize); above the stack's hugging, so it still fills up to the cap.
        let fill = stack.widthAnchor.constraint(equalTo: widthAnchor, constant: -48)
        fill.priority = .dragThatCannotResizeWindow
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -32),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            fill,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func setSections(_ sections: [NSView], maxWidth: CGFloat) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        NSLayoutConstraint.deactivate(widthConstraints)
        widthConstraints = [stack.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth)]
        for section in sections {
            stack.addArrangedSubview(section)
            widthConstraints.append(section.widthAnchor.constraint(equalTo: stack.widthAnchor))
        }
        NSLayoutConstraint.activate(widthConstraints)
    }
}
